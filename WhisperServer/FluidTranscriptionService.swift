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
            let models = try await AsrModels.downloadAndLoad()
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
        model _: ModelDescriptor = FluidTranscriptionService.defaultModel
    ) async -> TranscriptionResult? {
        // TODO: Apply model selection when FluidAudio API supports it
        // Currently AsrModels.downloadAndLoad() uses the default model without allowing selection
        do {
            let models = try await AsrModels.downloadAndLoad()
            let asrManager = AsrManager(config: .default)
            try await asrManager.initialize(models: models)

            guard let asrResult = try await runTranscription(using: asrManager, audioURL: audioURL) else {
                return nil
            }

            return makeTranscriptionResult(from: asrResult)
        } catch {
            print("❌ FluidAudio transcription failed: \(error)")
            return nil
        }
    }

    // MARK: - Helpers

    private static func makeTranscriptionResult(from asrResult: ASRResult) -> TranscriptionResult? {
        guard let trimmedText = extractTrimmedText(from: asrResult) else { return nil }

        let segments = buildSegments(
            from: asrResult.tokenTimings ?? [],
            fallbackText: trimmedText,
            duration: asrResult.duration
        )

        return TranscriptionResult(
            text: trimmedText,
            segments: segments,
            duration: asrResult.duration
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

        // Optimize sorting: check if already sorted before creating a new array
        let sortedTokens: [TokenTiming]
        let needsSorting = tokenTimings.indices.dropFirst().contains { i in
            tokenTimings[i].startTime < tokenTimings[i - 1].startTime
        }
        if needsSorting {
            print("⚠️ Token timings are not sorted, sorting now")
            sortedTokens = tokenTimings.sorted(by: { $0.startTime < $1.startTime })
        } else {
            sortedTokens = tokenTimings
        }

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
}
