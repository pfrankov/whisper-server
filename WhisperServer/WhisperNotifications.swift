import Foundation

// Centralized notification names used across the app
extension Notification.Name {
    static let modelManagerDidUpdate = Notification.Name("ModelManagerDidUpdate")
    static let modelManagerStatusChanged = Notification.Name("ModelManagerStatusChanged")
    static let modelManagerProgressChanged = Notification.Name("ModelManagerProgressChanged")
    static let modelIsReady = Notification.Name("ModelIsReady")
    static let modelPreparationFailed = Notification.Name("ModelPreparationFailed")
    static let tinyModelAutoSelected = Notification.Name("TinyModelAutoSelected")
    static let whisperMetalActivated = Notification.Name("WhisperMetalActivated")
    static let transcriptionProgressUpdated = Notification.Name("TranscriptionProgressUpdated")
}

enum TranscriptionProgressUserInfoKey {
    static let progress = "progress"
    static let isProcessing = "isProcessing"
    static let modelName = "modelName"
}
