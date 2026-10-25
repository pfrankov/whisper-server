import XCTest
import AppKit
import FluidAudio
@testable import WhisperServer

final class ParakeetModelTests: XCTestCase {
    func testParakeetVersionsAndDefaultAliases() throws {
        let v2 = try XCTUnwrap(FluidTranscriptionService.modelDescriptor(for: " PARAKEET-TDT-0.6B-V2-COREML "))
        XCTAssertEqual(v2.id, "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(v2.parakeetVersion, .v2)
        XCTAssertEqual(FluidTranscriptionService.availableModelIDs.prefix(2), ["parakeet-tdt-0.6b-v3", v2.id])
        for alias in ["default", "fluid-default", "parakeet-tdt-0.6b-v3", "parakeet-tdt-0.6b-v3-coreml"] {
            let model = try XCTUnwrap(FluidTranscriptionService.modelDescriptor(for: alias))
            XCTAssertEqual(model.id, FluidTranscriptionService.defaultModel.id)
            XCTAssertEqual(model.parakeetVersion, .v3)
        }
        XCTAssertNil(NemotronTranscriptionService.variant(forModelID: v2.id))
        XCTAssertNil(FluidTranscriptionService.modelDescriptor(for: "parakeet-tdt-0.6b-v1"))
        XCTAssertNil(FluidTranscriptionService.modelDescriptor(for: "nemotron")?.parakeetVersion)
    }

    func testParakeetCachesAreDistinctAndEitherVersionIsDiscoverable() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let directories = FluidTranscriptionService.parakeetCacheDirectories(baseDirectory: base)
        XCTAssertEqual(Set(directories).count, 2)
        XCTAssertFalse(FluidTranscriptionService.isParakeetModelDownloaded(baseDirectory: base))
        for version: AsrModelVersion in [.v2, .v3] {
            let directory = base.appendingPathComponent(AsrModels.defaultCacheDirectory(for: version).lastPathComponent, isDirectory: true)
            XCTAssertTrue(directories.contains(directory))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            XCTAssertFalse(FluidTranscriptionService.isParakeetModelDownloaded(baseDirectory: base))
            try Data("fixture".utf8).write(to: directory.appendingPathComponent("vocabulary.json"))
            XCTAssertTrue(FluidTranscriptionService.isParakeetModelDownloaded(baseDirectory: base))
            try FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    func testSwitchDuringPreparationWaitsAndPreparesLatestSelection() async throws {
        let keys = ["selectedProvider", "selectedFluidModelID", "selectedModelID"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
        }
        let started = expectation(description: "Initial preparation started")
        let finished = expectation(description: "Latest selection ready")
        let gate = PreparationGate()
        let manager = ModelManager(automaticallyPrepareModels: false) { model in
            await gate.prepare(model.id, started: started)
        }
        let observer = NotificationCenter.default.addObserver(forName: .modelIsReady, object: manager, queue: .main) { _ in
            finished.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        manager.selectFluidModel(id: "parakeet-tdt-0.6b-v3")
        await fulfillment(of: [started], timeout: 5)
        manager.selectFluidModel(id: "parakeet-tdt-0.6b-v2")
        manager.selectFluidModel(id: "parakeet-tdt-0.6b-v3")
        manager.selectFluidModel(id: "parakeet-tdt-0.6b-v2")
        XCTAssertFalse(manager.isModelReady)
        await gate.release()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(manager.selectedFluidModelDescriptor.parakeetVersion, .v2)
        XCTAssertTrue(manager.isModelReady)
        let calls = await gate.calls
        XCTAssertEqual(calls, ["parakeet-tdt-0.6b-v3", "parakeet-tdt-0.6b-v2"])
    }

    @MainActor
    func testParakeetMenuActionsAndSelectionPersistence() async throws {
        let defaults = UserDefaults.standard
        let keys = ["selectedProvider", "selectedFluidModelID", "selectedModelID"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
        }
        defaults.removeObject(forKey: "selectedFluidModelID")
        defaults.set("fluid", forKey: "selectedProvider")
        let manager = ModelManager(automaticallyPrepareModels: false, prepareFluidModel: { _ in })
        let service = MenuBarService(modelManager: manager)
        service.setupMenuBar()
        defer {
            if let item = service.statusItem { NSStatusBar.system.removeStatusItem(item) }
        }
        func submenu() throws -> NSMenu {
            try XCTUnwrap(service.statusItem?.menu?.item(withTitle: "Select Model")?.submenu)
        }
        func item(_ id: String) throws -> NSMenuItem {
            try XCTUnwrap(try submenu().items.first { $0.representedObject as? String == id })
        }
        let v3 = "parakeet-tdt-0.6b-v3"
        let v2 = "parakeet-tdt-0.6b-v2"
        XCTAssertEqual(try item(v3).title, "Parakeet TDT v3 (0.6B) (Core ML)")
        XCTAssertEqual(try item(v2).title, "Parakeet TDT v2 (0.6B, English) (Core ML)")
        XCTAssertEqual(try submenu().index(of: item(v2)), try submenu().index(of: item(v3)) + 1)
        XCTAssertEqual(try item(v3).state, .on)
        XCTAssertEqual(try item(v2).state, .off)

        for id in [v2, v3, v2] {
            let menu = try submenu()
            menu.performActionForItem(at: menu.index(of: try item(id)))
            let deadline = Date().addingTimeInterval(2)
            while !manager.isModelReady && Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(manager.isModelReady)
            XCTAssertEqual(manager.selectedProvider, .fluid)
            XCTAssertEqual(manager.selectedFluidModelID, id)
            XCTAssertEqual(try item(id).state, .on)
            XCTAssertEqual(try item(id == v2 ? v3 : v2).state, .off)
            XCTAssertEqual(defaults.string(forKey: "selectedProvider"), "fluid")
            XCTAssertEqual(defaults.string(forKey: "selectedFluidModelID"), id)
            let restored = ModelManager(automaticallyPrepareModels: false, prepareFluidModel: { _ in })
            XCTAssertEqual(restored.selectedProvider, .fluid)
            XCTAssertEqual(restored.selectedFluidModelDescriptor.id, id)
            XCTAssertEqual(FluidTranscriptionService.modelDescriptor(for: "default")?.id, v3)
            XCTAssertEqual(FluidTranscriptionService.modelDescriptor(for: "fluid-default")?.id, v3)
        }
    }

    /// Opt-in hosted macOS test; ordinary unit tests never download model weights.
    @MainActor
    func testParakeetNativeDownloadAndBothTranscriptionPaths() async throws {
        guard let path = ProcessInfo.processInfo.environment["PARAKEET_QA_AUDIO"] else {
            throw XCTSkip("Set PARAKEET_QA_AUDIO to a synthetic speech WAV for native model QA")
        }
        let audio = URL(fileURLWithPath: path)
        let keys = ["selectedProvider", "selectedFluidModelID", "selectedModelID"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
        }
        let manager = ModelManager(automaticallyPrepareModels: false)
        for id in ["parakeet-tdt-0.6b-v2", "parakeet-tdt-0.6b-v3", "parakeet-tdt-0.6b-v2"] {
            let descriptor = try XCTUnwrap(FluidTranscriptionService.modelDescriptor(for: id))
            let version = try XCTUnwrap(descriptor.parakeetVersion)
            manager.selectFluidModel(id: id)
            let deadline = Date().addingTimeInterval(600)
            while !manager.isModelReady && Date() < deadline {
                if manager.currentStatus.hasPrefix("Error") { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertTrue(manager.isModelReady, manager.currentStatus)
            guard manager.isModelReady else { return }
            do {
                let models = try await FluidTranscriptionService.loadParakeetModel(descriptor)
                XCTAssertEqual(models.version, version)
            }
            XCTAssertTrue(AsrModels.modelsExist(at: FluidTranscriptionService.cacheDirectory(for: version), version: version))
            let text = await FluidTranscriptionService.transcribeText(at: audio, language: "en", model: descriptor)
            XCTAssertFalse(try XCTUnwrap(text).isEmpty)
            let result = await FluidTranscriptionService.transcribeAudio(at: audio, language: "en", model: descriptor)
            let transcription = try XCTUnwrap(result)
            XCTAssertFalse(transcription.text.isEmpty)
            XCTAssertFalse(transcription.segments.isEmpty)
            XCTAssertTrue(transcription.speakerSegments.isEmpty)
            XCTAssertTrue(transcription.segments.allSatisfy {
                $0.startTime >= 0 && $0.endTime >= $0.startTime && $0.endTime <= transcription.duration
            })
        }
    }

    private actor PreparationGate {
        var calls: [String] = []
        private var continuation: CheckedContinuation<Void, Never>?

        func prepare(_ id: String, started: XCTestExpectation) async {
            calls.append(id)
            if calls.count == 1 {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    started.fulfill()
                }
            }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }
}
