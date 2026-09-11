import Foundation
import AVFoundation
import FluidAudio

/// Transcription with NVIDIA Nemotron streaming ASR models (CoreML, via FluidAudio).
///
/// Nemotron is a cache-aware streaming model: audio is fed in fixed chunks and the
/// encoder carries state between them. For the batch HTTP endpoint we feed the whole
/// decoded file through the streaming manager and collect the final transcript.
struct NemotronTranscriptionService {
    typealias TranscriptionResult = FluidTranscriptionService.TranscriptionResult

    enum Variant: String {
        case english
        case multilingual
    }

    /// Chunk tier used for both variants. 2240 ms is FluidAudio's recommended
    /// default: highest throughput at no accuracy cost vs the smaller tiers.
    private static let chunkMs = 2240
    private static let sampleRate = 16_000
    /// Samples fed per `process` call: exactly one 2240 ms model chunk (35 840
    /// samples @ 16 kHz). The streaming managers accumulate partial text per
    /// call; feeding multiple chunks per call can drop early-chunk text.
    private static let feedSliceSamples = 35_840

    static func variant(forModelID id: String) -> Variant? {
        let normalized = id.lowercased()
        if normalized.contains("multilingual") || normalized.contains("3.5") { return .multilingual }
        if normalized.contains("nemotron") { return .english }
        return nil
    }

    /// Base directory that FluidAudio managers append their repo folder to.
    static func cacheBaseDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "WhisperServer"
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("FluidAudio", isDirectory: true)
    }

    /// Match the downloader's local layout, which differs from the Hugging Face repo names.
    /// The multilingual root includes both Latin and full multilingual vocabulary caches.
    static func cacheDirectory(for variant: Variant, baseDirectory: URL? = nil) -> URL {
        let base = baseDirectory ?? cacheBaseDirectory()
        switch variant {
        case .english:
            return base.appendingPathComponent(
                NemotronChunkSize.ms2240.repo.folderName, isDirectory: true)
        case .multilingual:
            return base.appendingPathComponent(
                Repo.nemotronMultilingual.folderName, isDirectory: true)
        }
    }

    static func isModelDownloaded(_ variant: Variant, baseDirectory: URL? = nil) -> Bool {
        let dir = cacheDirectory(for: variant, baseDirectory: baseDirectory)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return !contents.isEmpty
    }

    // MARK: - Public API

    static func transcribeText(at audioURL: URL, language: String?, variant: Variant) async -> String? {
        await transcribeAudio(at: audioURL, language: language, variant: variant, includeDiarization: false)?.text
    }

    static func transcribeAudio(
        at audioURL: URL,
        language: String?,
        variant: Variant,
        includeDiarization: Bool = false
    ) async -> TranscriptionResult? {
        guard
            let samples = WhisperAudioConverter.convertToWhisperFormat(from: audioURL),
            !samples.isEmpty
        else {
            print("❌ Nemotron: failed to decode audio to 16 kHz mono PCM")
            return nil
        }

        let duration = TimeInterval(samples.count) / TimeInterval(sampleRate)

        do {
            let (text, timings): (String, [TokenTiming])
            switch variant {
            case .english:
                (text, timings) = try await transcribeEnglish(samples: samples)
            case .multilingual:
                (text, timings) = try await transcribeMultilingual(samples: samples, language: language)
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let segments = FluidTranscriptionService.buildSegments(
                from: timings,
                fallbackText: trimmed,
                duration: duration
            )

            return TranscriptionResult(
                text: trimmed,
                segments: segments,
                duration: duration,
                speakerSegments: includeDiarization
                    ? await FluidTranscriptionService.runDiarization(
                        for: audioURL,
                        tokenTimings: timings,
                        fallbackText: trimmed,
                        duration: duration
                    )
                    : []
            )
        } catch {
            print("❌ Nemotron transcription failed: \(error)")
            return nil
        }
    }

    // MARK: - Variant runners

    private static func transcribeEnglish(samples: [Float]) async throws -> (String, [TokenTiming]) {
        let manager = StreamingNemotronAsrManager(requestedChunkSize: .ms2240)
        try await manager.loadModels(to: cacheBaseDirectory())

        for slice in sampleSlices(samples) {
            guard let buffer = makePCMBuffer(from: slice) else {
                throw NemotronServiceError.bufferAllocationFailed
            }
            _ = try await manager.process(audioBuffer: buffer)
        }
        let result = try await manager.finishWithTokenTimings()
        await manager.cleanup()
        return (result.text, result.timings)
    }

    /// The multilingual model's cache-aware encoder needs left context before it
    /// starts emitting tokens: speech in the first ~2 chunks of a session is
    /// dropped otherwise (verified against FluidAudio's own CLI). For batch files
    /// we prime the session with 2 chunks of leading silence and flush the tail
    /// with 1 more, then shift token timings back by the lead-in.
    private static let multilingualLeadPadChunks = 2
    private static let multilingualTailPadChunks = 1

    private static func transcribeMultilingual(
        samples: [Float],
        language: String?
    ) async throws -> (String, [TokenTiming]) {
        let languageCode = normalizedLanguageCode(language)
        let variantDir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: languageCode,
            chunkMs: chunkMs,
            to: cacheBaseDirectory()
        )

        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: variantDir)
        await manager.setLanguage(languageCode)

        let chunkSamples = chunkMs * sampleRate / 1000
        let leadPad = [Float](repeating: 0, count: multilingualLeadPadChunks * chunkSamples)
        let tailPad = [Float](repeating: 0, count: multilingualTailPadChunks * chunkSamples)

        for slice in sampleSlices(leadPad + samples + tailPad) {
            _ = try await manager.process(samples: Array(slice))
        }
        let result = try await manager.finishWithTokenTimings()
        await manager.cleanup()

        let leadPadSeconds = TimeInterval(leadPad.count) / TimeInterval(sampleRate)
        let shifted = restoreTokenTimings(
            result.timings,
            leadingPadding: leadPadSeconds,
            duration: TimeInterval(samples.count) / TimeInterval(sampleRate)
        )
        return (result.text, shifted)
    }

    // MARK: - Helpers

    /// Restore the original recording's time domain without dropping final words.
    /// FluidAudio's finish timings describe token emission, so a lexical token in
    /// the flush padding may be delayed speech, not a silence hallucination. Keep
    /// its text/id/confidence and anchor it to the final valid interval; timestamps
    /// alone cannot distinguish those cases. This monotone mapping also preserves
    /// word order when crossing-EOF and fully delayed tokens share the endpoint.
    /// Discard explicit blank/pad tokens, not lexical tokens in the padded time range.
    /// Word separators stay intact, but buildSegments ignores their duration. Use
    /// the same restored timings for subtitles and diarization.
    static func restoreTokenTimings(
        _ timings: [TokenTiming],
        leadingPadding: TimeInterval,
        duration: TimeInterval
    ) -> [TokenTiming] {
        guard leadingPadding.isFinite, leadingPadding >= 0 else { return [] }
        var restored: [TokenTiming] = []
        restored.reserveCapacity(timings.count)
        for timing in timings {
            guard !FluidTranscriptionService.isPaddingToken(timing.token) else { continue }
            guard let bounds = FluidTranscriptionService.boundedTimeRange(
                start: timing.startTime - leadingPadding,
                end: timing.endTime - leadingPadding,
                duration: duration
            ) else {
                // Let the caller use the complete result.text as a bounded fallback
                // rather than silently omitting words whose timings are unusable.
                return []
            }
            restored.append(TokenTiming(
                token: timing.token,
                tokenId: timing.tokenId,
                startTime: bounds.start,
                endTime: bounds.end,
                confidence: timing.confidence
            ))
        }
        return restored
    }

    /// Maps request languages ("de", "de-DE", nil) onto the FLEURS-style codes the
    /// multilingual manager expects; nil/empty means model-side auto-detection.
    private static func normalizedLanguageCode(_ language: String?) -> String {
        guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty else {
            return "auto"
        }
        return language
    }

    private static func sampleSlices(_ samples: [Float]) -> [ArraySlice<Float>] {
        stride(from: 0, to: samples.count, by: feedSliceSamples).map {
            samples[$0..<min($0 + feedSliceSamples, samples.count)]
        }
    }

    private static func makePCMBuffer(from slice: ArraySlice<Float>) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(slice.count))
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(slice.count)
        if let channelData = buffer.floatChannelData {
            slice.withUnsafeBufferPointer { source in
                channelData[0].update(from: source.baseAddress!, count: slice.count)
            }
        }
        return buffer
    }

    enum NemotronServiceError: Error {
        case bufferAllocationFailed
    }
}
