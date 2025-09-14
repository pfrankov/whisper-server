import Foundation
import FluidAudio

/// Audio transcription service using FluidAudio
struct FluidTranscriptionService {
    // MARK: - Public API

    /// Transcribe a file to plain text using FluidAudio (non-streaming)
    /// - Parameters:
    ///   - audioURL: URL to the input audio file
    ///   - language: Optional BCP-47 language code (e.g., "en", "ru-RU"). Defaults to current locale when nil.
    /// - Returns: Recognized text, or nil on failure
    static func transcribeText(at audioURL: URL, language: String?) async -> String? {
        do {
            // Download and load ASR models (cached between runs)
            let models = try await AsrModels.downloadAndLoad()
            let asrManager = AsrManager(config: .default)
            try await asrManager.initialize(models: models)

            // Prefer robust local conversion to 16kHz mono float
            if let samples = WhisperAudioConverter.convertToWhisperFormat(from: audioURL), !samples.isEmpty {
                let result = try await asrManager.transcribe(samples, source: .system)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
                // Fallback: try direct file path if sample conversion yielded empty
            }

            // Fallback to direct file processing
            let result = try await asrManager.transcribe(audioURL, source: .system)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("❌ FluidAudio transcription failed: \(error)")
            return nil
        }
    }

    // MARK: - Helpers

    // Intentionally left empty for this integration: AsrModels handles model download

    /// Convert language code to Locale with a reasonable default
    private static func normalizedLocale(from language: String?) -> Locale {
        if let language, !language.isEmpty {
            return Locale(identifier: language)
        }
        return Locale.current
    }
}
