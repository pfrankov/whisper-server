import Foundation

/// Handles formatting of transcription segments into various subtitle formats
struct WhisperSubtitleFormatter {
    
    // MARK: - Data Structures
    
    /// Represents a segment of transcription with timing information
    struct TranscriptionSegment {
        let startTime: Double    // Start time in seconds
        let endTime: Double      // End time in seconds
        let text: String         // Transcribed text
    }
    
    /// Response formats for transcription
    enum ResponseFormat: String, CaseIterable {
        case json = "json"
        case text = "text"
        case verboseJson = "verbose_json"
        case srt = "srt"
        case vtt = "vtt"
    }
    
    // MARK: - Timestamp Formatting
    
    /// Formats timestamps for SRT format (HH:MM:SS,mmm)
    static func formatSRTTimestamp(_ seconds: Double) -> String {
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
        let milliseconds = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, milliseconds)
    }
    
    /// Formats timestamps for VTT format (HH:MM:SS.mmm)
    static func formatVTTTimestamp(_ seconds: Double) -> String {
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
        let milliseconds = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, milliseconds)
    }
    
    // MARK: - Subtitle Formatting
    
    /// Formats segments as SRT subtitles
    static func formatAsSRT(segments: [TranscriptionSegment]) -> String {
        var srtString = ""
        
        for (index, segment) in segments.enumerated() {
            let startTime = formatSRTTimestamp(segment.startTime)
            let endTime = formatSRTTimestamp(segment.endTime)
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip empty segments
            if !text.isEmpty {
                srtString += "\(index + 1)\n"
                srtString += "\(startTime) --> \(endTime)\n"
                srtString += "\(text)\n\n"
            }
        }
        
        return srtString
    }
    
    /// Formats segments as WebVTT subtitles
    static func formatAsVTT(segments: [TranscriptionSegment]) -> String {
        var vttString = "WEBVTT\n\n"
        
        for segment in segments {
            let startTime = formatVTTTimestamp(segment.startTime)
            let endTime = formatVTTTimestamp(segment.endTime)
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip empty segments
            if !text.isEmpty {
                vttString += "\(startTime) --> \(endTime)\n"
                vttString += "\(text)\n\n"
            }
        }
        
        return vttString
    }
    
    /// Formats segments as verbose JSON (OpenAI Whisper API compatible)
    static func formatAsVerboseJSON(segments: [TranscriptionSegment]) -> String {
        let fullTranscription = segments.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        
        let segmentDicts = segments.compactMap { segment -> [String: Any]? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return nil }
            
            return [
                "start": segment.startTime,
                "end": segment.endTime,
                "text": text
            ]
        }
        
        let responseDict: [String: Any] = [
            "text": fullTranscription,
            "segments": segmentDicts
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: responseDict, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        } else {
            // Fallback to simple JSON
            return "{\"text\": \"\(fullTranscription)\", \"error\": \"Failed to format verbose JSON\"}"
        }
    }
} 