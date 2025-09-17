import Foundation
import whisper
import AVFoundation

/// Handles conversion of various audio formats to 16-bit, 16kHz mono WAV required by Whisper
final class WhisperAudioConverter {
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
        return convertUsingAVFoundation(from: audioURL)
    }
    
    /// Converts audio using AVFoundation framework - unified approach for all formats
    private static func convertUsingAVFoundation(from audioURL: URL) -> [Float]? {
        
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
        
        // Convert the audio file to the required format
        return convertAudioFile(audioFile, toFormat: outputFormat)
    }
    
    /// Converts an audio file to the specified format using streaming approach for large files
    private static func convertAudioFile(_ file: AVAudioFile, toFormat outputFormat: AVAudioFormat) -> [Float]? {
        let sourceFormat = file.processingFormat
        let totalFrameCount = AVAudioFrameCount(file.length)
        
        // Validate input
        guard totalFrameCount > 0 else {
            print("❌ Audio file is empty")
            return nil
        }
        
        // Define chunk size (1 second worth of frames)
        let chunkDurationSeconds = 1.0
        let chunkFrameCount = AVAudioFrameCount(sourceFormat.sampleRate * chunkDurationSeconds)
        
        // If source format already matches target (16kHz, mono, Float32, non-interleaved), skip conversion
        if abs(sourceFormat.sampleRate - outputFormat.sampleRate) < 1.0 &&
           sourceFormat.channelCount == outputFormat.channelCount &&
           sourceFormat.commonFormat == .pcmFormatFloat32 &&
           sourceFormat.isInterleaved == false {
            
            var allSamples: [Float] = []
            allSamples.reserveCapacity(Int(totalFrameCount))
            
            // Reset file position to beginning
            file.framePosition = 0
            
            var remainingFrames = totalFrameCount
            while remainingFrames > 0 {
                let framesToRead = min(chunkFrameCount, remainingFrames)
                
                guard let chunkBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: framesToRead) else {
                    print("❌ Failed to create chunk buffer")
                    return nil
                }
                
                do {
                    try file.read(into: chunkBuffer, frameCount: framesToRead)
                } catch {
                    print("❌ Failed to read audio chunk: \(error.localizedDescription)")
                    return nil
                }
                
                if let chunkSamples = extractSamplesFromBuffer(chunkBuffer) {
                    allSamples.append(contentsOf: chunkSamples)
                } else {
                    print("❌ Failed to extract samples from chunk")
                    return nil
                }
                
                remainingFrames -= framesToRead
            }
            
            return allSamples
        }
        
        // Need conversion - use streaming approach
        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            print("❌ Failed to create audio converter")
            return nil
        }
        
        let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
        var allConvertedSamples: [Float] = []
        // Reserve capacity with estimated final size
        allConvertedSamples.reserveCapacity(Int(Double(totalFrameCount) * ratio))
        
        // Reset file position to beginning
        file.framePosition = 0
        
        var remainingFrames = totalFrameCount
        while remainingFrames > 0 {
            let framesToRead = min(chunkFrameCount, remainingFrames)
            
            // Create input buffer for this chunk
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: framesToRead) else {
                print("❌ Failed to create input chunk buffer")
                return nil
            }
            
            // Read chunk from file
            do {
                try file.read(into: inputBuffer, frameCount: framesToRead)
            } catch {
                print("❌ Failed to read audio chunk: \(error.localizedDescription)")
                return nil
            }
            
            // Skip empty chunks
            if inputBuffer.frameLength == 0 {
                break
            }
            
            // Create output buffer for this chunk
            let outputFrameCapacity = AVAudioFrameCount(Double(framesToRead) * ratio * 1.1)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
                print("❌ Failed to create output chunk buffer")
                return nil
            }
            
            // Convert this chunk
            var error: NSError?
            var inputProvided = false
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                if inputProvided {
                    outStatus.pointee = .noDataNow
                    return nil
                } else {
                    inputProvided = true
                    outStatus.pointee = .haveData
                    return inputBuffer
                }
            }
            
            let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
            
            if status == .error || error != nil {
                print("❌ Chunk conversion failed: \(error?.localizedDescription ?? "unknown error")")
                return nil
            }
            
            // Extract and accumulate samples from this chunk
            if let chunkSamples = extractSamplesFromBuffer(outputBuffer) {
                allConvertedSamples.append(contentsOf: chunkSamples)
            }
            
            remainingFrames -= framesToRead
        }
        
        if allConvertedSamples.isEmpty { return nil }
        
        return allConvertedSamples
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
        // Optimized energy-based VAD: sliding RMS without per-window allocations
        let windowSize = max(1, Int(sampleRate * 0.02)) // ~20ms
        let hopSize = max(1, windowSize / 2)

        guard samples.count >= windowSize else {
            return []
        }

        var speechSegments: [SpeechSegment] = []
        var isSpeech = false
        var speechStartSample = 0
        var lastSpeechEndSample = 0

        // Initialize sum of squares for the first window
        var sumSquares: Float = 0
        for i in 0..<windowSize {
            let s = samples[i]
            sumSquares += s * s
        }

        var windowStart = 0
        var windowEnd = windowSize

        func rmsEnergy() -> Float {
            return sqrt(sumSquares / Float(windowSize))
        }

        while windowEnd <= samples.count {
            let energy = rmsEnergy()

            if energy > energyThreshold {
                if !isSpeech {
                    speechStartSample = windowStart
                    isSpeech = true
                }
                lastSpeechEndSample = windowEnd
            } else {
                if isSpeech {
                    let silenceDuration = Double(windowStart - lastSpeechEndSample) / sampleRate
                    if silenceDuration > minSilenceDuration {
                        let speechDuration = Double(lastSpeechEndSample - speechStartSample) / sampleRate
                        if speechDuration > minSpeechDuration {
                            speechSegments.append(SpeechSegment(
                                startTime: Double(speechStartSample) / sampleRate,
                                endTime: Double(lastSpeechEndSample) / sampleRate,
                                startSample: speechStartSample,
                                endSample: lastSpeechEndSample
                            ))
                        }
                        isSpeech = false
                    }
                }
            }

            // Advance by hop; update sumSquares incrementally
            if windowEnd + hopSize > samples.count {
                break
            }

            // Remove leaving samples
            let leaveCount = hopSize
            for i in windowStart..<(windowStart + leaveCount) {
                let s = samples[i]
                sumSquares -= s * s
            }
            // Add incoming samples
            for i in windowEnd..<(windowEnd + hopSize) {
                let s = samples[i]
                sumSquares += s * s
            }

            windowStart += hopSize
            windowEnd += hopSize
        }

        // Close any pending speech segment
        if isSpeech {
            let speechDuration = Double(lastSpeechEndSample - speechStartSample) / sampleRate
            if speechDuration > minSpeechDuration {
                speechSegments.append(SpeechSegment(
                    startTime: Double(speechStartSample) / sampleRate,
                    endTime: Double(lastSpeechEndSample) / sampleRate,
                    startSample: speechStartSample,
                    endSample: lastSpeechEndSample
                ))
            }
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
        // Pure VAD-based segmentation - each speech segment becomes its own chunk
        
        // Convert audio to Whisper format first
        guard let allSamples = convertToWhisperFormat(from: audioURL) else {
            print("❌ Failed to convert audio to Whisper format")
            return nil
        }
        
        let totalDuration = Double(allSamples.count) / targetSampleRate
        
        // If VAD is disabled, process entire audio as single chunk
        if !vadEnabled {
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
        // Creating audio chunks with fixed window and optional overlap
        
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
        
        // Source format and total duration available if needed
        
        // If the audio is shorter than maxDuration, process as single chunk
        if totalDuration <= maxDuration {
            guard let samples = convertAudioFile(audioFile, toFormat: outputFormat) else { return nil }
            return [(samples: samples, startTime: 0.0, endTime: totalDuration)]
        }
        
        // Calculate chunks
        var chunks: [(samples: [Float], startTime: Double, endTime: Double)] = []
        var currentStart: Double = 0.0
        
        while currentStart < totalDuration {
            let currentEnd = min(currentStart + maxDuration, totalDuration)
            let actualStart = max(0.0, currentStart - (chunks.count > 0 ? overlap : 0.0))
            
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
        
        // Convert to target format if needed. Only skip when buffer is already Float32 mono 16k non-interleaved
        if abs(sourceFormat.sampleRate - targetFormat.sampleRate) < 1.0 &&
           sourceFormat.channelCount == targetFormat.channelCount &&
           sourceFormat.commonFormat == .pcmFormatFloat32 &&
           sourceFormat.isInterleaved == false {
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
}
