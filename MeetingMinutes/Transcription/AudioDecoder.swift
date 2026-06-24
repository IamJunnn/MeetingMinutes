import AVFoundation

/// Decodes an audio file (our .m4a tracks) into the format Whisper requires:
/// 16 kHz, mono, 32-bit float PCM samples.
///
/// Reads and converts in chunks so memory stays flat regardless of how long the
/// meeting was.
enum AudioDecoder {
    enum DecodeError: LocalizedError {
        case cannotCreateConverter
        case cannotAllocateBuffer

        var errorDescription: String? {
            switch self {
            case .cannotCreateConverter: return "Could not create the audio converter."
            case .cannotAllocateBuffer: return "Could not allocate an audio buffer."
            }
        }
    }

    static func decodeTo16kMonoFloat(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { return [] }

        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16_000,
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw DecodeError.cannotCreateConverter
        }

        let inputChunkFrames: AVAudioFrameCount = 16_384
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputChunkFrames),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: inputChunkFrames) else {
            throw DecodeError.cannotAllocateBuffer
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * 16_000 / inputFormat.sampleRate) + Int(inputChunkFrames))

        while true {
            outputBuffer.frameLength = 0
            var conversionError: NSError?

            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                do {
                    inputBuffer.frameLength = 0
                    try file.read(into: inputBuffer)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError { throw conversionError }

            if let channel = outputBuffer.floatChannelData, outputBuffer.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(outputBuffer.frameLength)))
            }

            if status == .endOfStream || status == .error { break }
        }

        return samples
    }
}
