import NextNotesDictionary
import AVFoundation
import Foundation
import Speech

/// Streaming on-device transcription via macOS 26's `SpeechAnalyzer` / `SpeechTranscriber`.
///
/// No model ships with the app — the OS downloads and manages the assets, so the first
/// run for a given locale may block briefly while `AssetInstallationRequest` completes.
actor AppleSpeechEngine: TranscriptionEngine {
    private let locale: Locale

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    /// Text the engine has committed. Volatile results are appended on top for display
    /// but discarded as soon as a final result covering the same range arrives.
    private var finalizedText = ""

    init(locale: Locale = Locale.current) {
        self.locale = locale
    }

    func preferredInputFormat() async -> AVAudioFormat? {
        let module = transcriber ?? Self.makeTranscriber(locale: locale)
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.localeUnsupported(locale)
        }

        let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            ?? Locale(identifier: "en-US")

        let transcriber = Self.makeTranscriber(locale: resolvedLocale)
        self.transcriber = transcriber

        try await Self.ensureModelInstalled(for: transcriber)

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inputContinuation

        // Bias the recognizer toward the dictionary's words — and a few of the names visible
        // on screen — before it hears anything. This is a nudge, not a guarantee:
        // `DictionaryCorrector` is the pass that actually enforces spelling, and the cleanup
        // prompt is where a spoken file name is actually resolved. But it's free and it catches
        // things a post-hoc rewrite can't, like a name the engine would otherwise split into
        // two ordinary words.
        //
        // The list is capped at `DictionaryCorrector.biasLimit`. A long context list makes
        // these models drift: on quiet or ambiguous audio they start emitting the terms they
        // were primed with, which is a far worse failure than the misspelling it prevents.
        // Only the input-sequence initializers take a context up front, and this analyzer is
        // fed by `analyzer.start(inputSequence:)` later — so the context is applied here
        // instead. It must be set before any audio arrives to affect recognition.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        if let context = await Self.context() {
            try? await analyzer.setContext(context)
        }

        finalizedText = ""

        let (chunks, chunkContinuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()

        // Drain the transcriber's results into our simpler chunk stream.
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { break }
                    let snapshot = await self.absorb(result)
                    chunkContinuation.yield(TranscriptionChunk(text: snapshot, isFinal: false))
                }
                let final = await self?.finalizedText ?? ""
                chunkContinuation.yield(TranscriptionChunk(text: final, isFinal: true))
                chunkContinuation.finish()
            } catch {
                Log.speech.error("results stream failed: \(error.localizedDescription, privacy: .public)")
                chunkContinuation.finish(throwing: error)
            }
        }

        try await analyzer.start(inputSequence: inputStream)
        Log.speech.info("SpeechAnalyzer started for \(resolvedLocale.identifier)")

        return chunks
    }

    func feed(_ chunk: AudioChunk) async {
        inputContinuation?.yield(AnalyzerInput(buffer: chunk.buffer))
    }

    func finish() async {
        inputContinuation?.finish()
        inputContinuation = nil

        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.speech.error("finalize failed: \(error.localizedDescription, privacy: .public)")
            await analyzer?.cancelAndFinishNow()
        }

        analyzer = nil
        transcriber = nil
        resultsTask = nil
    }

    // MARK: - Result accumulation

    /// Folds one result into the running transcript and returns the full text to display.
    ///
    /// Final results are committed; a volatile result is shown appended to the committed
    /// text but never stored, so the next revision replaces it cleanly.
    private func absorb(_ result: SpeechTranscriber.Result) -> String {
        let text = String(result.text.characters)
        guard result.isFinal else {
            return (finalizedText + text).trimmingCharacters(in: .whitespaces)
        }
        finalizedText += text
        return finalizedText.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Setup helpers

    /// The dictionary's words plus a small slice of the names harvested from the app the text
    /// is going into, handed to the analyzer as contextual strings.
    ///
    /// Reads both stores on the main actor because that's where they live; the resulting array
    /// of strings is plain value data and crosses back safely.
    /// - Returns: nil when there is nothing to bias with, so an empty context is never set for
    ///   nothing.
    ///
    /// Hops to the main actor rather than asserting it. The stores are main-actor isolated and
    /// this runs on the engine's own executor — `MainActor.assumeIsolated` here doesn't check
    /// that claim, it asserts it, and takes the whole process down when it's false.
    /// `OutputProfileStore.startTrackingFrontmostApp` records the same reasoning.
    private static func context() async -> AnalysisContext? {
        // Sixty milliseconds against the harvester's 120 ms budget, and short of it on purpose.
        // Contextual strings have to be set before the first audio buffer arrives, so this wait
        // sits in front of the recording: a bias name that misses the deadline is invisible,
        // while a late start costs the user the first word of their sentence. Timing out does
        // not cancel the walk — the cleanup pass wants that same result a few seconds later.
        let harvested = await ScreenContextStore.shared
            .awaitCapture(within: .milliseconds(60))
            .biasPhrases()

        // Both numbers, because the asymmetry between the two lists is the counter-intuitive
        // part of this feature and the log is where anyone checks it against a real run. A line
        // reading `40 + 0` is a full dictionary crowding the harvest out, which is correct and
        // otherwise indistinguishable from a harvest that silently returned nothing.
        let (phrases, dictionaryCount) = await MainActor.run { () -> ([String], Int) in
            let store = DictionaryStore.shared
            return (store.biasPhrases(withHarvested: harvested), store.biasPhrases.count)
        }
        guard !phrases.isEmpty else { return nil }

        let context = AnalysisContext()
        context.contextualStrings[.general] = phrases
        Log.speech.info("""
            biasing with \(dictionaryCount, privacy: .public) dictionary phrase(s) \
            + \(phrases.count - dictionaryCount, privacy: .public) screen name(s)
            """)
        return context
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // `.volatileResults` is what makes live text appear while you're still talking.
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    private static func ensureModelInstalled(for transcriber: SpeechTranscriber) async throws {
        let installed = await SpeechTranscriber.installedLocales
        let selected = transcriber.selectedLocales
        let alreadyThere = selected.allSatisfy { locale in
            installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        }
        guard !alreadyThere else { return }

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Log.speech.info("downloading speech model…")
                try await request.downloadAndInstall()
                Log.speech.info("speech model installed")
            }
        } catch {
            throw TranscriptionError.modelInstallFailed(error.localizedDescription)
        }
    }
}
