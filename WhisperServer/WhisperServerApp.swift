//
//  WhisperServerApp.swift
//  WhisperServer
//
//  Created by Frankov Pavel on 24.03.2025.
//

import SwiftUI

@main
struct WhisperServerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// Lightweight application delegate coordinating specialized services
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties
    
    private let modelManager = ModelManager()
    private let serverCoordinator: ServerCoordinator
    private let menuBarService: MenuBarService
    private let modelObserver: ModelObserver
    
    override init() {
        serverCoordinator = ServerCoordinator(modelManager: modelManager)
        menuBarService = MenuBarService(modelManager: modelManager)
        modelObserver = ModelObserver(modelManager: modelManager)
        
        super.init()
        
        // Wire up dependencies
        menuBarService.setServerCoordinator(serverCoordinator)
        serverCoordinator.setMenuBarService(menuBarService)
        modelObserver.setMenuBarService(menuBarService)
        modelObserver.setServerCoordinator(serverCoordinator)
    }
    
    // MARK: - Application Lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Make app appear only in menu bar (no dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // Check DEBUG flag status
        #if DEBUG
        print("✅ DEBUG mode is ACTIVE")
        #else
        print("❌ DEBUG mode is INACTIVE (Release build)")
        #endif
        
        // Initialize services
        menuBarService.setupMenuBar()
        modelObserver.updateUIForModelPreparation()
        serverCoordinator.startServer()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        serverCoordinator.handleApplicationTermination()
    }
}
