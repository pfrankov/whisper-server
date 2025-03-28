//
//  ContentView.swift
//  WhisperServer
//
//  Created by Frankov Pavel on 24.03.2025.
//

import SwiftUI

/// A placeholder view for the application (not displayed as app is menu bar only)
struct ContentView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)
            
            Text("WhisperServer")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Running as menu bar app")
                .font(.title3)
        }
        .padding()
        .frame(width: 300, height: 200)
    }
}

#Preview {
    ContentView()
}
