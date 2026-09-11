import XCTest
import FluidAudio
@testable import WhisperServer

final class NemotronCacheTests: XCTestCase {
    private var directory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try fileManager.removeItem(at: directory) }
    }

    /// Fixtures follow the pinned downloader's layout, independently of the app's cache helpers.
    private var englishDirectory: URL {
        directory.appendingPathComponent(NemotronChunkSize.ms2240.repo.folderName, isDirectory: true)
    }

    private var multilingualDirectory: URL {
        directory.appendingPathComponent(Repo.nemotronMultilingual.folderName, isDirectory: true)
    }

    @discardableResult
    private func writeFixture(in parent: URL, filename: String = "metadata.json") throws -> URL {
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let file = parent.appendingPathComponent(filename)
        try Data("fixture".utf8).write(to: file)
        return file
    }

    func testNemotronDetectsEnglishDownloaderCache() throws {
        try writeFixture(in: englishDirectory)
        XCTAssertTrue(NemotronTranscriptionService.isModelDownloaded(.english, baseDirectory: directory))
        XCTAssertFalse(NemotronTranscriptionService.isModelDownloaded(.multilingual, baseDirectory: directory))
    }

    func testNemotronDetectsLatinOnlyDownloaderCache() throws {
        try writeFixture(in: multilingualDirectory.appendingPathComponent("latin/2240ms", isDirectory: true))
        XCTAssertTrue(NemotronTranscriptionService.isModelDownloaded(.multilingual, baseDirectory: directory))
        XCTAssertFalse(NemotronTranscriptionService.isModelDownloaded(.english, baseDirectory: directory))
    }

    func testNemotronDetectsFullMultilingualOnlyDownloaderCache() throws {
        try writeFixture(in: multilingualDirectory.appendingPathComponent("multilingual/2240ms", isDirectory: true))
        XCTAssertTrue(NemotronTranscriptionService.isModelDownloaded(.multilingual, baseDirectory: directory))
    }

    func testNemotronMissingAndEmptyCachesAreNotDownloaded() throws {
        for variant: NemotronTranscriptionService.Variant in [.english, .multilingual] {
            XCTAssertFalse(NemotronTranscriptionService.isModelDownloaded(variant, baseDirectory: directory))
        }
        for cache in [englishDirectory, multilingualDirectory] {
            try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        }
        for variant: NemotronTranscriptionService.Variant in [.english, .multilingual] {
            XCTAssertFalse(NemotronTranscriptionService.isModelDownloaded(variant, baseDirectory: directory))
        }
    }

    func testFluidDeletionRemovesDownloaderCachesAndPreservesUnrelatedFiles() throws {
        let parakeet = directory.appendingPathComponent(AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent)
        let downloadedFiles = try [
            writeFixture(in: englishDirectory),
            writeFixture(in: multilingualDirectory.appendingPathComponent("latin/2240ms", isDirectory: true)),
            writeFixture(in: multilingualDirectory.appendingPathComponent("multilingual/2240ms", isDirectory: true)),
            writeFixture(in: parakeet)
        ]
        let unrelatedFiles = try [
            writeFixture(in: directory.appendingPathComponent("nemotron-streaming-unrelated", isDirectory: true)),
            writeFixture(in: directory.appendingPathComponent("speaker-diarization", isDirectory: true)),
            writeFixture(in: directory, filename: "keep.txt")
        ]

        // Exercise the same filesystem operation called by the model-deletion menu action.
        for _ in 0..<2 {
            try ModelManager.deleteDownloadedFluidModelCaches(
                parakeetDirectory: parakeet, nemotronBaseDirectory: directory
            )
            for file in downloadedFiles {
                XCTAssertFalse(fileManager.fileExists(atPath: file.path), "Cached model was not removed: \(file.path)")
            }
            for file in unrelatedFiles {
                XCTAssertEqual(try Data(contentsOf: file), Data("fixture".utf8))
            }
            XCTAssertFalse(NemotronTranscriptionService.isModelDownloaded(.english, baseDirectory: directory))
            XCTAssertFalse(NemotronTranscriptionService.isModelDownloaded(.multilingual, baseDirectory: directory))
        }
    }
}
