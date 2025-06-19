import Foundation
import whisper
#if os(macOS) || os(iOS)
import SwiftUI
import AVFoundation
import Darwin
import AppKit
#endif

/// Handles conversion of various audio formats to 16-bit, 16kHz mono WAV required by Whisper
class WhisperAudioConverter {
    // MARK: - Constants
    
    /// Target sample rate required by Whisper
    static let targetSampleRate = 16000.0
    

    
    // MARK: - Voice Activity Detection
    
    /// Represents a segment of speech detected by VAD
    struct SpeechSegment {
        let startTime: Double
        let endTime: Double
        let startSample: Int
        let endSample: Int
    }
    
    /// Converts audio data from any supported format to the format required by Whisper
    /// - Parameter audioURL: URL of the original audio file
    /// - Returns: Converted audio data as PCM 16-bit 16kHz mono samples, or nil if conversion failed
    static func convertToWhisperFormat(from audioURL: URL) -> [Float]? {
        #if os(macOS) || os(iOS)
        return convertUsingAVFoundation(from: audioURL)
        #else
        print("❌ Audio conversion is only supported on macOS and iOS")
        return nil
        #endif
    }
    
    #if os(macOS) || os(iOS)
    /// Converts audio using AVFoundation framework - unified approach for all formats
    private static func convertUsingAVFoundation(from audioURL: URL) -> [Float]? {
        print("🔄 Converting audio to Whisper format (16kHz mono float)")
        
        // Target format: 16kHz mono float
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: targetSampleRate,
                                       channels: 1,
                                       interleaved: false)!
        
        // Try to create an AVAudioFile from the data
        guard let audioFile = try? AVAudioFile(forReading: audioURL) else {
            print("❌ Failed to create AVAudioFile for reading from URL: \(audioURL.path)")
            return nil
        }
        
        let sourceFormat = audioFile.processingFormat
        print("🔍 Source format: \(sourceFormat.sampleRate)Hz, \(sourceFormat.channelCount) channels")
        print("🔍 Source duration: \(String(format: "%.2f", Double(audioFile.length) / sourceFormat.sampleRate))s")
        print("🔍 Target format: \(outputFormat.sampleRate)Hz, \(outputFormat.channelCount) channels")
        
        // Convert the audio file to the required format
        let convertedSamples = convertAudioFile(audioFile, toFormat: outputFormat)
        
        if let samples = convertedSamples {
            print("🔍 Final converted samples: \(samples.count) samples")
            print("🔍 Final duration: \(String(format: "%.2f", Double(samples.count) / outputFormat.sampleRate))s")
        }
        
        return convertedSamples
    }
    
    /// Converts an audio file to the specified format
    private static func convertAudioFile(_ file: AVAudioFile, toFormat outputFormat: AVAudioFormat) -> [Float]? {
        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        
        print("🔍 DEBUG: Source file info:")
        print("   - Frames: \(file.length)")
        print("   - Sample Rate: \(sourceFormat.sampleRate)Hz")
        print("   - Channels: \(sourceFormat.channelCount)")
        print("   - Original Duration: \(String(format: "%.2f", Double(file.length) / sourceFormat.sampleRate))s")
        
        // Validate input
        guard frameCount > 0 else {
            print("❌ Audio file is empty")
            return nil
        }
        
        // Read the entire file into a buffer
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            print("❌ Failed to create source PCM buffer")
            return nil
        }
        
        do {
            try file.read(into: buffer)
        } catch {
            print("❌ Failed to read audio file: \(error.localizedDescription)")
            return nil
        }
        
        // If source format matches target format, just return the samples
        if abs(sourceFormat.sampleRate - outputFormat.sampleRate) < 1.0 && 
           sourceFormat.channelCount == outputFormat.channelCount {
            return extractSamplesFromBuffer(buffer)
        }
        
        // Create converter and convert
        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            print("❌ Failed to create audio converter")
            return nil
        }
        
        // Calculate output buffer size with some margin
        let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(frameCount) * ratio * 1.1)
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            print("❌ Failed to create output buffer")
            return nil
        }
        
        // Perform conversion
        var error: NSError?
        var inputProvided = false
        var inputBlockCallCount = 0
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            inputBlockCallCount += 1
            print("🔄 DEBUG: Input block called \(inputBlockCallCount) time(s), requested packets: \(inNumPackets)")
            
            if inputProvided {
                // We've already provided all input data
                outStatus.pointee = .noDataNow
                print("🚫 DEBUG: No more data to provide (already provided)")
                return nil
            } else {
                // Provide the input buffer once
                inputProvided = true
                outStatus.pointee = .haveData
                print("✅ DEBUG: Providing input buffer with \(buffer.frameLength) frames to converter")
                return buffer
            }
        }
        
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        print("🔄 DEBUG: Conversion completed with status: \(status)")
        print("🔄 DEBUG: Input block was called \(inputBlockCallCount) time(s) total")
        
        if status == .error || error != nil {
            print("❌ Conversion failed: \(error?.localizedDescription ?? "unknown error")")
            return nil
        }
        
        if outputBuffer.frameLength == 0 {
            print("❌ No frames were converted")
            return nil
        }
        
        print("✅ Successfully converted to \(outputBuffer.frameLength) frames at \(outputFormat.sampleRate)Hz")
        print("🔍 DEBUG: Converted file info:")
        print("   - Output Frames: \(outputBuffer.frameLength)")
        print("   - Output Sample Rate: \(outputFormat.sampleRate)Hz")
        print("   - Expected Duration: \(String(format: "%.2f", Double(outputBuffer.frameLength) / outputFormat.sampleRate))s")
        print("   - Conversion Ratio: \(String(format: "%.4f", Double(outputBuffer.frameLength) / Double(frameCount)))")
        
        return extractSamplesFromBuffer(outputBuffer)
    }
    
    /// Extracts float samples from an audio buffer
    private static func extractSamplesFromBuffer(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            print("❌ No valid channel data in buffer")
            return nil
        }
        
        // Extract samples from the first channel (mono)
        // Using reserveCapacity for better performance with large buffers
        let frameCount = Int(buffer.frameLength)
        var samples = [Float]()
        samples.reserveCapacity(frameCount)
        
        let data = UnsafeBufferPointer(start: channelData[0], count: frameCount)
        samples.append(contentsOf: data)
        
        return samples
    }
    
    // MARK: - Voice Activity Detection
    
    /// Simple energy-based Voice Activity Detection
    /// - Parameters:
    ///   - samples: Audio samples at 16kHz
    ///   - sampleRate: Sample rate (should be 16000)
    ///   - energyThreshold: Energy threshold for speech detection (0.0-1.0)
    ///   - minSpeechDuration: Minimum duration to consider as speech (seconds)
    ///   - minSilenceDuration: Minimum duration to consider as silence (seconds)
    /// - Returns: Array of detected speech segments
    private static func detectSpeechSegments(samples: [Float], 
                                           sampleRate: Double = targetSampleRate,
                                           energyThreshold: Float = 0.02,
                                           minSpeechDuration: Double = 0.3,
                                           minSilenceDuration: Double = 0.5) -> [SpeechSegment] {
        print("🎤 Running Voice Activity Detection on \(samples.count) samples")
        
        // Window size for energy calculation (20ms)
        let windowSize = Int(sampleRate * 0.02)
        let hopSize = windowSize / 2
        
        var speechSegments: [SpeechSegment] = []
        var isSpeech = false
        var speechStartSample = 0
        var lastSpeechEndSample = 0
        
        // Calculate RMS energy for each window
        var windowIndex = 0
        while windowIndex + windowSize <= samples.count {
            let windowSamples = Array(samples[windowIndex..<(windowIndex + windowSize)])
            let energy = sqrt(windowSamples.map { $0 * $0 }.reduce(0, +) / Float(windowSize))
            
            if energy > energyThreshold {
                // Detected speech
                if !isSpeech {
                    speechStartSample = windowIndex
                    isSpeech = true
                }
                lastSpeechEndSample = windowIndex + windowSize
            } else {
                // Detected silence
                if isSpeech {
                    let silenceDuration = Double(windowIndex - lastSpeechEndSample) / sampleRate
                    if silenceDuration > minSilenceDuration {
                        // End of speech segment
                        let speechDuration = Double(lastSpeechEndSample - speechStartSample) / sampleRate
                        if speechDuration > minSpeechDuration {
                            let segment = SpeechSegment(
                                startTime: Double(speechStartSample) / sampleRate,
                                endTime: Double(lastSpeechEndSample) / sampleRate,
                                startSample: speechStartSample,
                                endSample: lastSpeechEndSample
                            )
                            speechSegments.append(segment)
                        }
                        isSpeech = false
                    }
                }
            }
            
            windowIndex += hopSize
        }
        
        // Handle last segment if still in speech
        if isSpeech {
            let speechDuration = Double(lastSpeechEndSample - speechStartSample) / sampleRate
            if speechDuration > minSpeechDuration {
                let segment = SpeechSegment(
                    startTime: Double(speechStartSample) / sampleRate,
                    endTime: Double(lastSpeechEndSample) / sampleRate,
                    startSample: speechStartSample,
                    endSample: lastSpeechEndSample
                )
                speechSegments.append(segment)
            }
        }
        
        print("🎯 Detected \(speechSegments.count) speech segments")
        for (index, segment) in speechSegments.enumerated() {
            print("   - Segment \(index + 1): \(String(format: "%.1f", segment.startTime))s - \(String(format: "%.1f", segment.endTime))s")
        }
        
        return speechSegments
    }
    
    /// Creates audio chunks based on Voice Activity Detection
    /// - Parameters:
    ///   - audioURL: URL of the original audio file
    ///   - vadEnabled: Whether to use VAD for smart chunking
    ///   - removeLeadingSilence: Whether to remove leading silence from chunks
    ///   - vadEnergyThreshold: Energy threshold for VAD
    ///   - vadMinSpeechDuration: Minimum speech duration
    ///   - vadMinSilenceDuration: Minimum silence duration
    /// - Returns: Array of audio chunks with timing information
    static func createAudioChunksWithVAD(from audioURL: URL, 
                                       vadEnabled: Bool = true,
                                       removeLeadingSilence: Bool = true,
                                       vadEnergyThreshold: Float = 0.02,
                                       vadMinSpeechDuration: Double = 0.3,
                                       vadMinSilenceDuration: Double = 0.5) -> [(samples: [Float], startTime: Double, endTime: Double, originalStartTime: Double)]? {
        print("🔄 Creating audio chunks with VAD (VAD: \(vadEnabled ? "ON" : "OFF"))")
        print("🎯 Pure VAD-based segmentation - each speech segment becomes its own chunk")
        
        // Convert audio to Whisper format first
        guard let allSamples = convertToWhisperFormat(from: audioURL) else {
            print("❌ Failed to convert audio to Whisper format")
            return nil
        }
        
        let totalDuration = Double(allSamples.count) / targetSampleRate
        print("🔍 Total audio duration: \(String(format: "%.1f", totalDuration)) seconds")
        
        // If VAD is disabled, process entire audio as single chunk
        if !vadEnabled {
            print("📋 VAD disabled, processing entire audio as single chunk")
            return [(samples: allSamples, startTime: 0.0, endTime: totalDuration, originalStartTime: 0.0)]
        }
        
        // Detect speech segments
        let speechSegments = detectSpeechSegments(
            samples: allSamples,
            sampleRate: targetSampleRate,
            energyThreshold: vadEnergyThreshold,
            minSpeechDuration: vadMinSpeechDuration,
            minSilenceDuration: vadMinSilenceDuration
        )
        
        if speechSegments.isEmpty {
            print("⚠️ No speech detected, processing entire audio")
            return [(samples: allSamples, startTime: 0.0, endTime: totalDuration, originalStartTime: 0.0)]
        }
        
        // Create chunks based on speech segments - each segment becomes its own chunk
        // No artificial limits - pure VAD-based natural segmentation
        var chunks: [(samples: [Float], startTime: Double, endTime: Double, originalStartTime: Double)] = []
        
        for segment in speechSegments {
            // Each speech segment becomes its own chunk - completely natural
            if let chunk = createChunkFromSegments([segment], 
                                                  allSamples: allSamples,
                                                  removeLeadingSilence: removeLeadingSilence) {
                chunks.append(chunk)
            }
        }
        
        print("✅ Created \(chunks.count) VAD-based audio chunks")
        for (index, chunk) in chunks.enumerated() {
            print("   - Chunk \(index + 1): \(String(format: "%.1f", chunk.startTime))s - \(String(format: "%.1f", chunk.endTime))s (original: \(String(format: "%.1f", chunk.originalStartTime))s)")
        }
        
        return chunks
    }
    
    /// Creates a chunk from speech segments
    private static func createChunkFromSegments(_ segments: [SpeechSegment],
                                              allSamples: [Float],
                                              removeLeadingSilence: Bool) -> (samples: [Float], startTime: Double, endTime: Double, originalStartTime: Double)? {
        guard !segments.isEmpty else { return nil }
        
        let firstSegment = segments.first!
        let lastSegment = segments.last!
        
        // Original time boundaries (including silence)
        let originalStartTime = firstSegment.startTime
        let originalEndTime = lastSegment.endTime
        
        if removeLeadingSilence {
            // Extract only speech samples
            var chunkSamples: [Float] = []
            var adjustedStartTime = originalStartTime
            
            for (index, segment) in segments.enumerated() {
                let segmentSamples = Array(allSamples[segment.startSample..<segment.endSample])
                
                if index == 0 {
                    // First segment - this is where transcription actually starts
                    adjustedStartTime = segment.startTime
                } else {
                    // Add small silence between segments (100ms) to preserve natural speech flow
                    let silenceSamples = Int(targetSampleRate * 0.1) // 100ms of silence
                    chunkSamples.append(contentsOf: Array(repeating: 0.0, count: silenceSamples))
                }
                
                chunkSamples.append(contentsOf: segmentSamples)
            }
            
            // The adjusted end time is based on the actual duration of samples
            let adjustedEndTime = adjustedStartTime + (Double(chunkSamples.count) / targetSampleRate)
            
            return (samples: chunkSamples, 
                   startTime: adjustedStartTime, 
                   endTime: adjustedEndTime,
                   originalStartTime: originalStartTime)
        } else {
            // Keep all samples including silence
            let startSample = segments.first!.startSample
            let endSample = segments.last!.endSample
            let chunkSamples = Array(allSamples[startSample..<endSample])
            
            return (samples: chunkSamples,
                   startTime: originalStartTime,
                   endTime: originalEndTime,
                   originalStartTime: originalStartTime)
        }
    }
    
    /// Creates audio chunks from the source audio file
    /// - Parameters:
    ///   - audioURL: URL of the original audio file
    ///   - maxDuration: Maximum duration of each chunk in seconds
    ///   - overlap: Overlap between chunks in seconds
    /// - Returns: Array of audio sample arrays, each representing a chunk
    static func createAudioChunks(from audioURL: URL, maxDuration: Double, overlap: Double) -> [(samples: [Float], startTime: Double, endTime: Double)]? {
        print("🔄 Creating audio chunks (max: \(Int(maxDuration))s, overlap: \(Int(overlap))s)")
        
        // Target format: 16kHz mono float
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: targetSampleRate,
                                       channels: 1,
                                       interleaved: false)!
        
        // Try to create an AVAudioFile from the data
        guard let audioFile = try? AVAudioFile(forReading: audioURL) else {
            print("❌ Failed to create AVAudioFile for reading from URL: \(audioURL.path)")
            return nil
        }
        
        let sourceFormat = audioFile.processingFormat
        let totalDuration = Double(audioFile.length) / sourceFormat.sampleRate
        
        print("🔍 Source format: \(sourceFormat.sampleRate)Hz, \(sourceFormat.channelCount) channels")
        print("🔍 Total duration: \(String(format: "%.1f", totalDuration)) seconds")
        
        // If the audio is shorter than maxDuration, process as single chunk
        if totalDuration <= maxDuration {
            print("📋 Audio is short enough, processing as single chunk")
            guard let samples = convertAudioFile(audioFile, toFormat: outputFormat) else {
                return nil
            }
            return [(samples: samples, startTime: 0.0, endTime: totalDuration)]
        }
        
        // Calculate chunks
        var chunks: [(samples: [Float], startTime: Double, endTime: Double)] = []
        var currentStart: Double = 0.0
        
        while currentStart < totalDuration {
            let currentEnd = min(currentStart + maxDuration, totalDuration)
            let actualStart = max(0.0, currentStart - (chunks.count > 0 ? overlap : 0.0))
            
            print("🔄 Processing chunk \(chunks.count + 1): \(String(format: "%.1f", actualStart))s - \(String(format: "%.1f", currentEnd))s")
            
            // Extract chunk samples
            guard let chunkSamples = extractAudioChunk(from: audioFile, 
                                                      startTime: actualStart, 
                                                      endTime: currentEnd, 
                                                      targetFormat: outputFormat) else {
                print("❌ Failed to extract chunk at \(actualStart)s - \(currentEnd)s")
                return nil
            }
            
            chunks.append((samples: chunkSamples, startTime: currentStart, endTime: currentEnd))
            
            // Move to next chunk
            currentStart = currentEnd
        }
        
        print("✅ Created \(chunks.count) audio chunks")
        return chunks
    }
    
    /// Extracts a specific time segment from audio file
    private static func extractAudioChunk(from audioFile: AVAudioFile, 
                                        startTime: Double, 
                                        endTime: Double, 
                                        targetFormat: AVAudioFormat) -> [Float]? {
        let sourceFormat = audioFile.processingFormat
        let startFrame = AVAudioFramePosition(startTime * sourceFormat.sampleRate)
        let endFrame = AVAudioFramePosition(endTime * sourceFormat.sampleRate)
        let frameCount = AVAudioFrameCount(endFrame - startFrame)
        
        guard frameCount > 0 else {
            print("❌ Invalid frame count: \(frameCount)")
            return nil
        }
        
        // Create buffer for the chunk
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            print("❌ Failed to create chunk buffer")
            return nil
        }
        
        // Seek to start position and read chunk
        audioFile.framePosition = startFrame
        do {
            try audioFile.read(into: buffer, frameCount: frameCount)
        } catch {
            print("❌ Failed to read audio chunk: \(error.localizedDescription)")
            return nil
        }
        
        // Convert to target format if needed
        if abs(sourceFormat.sampleRate - targetFormat.sampleRate) < 1.0 && 
           sourceFormat.channelCount == targetFormat.channelCount {
            return extractSamplesFromBuffer(buffer)
        } else {
            // Create converter for this chunk
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                print("❌ Failed to create chunk converter")
                return nil
            }
            
            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(frameCount) * ratio * 1.1)
            
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
                print("❌ Failed to create chunk output buffer")
                return nil
            }
            
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            if status == .error || error != nil {
                print("❌ Chunk conversion failed: \(error?.localizedDescription ?? "unknown error")")
                return nil
            }
            
            return extractSamplesFromBuffer(outputBuffer)
        }
    }
    #endif
} 