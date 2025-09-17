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
        language: String?,
        model _: ModelDescriptor = FluidTranscriptionService.defaultModel
    ) async -> String? {
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

}
