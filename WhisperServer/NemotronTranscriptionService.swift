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
    /// Samples fed per `process` call (~22.4 s = 10 model chunks) to bound peak
    /// per-call buffer size on long files.
    private static let feedSliceSamples = 358_400

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

    /// Cache directory for a variant's downloaded models (for download-state UI and deletion).
    static func cacheDirectory(for variant: Variant) -> URL {
        switch variant {
        case .english:
            return cacheBaseDirectory().appendingPathComponent(
                "nemotron-speech-streaming-en-0.6b-coreml", isDirectory: true)
        case .multilingual:
            return cacheBaseDirectory().appendingPathComponent(
                "Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML", isDirectory: true)
        }
    }

    static func isModelDownloaded(_ variant: Variant) -> Bool {
        let dir = cacheDirectory(for: variant)
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

        for slice in sampleSlices(samples) {
            _ = try await manager.process(samples: Array(slice))
        }
        let result = try await manager.finishWithTokenTimings()
        await manager.cleanup()
        return (result.text, result.timings)
    }

    // MARK: - Helpers

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
