import Foundation
import FluidAudio

/// Audio transcription service using FluidAudio
struct FluidTranscriptionService {
    struct ModelDescriptor {
        let id: String
        let displayName: String
        private let matchingIdentifiers: Set<String>

        init(id: String, displayName: String, aliases: [String] = []) {
            self.id = id
            self.displayName = displayName
            var identifiers = Set<String>()
            identifiers.insert(id.lowercased())
            for alias in aliases {
                identifiers.insert(alias.lowercased())
            }
            self.matchingIdentifiers = identifiers
        }

        func matches(_ rawIdentifier: String) -> Bool {
            matchingIdentifiers.contains(rawIdentifier.lowercased())
        }

        var allIdentifiers: [String] {
            Array(matchingIdentifiers).sorted()
        }
    }

    typealias TranscriptionSegment = WhisperSubtitleFormatter.TranscriptionSegment

    struct TranscriptionResult {
        let text: String
        let segments: [TranscriptionSegment]
        let duration: TimeInterval
        let speakerSegments: [SpeakerSegment]
    }

    struct SpeakerSegment {
        let speakerId: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let text: String
    }

    private static let sentenceTerminators: Set<Character> = [
        ".",
        "!",
        "?",
        "。",
        "！",
        "？",
        "؟",
        "۔",
        "।"
    ]
    private static let tokenGapBreak: TimeInterval = 1.2
    private static let maxSegmentDuration: TimeInterval = 7.5
    private static let minSegmentDuration: TimeInterval = 0.06
    
    /// Regex pattern to collapse multiple whitespace characters into a single space
    private static let whitespacePattern = "\\s+"

    private static let availableModelsInternal: [ModelDescriptor] = [
        ModelDescriptor(
            id: "parakeet-tdt-0.6b-v3",
            displayName: "Parakeet TDT v3 (0.6B)",
            aliases: ["default", "fluid-default", "parakeet-tdt-0.6b-v3-coreml"]
        )
    ]

    static var availableModels: [ModelDescriptor] { availableModelsInternal }

    static var defaultModel: ModelDescriptor {
        guard let model = availableModelsInternal.first else {
            fatalError("FluidAudio model catalog is empty")
        }
        return model
    }

    static func modelDescriptor(for rawIdentifier: String) -> ModelDescriptor? {
        let normalized = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return availableModelsInternal.first { $0.matches(normalized) }
    }

    static var availableModelIDs: [String] {
        availableModelsInternal.map { $0.id }
    }

    static func cacheDirectory(for version: AsrModelVersion = .v3) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "WhisperServer"
        let base = appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("FluidAudio", isDirectory: true)
        let defaultLeaf = AsrModels.defaultCacheDirectory(for: version).lastPathComponent
        return base.appendingPathComponent(defaultLeaf, isDirectory: true)
    }

    static func diarizerCacheDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "WhisperServer"
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("speaker-diarization-coreml", isDirectory: true)
    }

    // MARK: - Public API

    /// Transcribe a file to plain text using FluidAudio (non-streaming)
    /// - Parameters:
    ///   - audioURL: URL to the input audio file
    ///   - language: Optional BCP-47 language code (e.g., "en", "ru-RU"). Defaults to current locale when nil.
    /// - Returns: Recognized text, or nil on failure
    static func transcribeText(
        at audioURL: URL,
        language _: String?,
        model _: ModelDescriptor = FluidTranscriptionService.defaultModel
    ) async -> String? {
        // TODO: Apply model selection when FluidAudio API supports it
        do {
            let models = try await AsrModels.downloadAndLoad(to: prepareCacheDirectory())
            let asrManager = AsrManager(config: .default)
            try await asrManager.initialize(models: models)

            guard let asrResult = try await runTranscription(using: asrManager, audioURL: audioURL) else {
                return nil
            }
            return extractTrimmedText(from: asrResult)
        } catch {
            print("❌ FluidAudio transcription failed: \(error)")
            return nil
        }
    }

    /// Transcribe a file and return segment information with timing metadata.
    /// - Parameters:
    ///   - audioURL: URL to the input audio file
    ///   - language: Optional BCP-47 language code.
    ///   - model: Model descriptor to use for transcription.
    /// - Returns: A structured transcription result, or nil when recognition fails.
    static func transcribeAudio(
        at audioURL: URL,
        language _: String?,
        model _: ModelDescriptor = FluidTranscriptionService.defaultModel,
        includeDiarization: Bool = false
    ) async -> TranscriptionResult? {
        // TODO: Apply model selection when FluidAudio API supports it
        // Currently AsrModels.downloadAndLoad() uses the default model without allowing selection
        do {
            let models = try await AsrModels.downloadAndLoad(to: prepareCacheDirectory())
            let asrManager = AsrManager(config: .default)
            try await asrManager.initialize(models: models)

            guard let asrResult = try await runTranscription(using: asrManager, audioURL: audioURL) else {
                return nil
            }

            return await makeTranscriptionResult(
                from: asrResult,
                audioURL: audioURL,
                includeDiarization: includeDiarization
            )
        } catch {
            print("❌ FluidAudio transcription failed: \(error)")
            return nil
        }
    }

    // MARK: - Helpers

    private static func makeTranscriptionResult(
        from asrResult: ASRResult,
        audioURL: URL,
        includeDiarization: Bool
    ) async -> TranscriptionResult? {
        guard let trimmedText = extractTrimmedText(from: asrResult) else { return nil }

        let segments = buildSegments(
            from: asrResult.tokenTimings ?? [],
            fallbackText: trimmedText,
            duration: asrResult.duration
        )

        return TranscriptionResult(
            text: trimmedText,
            segments: segments,
            duration: asrResult.duration,
            speakerSegments: includeDiarization
                ? await runDiarization(
                    for: audioURL,
                    tokenTimings: asrResult.tokenTimings ?? [],
                    fallbackText: trimmedText,
                    duration: asrResult.duration
                )
                : []
        )
    }

    private static func extractTrimmedText(from asrResult: ASRResult) -> String? {
        let trimmed = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func runTranscription(using asrManager: AsrManager, audioURL: URL) async throws -> ASRResult? {
        if
            let samples = WhisperAudioConverter.convertToWhisperFormat(from: audioURL),
            !samples.isEmpty
        {
            let sampleResult = try await asrManager.transcribe(samples, source: .system)
            if extractTrimmedText(from: sampleResult) != nil {
                if !(sampleResult.tokenTimings?.isEmpty ?? true) {
                    return sampleResult
                }
                let directResult = try await asrManager.transcribe(audioURL, source: .system)
                if let directTrimmed = extractTrimmedText(from: directResult) {
                    if !(directResult.tokenTimings?.isEmpty ?? true) {
                        return directResult
                    }
                    // Timings missing in both runs; prefer direct result to align with file duration.
                    return directResult
                }
                return sampleResult
            }
        }

        let fileResult = try await asrManager.transcribe(audioURL, source: .system)
        guard extractTrimmedText(from: fileResult) != nil else { return nil }
        return fileResult
    }

    private static func runDiarization(
        for audioURL: URL,
        tokenTimings: [TokenTiming],
        fallbackText: String,
        duration: TimeInterval
    ) async -> [SpeakerSegment] {
        do {
            let converter = AudioConverter()
            let samples = try converter.resampleAudioFile(audioURL)
            guard !samples.isEmpty else { return [] }

            guard let diarizationResult = try await FluidDiarizerCoordinator.shared.diarize(samples: samples) else {
                return []
            }

            let speakerSegments = mapDiarizationSegments(
                diarizationResult.segments,
                tokens: tokenTimings,
                duration: duration
            )

            if speakerSegments.isEmpty,
               !fallbackText.isEmpty,
               let firstSegment = diarizationResult.segments.first
            {
                let speakerIdentifier = String(describing: firstSegment.speakerId)
                return [
                    SpeakerSegment(
                        speakerId: speakerIdentifier,
                        startTime: 0.0,
                        endTime: duration,
                        text: fallbackText
                    )
                ]
            }

            return speakerSegments
        } catch {
            print("⚠️ FluidAudio diarization failed: \(error)")
            return []
        }
    }

    private static func normalizeSegmentText(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }

        var normalized = raw.replacingOccurrences(of: "\n", with: " ")
        normalized = normalized.replacingOccurrences(
            of: whitespacePattern,
            with: " ",
            options: .regularExpression
        )

        let spacingFixes: [String: String] = [
            " ,": ",",
            " .": ".",
            " !": "!",
            " ?": "?",
            " :": ":",
            " ;": ";",
            " n't": "n't",
            " '": "'"
        ]

        for (pattern, replacement) in spacingFixes {
            normalized = normalized.replacingOccurrences(of: pattern, with: replacement)
        }

        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized = stripLeadingArtifacts(from: normalized)
        return normalized
    }

    private static func buildSegments(
        from tokenTimings: [TokenTiming],
        fallbackText: String,
        duration: TimeInterval
    ) -> [TranscriptionSegment] {
        guard !tokenTimings.isEmpty else {
            return fallbackSegments(text: fallbackText, duration: duration)
        }

        let sortedTokens = sortedTokenTimings(tokenTimings)

        var segments: [TranscriptionSegment] = []
        var currentStart: TimeInterval?
        var lastEnd: TimeInterval?
        var previousTokenEnd: TimeInterval?
        var buffer = ""
        var invalidTokenCount = 0

        func closeSegment() {
            guard let start = currentStart, let end = lastEnd else {
                buffer = ""
                currentStart = nil
                lastEnd = nil
                return
            }

            let text = normalizeSegmentText(buffer)
            buffer = ""
            currentStart = nil
            lastEnd = nil

            guard !text.isEmpty else { return }
            let cappedEnd = min(end, duration)
            let finalEnd = max(cappedEnd, start + minSegmentDuration)
            segments.append(
                TranscriptionSegment(
                    startTime: start,
                    endTime: finalEnd,
                    text: text
                )
            )
        }

        for token in sortedTokens {
            // Validate token timing
            guard token.startTime >= 0, token.endTime >= token.startTime else {
                invalidTokenCount += 1
                continue
            }
            
            let start = token.startTime
            let end = max(token.endTime, start + minSegmentDuration)

            if let previousEnd = previousTokenEnd, start - previousEnd >= tokenGapBreak {
                closeSegment()
            }

            if currentStart == nil {
                currentStart = start
            }

            buffer += token.token
            lastEnd = end

            let trimmedToken = token.token.trimmingCharacters(in: .whitespacesAndNewlines)
            var shouldClose = false

            if let lastCharacter = trimmedToken.last, sentenceTerminators.contains(lastCharacter) {
                shouldClose = true
            }

            if token.token.contains("\n") {
                shouldClose = true
            }

            if let segmentStart = currentStart, end - segmentStart >= maxSegmentDuration {
                shouldClose = true
            }

            if shouldClose {
                closeSegment()
            }

            previousTokenEnd = end
        }

        closeSegment()

        if invalidTokenCount > 0 {
            print("⚠️ Skipped \(invalidTokenCount) token(s) with invalid timing")
        }

        if segments.isEmpty {
            print("⚠️ No valid segments created from \(sortedTokens.count) tokens, using fallback")
            return fallbackSegments(text: fallbackText, duration: duration)
        }

        return segments
    }

    private static func fallbackSegments(text: String, duration: TimeInterval) -> [TranscriptionSegment] {
        let cleaned = normalizeSegmentText(text)
        guard !cleaned.isEmpty else { return [] }

        let fallbackDuration = max(duration, minSegmentDuration * 2)
        return [
            TranscriptionSegment(
                startTime: 0.0,
                endTime: fallbackDuration,
                text: cleaned
            )
        ]
    }

    private static let leadingTrimCharacters: Set<Character> = [",", ".", "!", "?", ":", ";"]

    private static func stripLeadingArtifacts(from text: String) -> String {
        var result = text
        while
            let first = result.first,
            leadingTrimCharacters.contains(first),
            result.dropFirst().contains(where: { $0.isLetter || $0.isNumber })
        {
            result.removeFirst()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func prepareCacheDirectory(version: AsrModelVersion = .v3) -> URL {
        let directory = cacheDirectory(for: version)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("⚠️ Failed to create FluidAudio cache directory: \(error)")
        }
        return directory
    }

    static func prepareDiarizerCacheDirectory() -> URL {
        let directory = diarizerCacheDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("⚠️ Failed to create FluidAudio diarizer directory: \(error)")
        }
        return directory
    }

    static func sortedTokenTimings(_ tokenTimings: [TokenTiming]) -> [TokenTiming] {
        guard tokenTimings.count > 1 else { return tokenTimings }
        let requiresSort = tokenTimings.indices.dropFirst().contains { index in
            tokenTimings[index].startTime < tokenTimings[index - 1].startTime
        }
        if requiresSort {
            print("⚠️ Token timings are not sorted, sorting now")
            return tokenTimings.sorted { $0.startTime < $1.startTime }
        }
        return tokenTimings
    }

    static func mapDiarizationSegments(
        _ diarizationSegments: [TimedSpeakerSegment],
        tokens: [TokenTiming],
        duration: TimeInterval
    ) -> [SpeakerSegment] {
        guard !diarizationSegments.isEmpty else { return [] }
        guard duration.isFinite, duration > 0 else { return [] }

        let sortedTokens = sortedTokenTimings(tokens)
        var speakerSegments: [SpeakerSegment] = []
        var currentTokenIndex = 0

        for diarSegment in diarizationSegments {
            let diarStart = TimeInterval(diarSegment.startTimeSeconds)
            let diarEnd = TimeInterval(diarSegment.endTimeSeconds)
            let sanitizedStart = max(0.0, diarStart)
            let sanitizedEnd = min(duration, max(sanitizedStart, diarEnd))

            guard sanitizedEnd > sanitizedStart else { continue }
            guard sanitizedStart.isFinite, sanitizedEnd.isFinite else { continue }

            while currentTokenIndex < sortedTokens.count,
                  sortedTokens[currentTokenIndex].endTime <= sanitizedStart {
                currentTokenIndex += 1
            }

            var buffer = ""
            var scanIndex = currentTokenIndex

            while scanIndex < sortedTokens.count {
                let token = sortedTokens[scanIndex]
                if token.startTime >= sanitizedEnd {
                    break
                }

                if token.endTime > sanitizedStart {
                    buffer += token.token
                }
                scanIndex += 1
            }

            let normalizedText = normalizeSegmentText(buffer)
            if !normalizedText.isEmpty {
                let speakerIdentifier = String(describing: diarSegment.speakerId)
                speakerSegments.append(
                    SpeakerSegment(
                        speakerId: speakerIdentifier,
                        startTime: sanitizedStart,
                        endTime: sanitizedEnd,
                        text: normalizedText
                    )
                )
            }

            currentTokenIndex = scanIndex
        }

        return speakerSegments
    }
}

private actor FluidDiarizerCoordinator {
    static let shared = FluidDiarizerCoordinator()

    private var diarizer: DiarizerManager?

    func diarize(samples: [Float]) async throws -> DiarizationResult? {
        guard !samples.isEmpty else { return nil }
        let manager = try await resolveManager()
        return try manager.performCompleteDiarization(samples)
    }

    func reset() {
        diarizer?.cleanup()
        diarizer = nil
    }

    private func resolveManager() async throws -> DiarizerManager {
        if let existing = diarizer {
            return existing
        }

        let models = try await DiarizerModels.downloadIfNeeded(to: FluidTranscriptionService.prepareDiarizerCacheDirectory())
        let manager = DiarizerManager()
        manager.initialize(models: models)
        diarizer = manager
        return manager
    }
}
