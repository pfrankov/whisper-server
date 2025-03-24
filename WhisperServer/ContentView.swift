//
//  ContentView.swift
//  WhisperServer
//
//  Created by Frankov Pavel on 24.03.2025.
//

import SwiftUI

/// A placeholder view for the application
/// This view is not actually displayed to the user since the app is menu bar only,
/// but it's required as part of the SwiftUI app structure.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "server.rack")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)
            
            Text("WhisperServer")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("HTTP Server is running")
                .font(.title3)
            
            Text("The app runs in the menu bar")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}
