import XCTest
import FluidAudio
@testable import WhisperServer

final class NemotronModelRoutingTests: XCTestCase {
    func testFluidCatalogContainsNemotronModels() {
        let ids = FluidTranscriptionService.availableModelIDs
        XCTAssertTrue(ids.contains("parakeet-tdt-0.6b-v3"))
        XCTAssertTrue(ids.contains("nemotron-speech-streaming-en-0.6b"))
        XCTAssertTrue(ids.contains("nemotron-3.5-asr-streaming-multilingual-0.6b"))
    }

    func testDefaultModelRemainsParakeet() {
        XCTAssertEqual(FluidTranscriptionService.defaultModel.id, "parakeet-tdt-0.6b-v3")
    }

    func testNemotronAliasesResolve() {
        XCTAssertEqual(
            FluidTranscriptionService.modelDescriptor(for: "nemotron")?.id,
            "nemotron-speech-streaming-en-0.6b"
        )
        XCTAssertEqual(
            FluidTranscriptionService.modelDescriptor(for: "Nemotron-3.5")?.id,
            "nemotron-3.5-asr-streaming-multilingual-0.6b"
        )
        XCTAssertEqual(
            FluidTranscriptionService.modelDescriptor(for: "nemotron-multilingual")?.id,
            "nemotron-3.5-asr-streaming-multilingual-0.6b"
        )
    }

    func testVariantRouting() {
        XCTAssertEqual(
            NemotronTranscriptionService.variant(forModelID: "nemotron-speech-streaming-en-0.6b"),
            .english
        )
        XCTAssertEqual(
            NemotronTranscriptionService.variant(forModelID: "nemotron-3.5-asr-streaming-multilingual-0.6b"),
            .multilingual
        )
        XCTAssertNil(NemotronTranscriptionService.variant(forModelID: "parakeet-tdt-0.6b-v3"))
    }

    func testNemotronCacheDirectoriesMatchDownloaders() {
        let base = NemotronTranscriptionService.cacheBaseDirectory()
        let english = NemotronTranscriptionService.cacheDirectory(for: .english)
        let multilingual = NemotronTranscriptionService.cacheDirectory(for: .multilingual)
        XCTAssertNotEqual(english, multilingual)
        XCTAssertEqual(
            english,
            base.appendingPathComponent(NemotronChunkSize.ms2240.repo.folderName, isDirectory: true)
        )
        XCTAssertEqual(
            multilingual,
            base.appendingPathComponent(Repo.nemotronMultilingual.folderName, isDirectory: true)
        )
    }
}
