import Foundation

/// A recorded preemption: a lower-priority job gave way so a higher-priority
/// one could run. The self-test asserts this fired for `background` → `realtimeASR`.
struct ComputeYield: Sendable, Equatable {
    let yielded: WorkClass
    let to: WorkClass
}

/// Cheap, race-tolerant view of which lanes currently have work.
///
/// Includes the running job and anything still queued or parked after
/// preemption — a notes job that yielded to ASR is still "busy" for cleanup
/// pressure. Approximate by design: callers must not treat this as a lock.
struct ComputeOccupancy: Sendable, Equatable {
    /// Work class of the job currently holding the lane, if any.
    let running: WorkClass?
    /// Classes with at least one job running, queued, or parked.
    let busy: Set<WorkClass>

    func isBusy(_ workClass: WorkClass) -> Bool {
        busy.contains(workClass)
    }

    /// Dictation / meeting ASR hold (`.realtimeASR`).
    var realtimeASRBusy: Bool { isBusy(.realtimeASR) }

    /// Notes load / generation (and other `.background` work such as diarization).
    var notesBusy: Bool { isBusy(.background) }

    static let empty = ComputeOccupancy(running: nil, busy: [])
}

/// The scheduler surface runtimes take. One in-memory implementation records
/// `workClass` order, cooperative yield, and production `acquire` /
/// `checkpoint` / `release` used by `NotesModelRuntime` and dictation ASR.
protocol ComputeScheduling: Sendable {
    func submit(_ job: ComputeJob) async
    func finishCurrent() async
    var recordedOrder: [WorkClass] { get async }
    var yieldEvents: [ComputeYield] { get async }
}

/// In-memory compute queue with cooperative preemption.
///
/// Policy intent (preferred device is still a hint, not a binding):
///
///     realtimeAudio  → reserved CPU
///     realtimeASR    → Neural Engine / CoreML
///     realtimeAgent  → GPU or Apple Foundation Models
///     meetingLive    → opportunistic accelerator
///     background     → idle resources / throttled GPU
///
/// Background jobs yield when a `realtimeASR` (or higher) job is queued.
/// That is the whole reason this type exists: a meeting-notes load of Qwen
/// must not stall dictation ASR for four seconds.
///
/// ## Enforced here
///
/// - Priority order and recorded yields (`submit` / `acquire`).
/// - Cooperative park/resume for a body that calls `checkpoint` after a
///   higher-priority job has preempted it.
/// - `NotesModelRuntime` acquires `.background` around load and generation.
/// - Dictation ASR acquires `.realtimeASR` (`ParakeetEngine` for the whole
///   start→finish window; Apple via `DictationController`).
/// - Meeting ASR acquires `.realtimeASR` per window in `TranscriptionQueue`
///   (the shared Parakeet lane for both mic and system tracks).
///
/// ## Deliberately not done here
///
/// - Call `LlamaBackend.beginCleanup` / `endCleanup`. The cleanup gate is
///   one-directional (notes wait for cleanup via `awaitCleanupIdle`). A
///   scheduler that asked cleanup to wait for notes would deadlock it —
///   see `QwenCleanupFormatter`.
/// - Bind a real model to `preferredDevice`.
/// - Unload weights under pressure — that is `ModelResidencyPolicy`.
///
/// Windows is out of scope.
actor ComputeScheduler: ComputeScheduling {
    /// Process-wide lane. Notes generation and (later) diarization share it;
    /// ASR acquires `.realtimeASR` from ParakeetEngine / the Apple path in
    /// DictationController / meeting `TranscriptionQueue` (one hold per window).
    static let shared = ComputeScheduler()

    private var queued: [ComputeJob] = []
    private var parked: [ComputeJob] = []
    private var running: ComputeJob?

    /// Continuations for jobs that called `acquire` or `checkpoint` while
    /// not currently `running`. Resumed from `start(_:)`.
    private var resumeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private(set) var recordedOrder: [WorkClass] = []
    private(set) var yieldEvents: [ComputeYield] = []

    /// Enqueue `job`. If something less urgent is already running, that
    /// job is parked and a yield is recorded; the new job starts immediately.
    /// If the new job is less urgent than whatever is running, it waits.
    func submit(_ job: ComputeJob) {
        if let current = running, job.workClass.preempts(current.workClass) {
            parked.insert(current, at: 0)
            yieldEvents.append(ComputeYield(yielded: current.workClass, to: job.workClass))
            start(job)
            return
        }

        if running == nil {
            start(job)
            return
        }

        for waiting in queued where job.workClass.preempts(waiting.workClass) {
            yieldEvents.append(ComputeYield(yielded: waiting.workClass, to: job.workClass))
        }
        queued.append(job)
        queued.sort { lhs, rhs in
            if lhs.workClass.priority != rhs.workClass.priority {
                return lhs.workClass.priority < rhs.workClass.priority
            }
            return false
        }
    }

    /// Completes the running job and starts the next: a parked (preempted)
    /// job first, otherwise the head of the priority queue.
    func finishCurrent() {
        running = nil
        if let next = parked.first {
            parked.removeFirst()
            start(next)
            return
        }
        if queued.isEmpty { return }
        start(queued.removeFirst())
    }

    func didYield(_ yielded: WorkClass, to winner: WorkClass) -> Bool {
        yieldEvents.contains { $0.yielded == yielded && $0.to == winner }
    }

    // MARK: - Production cooperative API

    /// Registers a job of `workClass` and suspends until it is the running
    /// job. Pair with `release(_:)` (and optional `checkpoint(_:)` inside
    /// long bodies).
    func acquire(_ workClass: WorkClass) async -> UUID {
        let job = ComputeJob(workClass: workClass)
        submit(job)
        if running?.id == job.id {
            return job.id
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            resumeWaiters[job.id] = continuation
        }
        return job.id
    }

    /// If `id` was preempted into `parked`, suspend until it is running again.
    /// No-op when this job still holds the lane.
    func checkpoint(_ id: UUID) async {
        // Re-check inside the continuation closure: the actor can resume us
        // via `start` between the outer guard and suspension registration only
        // after we await, so the sync closure still sees a consistent snapshot.
        if running?.id == id { return }
        let known = parked.contains { $0.id == id } || queued.contains { $0.id == id }
        guard known else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if running?.id == id {
                continuation.resume()
                return
            }
            resumeWaiters[id] = continuation
        }
    }

    /// Ends the job. If it is running, starts the next; if it is still
    /// queued or parked, drops it without touching the current runner.
    func release(_ id: UUID) {
        if running?.id == id {
            finishCurrent()
            return
        }
        parked.removeAll { $0.id == id }
        queued.removeAll { $0.id == id }
        if let waiter = resumeWaiters.removeValue(forKey: id) {
            waiter.resume()
        }
    }

    // MARK: - Occupancy snapshot

    /// Approximate lane occupancy for pressure probes. Safe to call anytime;
    /// does not mutate queue state.
    func occupancy() -> ComputeOccupancy {
        var busy = Set<WorkClass>()
        if let running {
            busy.insert(running.workClass)
        }
        for job in queued {
            busy.insert(job.workClass)
        }
        for job in parked {
            busy.insert(job.workClass)
        }
        return ComputeOccupancy(running: running?.workClass, busy: busy)
    }

    /// Whether any job of `workClass` is running, queued, or parked.
    func isBusy(_ workClass: WorkClass) -> Bool {
        occupancy().isBusy(workClass)
    }

    private func start(_ job: ComputeJob) {
        running = job
        recordedOrder.append(job.workClass)
        if let waiter = resumeWaiters.removeValue(forKey: job.id) {
            waiter.resume()
        }
    }
}

extension ComputeScheduler {
    /// Isolated probe of the in-memory queue. Wired to `--selftest-scheduler`.
    /// Never calls `RunLog.record`.
    ///
    /// Fails unless a background job that was already running yielded when
    /// a `realtimeASR` job was queued.
    ///
    /// Production callers of that class: dictation `ParakeetEngine` /
    /// `DictationController` (Apple), and meeting `TranscriptionQueue` per
    /// window. This probe stays on the in-memory scheduler — it does not
    /// drive Parakeet or a meeting — and still prints `SCHEDULER_OK` when
    /// the yield / acquire / release contract holds.
    static func runSelfTest() async {
        var failures: [String] = []

        let scheduler = ComputeScheduler()
        await scheduler.submit(ComputeJob(workClass: .background))
        await scheduler.submit(ComputeJob(workClass: .realtimeASR))

        let yielded = await scheduler.didYield(.background, to: .realtimeASR)
        if !yielded {
            failures.append("background job did not yield when realtimeASR was queued")
        }

        let order = await scheduler.recordedOrder
        if order.first != .background {
            failures.append("background job did not start before realtimeASR arrived")
        }
        if !order.contains(.realtimeASR) {
            failures.append("realtimeASR job never started after being queued")
        }

        // Control: ASR already running must not yield to notes.
        let reverse = ComputeScheduler()
        await reverse.submit(ComputeJob(workClass: .realtimeASR))
        await reverse.submit(ComputeJob(workClass: .background))
        if await reverse.didYield(.realtimeASR, to: .background) {
            failures.append("realtimeASR yielded to a background job")
        }

        // Cooperative acquire: background waits behind a held ASR lane.
        let coop = ComputeScheduler()
        let asrID = await coop.acquire(.realtimeASR)
        if !(await coop.isBusy(.realtimeASR)) {
            failures.append("occupancy missed a held realtimeASR lane")
        }
        if await coop.isBusy(.background) {
            failures.append("occupancy reported background busy before notes acquired")
        }
        let gate = Gate()
        let background = Task {
            let bgID = await coop.acquire(.background)
            await gate.markStarted()
            await coop.release(bgID)
        }
        try? await Task.sleep(for: .milliseconds(40))
        if await gate.hasStarted {
            failures.append("background acquire ran while realtimeASR still held the lane")
        }
        // Background is queued behind ASR — still counts as notes-busy for pressure.
        if !(await coop.isBusy(.background)) {
            failures.append("occupancy missed a queued background job")
        }
        await coop.release(asrID)
        _ = await background.result
        if !(await gate.hasStarted) {
            failures.append("background acquire never resumed after realtimeASR released")
        }
        let coopDone = await coop.occupancy()
        if coopDone.realtimeASRBusy || coopDone.notesBusy {
            failures.append("occupancy still busy after cooperative acquire released")
        }

        // Simulated dictation hold: notes already running must park at
        // checkpoint when ASR acquires (the NotesModelRuntime path), then
        // resume only after ASR releases — no leak across the hold.
        let hold = ComputeScheduler()
        let holdGate = CheckpointGate()
        let notes = Task {
            let bgID = await hold.acquire(.background)
            await holdGate.markRunning()
            // Wait until the test has acquired ASR (and preempted us) before
            // checkpointing — otherwise checkpoint is a no-op while we still run.
            await holdGate.waitUntilASRHeld()
            await hold.checkpoint(bgID)
            await holdGate.markResumed()
            await hold.release(bgID)
        }
        for _ in 0..<50 where !(await holdGate.hasRunning) {
            try? await Task.sleep(for: .milliseconds(4))
        }
        if !(await holdGate.hasRunning) {
            failures.append("background job never started before simulated ASR hold")
        } else {
            if !(await hold.isBusy(.background)) {
                failures.append("occupancy missed a running background job before ASR hold")
            }
            let asrHold = await hold.acquire(.realtimeASR)
            if !(await hold.didYield(.background, to: .realtimeASR)) {
                failures.append("running background did not yield when simulated ASR acquired")
            }
            // Parked notes + running ASR should both show up on the snapshot.
            let snapped = await hold.occupancy()
            if !snapped.realtimeASRBusy {
                failures.append("occupancy missed realtimeASR during simulated ASR hold")
            }
            if !snapped.notesBusy {
                failures.append("occupancy missed parked background during simulated ASR hold")
            }
            await holdGate.signalASRHeld()
            // Give the notes task a beat to reach checkpoint and park.
            try? await Task.sleep(for: .milliseconds(40))
            if await holdGate.hasResumed {
                failures.append("background checkpoint resumed while simulated ASR still held")
            }
            await hold.release(asrHold)
            _ = await notes.result
            if !(await holdGate.hasResumed) {
                failures.append("background checkpoint never resumed after simulated ASR released")
            }
            let holdDone = await hold.occupancy()
            if holdDone.realtimeASRBusy || holdDone.notesBusy {
                failures.append("occupancy still busy after simulated ASR hold released")
            }
        }

        for failure in failures {
            print("SCHEDULER_WRONG: \(failure)")
        }
        print(failures.isEmpty ? "SCHEDULER_OK" : "SCHEDULER_FAILED")
    }
}

/// Tiny async flag for the cooperative half of `runSelfTest`.
private actor Gate {
    private(set) var hasStarted = false
    func markStarted() { hasStarted = true }
}

/// Coordinates the checkpoint half of `runSelfTest`: notes waits until ASR
/// has preempted before calling `checkpoint`, so the park is observable.
private actor CheckpointGate {
    private(set) var hasRunning = false
    private(set) var hasResumed = false
    private var asrHeld = false
    private var asrWaiter: CheckedContinuation<Void, Never>?

    func markRunning() { hasRunning = true }
    func markResumed() { hasResumed = true }

    func signalASRHeld() {
        asrHeld = true
        if let asrWaiter {
            self.asrWaiter = nil
            asrWaiter.resume()
        }
    }

    func waitUntilASRHeld() async {
        if asrHeld { return }
        await withCheckedContinuation { asrWaiter = $0 }
    }
}
