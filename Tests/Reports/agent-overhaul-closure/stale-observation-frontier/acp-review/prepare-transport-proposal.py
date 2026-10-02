from pathlib import Path
import hashlib
import json

out = Path(__file__).resolve().parent
root = out.parents[4]
source_path = root / 'Sources/NextNotes/Agent/Backend/JSONRPCStdioClient.swift'
source = source_path.read_text()
(out / 'original-JSONRPCStdioClient.swift.txt').write_text(source)
candidate = source.replace('    private var closed = false\n', '''    private var closed = false
    // EOF is terminal only after every already-started output read dispatched
    // its final parsed frames. One stream, the existing lock, no queue/timer.
    private var activeOutputReads = 0
    private var sawOutputEOF = false
''', 1)
old = '''        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.ingest(chunk)
        }'''
candidate = candidate.replace(old, '''        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.readOutput(handle)
        }''', 1)
candidate = candidate.replace('''            lock.lock()
            pending[id] = continuation
            lock.unlock()''', '''            lock.lock()
            guard !closed else {
                lock.unlock()
                continuation.resume(throwing: JSONRPCError(message: "Session closed."))
                return
            }
            pending[id] = continuation
            lock.unlock()''', 1)
start = candidate.index('    func close() {')
end = candidate.index('    private func write(', start)
candidate = candidate[:start] + '''    func close() {
        lock.lock()
        let leftover = stopLocked()
        lock.unlock()
        guard let leftover else { return }
        finish(leftover, error: JSONRPCError(message: "Session closed."))
    }

    /// Caller holds the existing state lock; response/timeout/EOF/close compete
    /// for each continuation exactly once through the same pending dictionary.
    private func stopLocked() -> [Int: CheckedContinuation<Data, Error>]? {
        guard !closed else { return nil }
        closed = true
        let leftover = pending
        pending.removeAll()
        return leftover
    }

    private func finish(_ leftover: [Int: CheckedContinuation<Data, Error>], error: JSONRPCError) {
        stdout.fileHandleForReading.readabilityHandler = nil
        writeLock.lock()
        try? stdin.fileHandleForWriting.close()
        writeLock.unlock()
        if process.isRunning { process.terminate() }
        for (_, continuation) in leftover { continuation.resume(throwing: error) }
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

''' + candidate[end:]
start = candidate.index('    private func ingest(')
end = candidate.index('    private func popMessageLocked()', start)
candidate = candidate[:start] + '''    private func readOutput(_ handle: FileHandle) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        activeOutputReads += 1
        lock.unlock()
        // Do not hold the state lock across the existing FileHandle read.
        let chunk = handle.availableData
        lock.lock()
        if !closed {
            if chunk.isEmpty {
                sawOutputEOF = true
            } else {
                buffer.append(chunk)
                // Detach final responses before EOF can drain their continuations.
                while let message = popMessageLocked() { dispatchLocked(message) }
            }
        }
        activeOutputReads -= 1
        let leftover = !closed && sawOutputEOF && activeOutputReads == 0 ? stopLocked() : nil
        lock.unlock()
        if let leftover {
            finish(leftover, error: JSONRPCError(message: "Session output ended."))
        }
    }

''' + candidate[end:]
candidate = candidate.replace('    private func dispatch(_ message:', '    private func dispatchLocked(_ message:', 1)
candidate = candidate.replace('''            let (continuation, precedingNotifications) = lock.withLock {
                (pending.removeValue(forKey: id), notificationTail)
            }''', '''            let continuation = pending.removeValue(forKey: id)
            let precedingNotifications = notificationTail''', 1)
candidate = candidate.replace('            let handler = lock.withLock { incomingHandler }', '            let handler = incomingHandler', 1)
candidate = candidate.replace('''            lock.lock()
            let preceding = notificationTail''', '''            let preceding = notificationTail''', 1)
candidate = candidate.replace('''            }
            lock.unlock()
        }
    }

    private func fail''', '''            }
        }
    }

    private func fail''', 1)
assert 'self?.ingest' not in candidate and 'dispatch(message)' not in candidate
(out / 'proposed-JSONRPCStdioClient.swift.txt').write_text(candidate)
paths = ['Sources/NextNotes/Agent/Backend/JSONRPCStdioClient.swift',
         'Sources/NextNotes/Agent/Backend/ACPSession.swift',
         'Sources/NextNotes/Agent/Backend/ACPAgentBackend.swift',
         'Sources/NextNotes/Agent/Backend/ACPCompatibilityCLIBackend.swift',
         'Sources/NextNotes/Agent/Backend/AgentStdioFixtures.swift']
(out / 'source-identities.json').write_text(json.dumps({path: hashlib.sha256((root / path).read_bytes()).hexdigest() for path in paths}, indent=2) + '\n')
