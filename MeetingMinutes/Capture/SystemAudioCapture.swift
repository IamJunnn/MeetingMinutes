import ScreenCaptureKit
import AVFoundation
import OSLog

/// Captures system audio (everything coming out of the Mac's output — i.e. the
/// other meeting participants) using ScreenCaptureKit, and writes it to its own
/// AAC (.m4a) file.
///
/// We capture a display purely because ScreenCaptureKit requires a content
/// filter to produce audio; the video frames are tiny and discarded. This works
/// with any meeting app (Zoom, Meet, Teams, …) because it taps the system mix
/// rather than integrating with a specific client.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let logger = Logger(subsystem: "build.ecoblox.MeetingMinutes", category: "SystemAudioCapture")
    private let sampleQueue = DispatchQueue(label: "build.ecoblox.MeetingMinutes.systemaudio")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var rawFile: AVAudioFile?           // lossless sidecar, see start()
    private var rawConverter: AVAudioConverter?

    private let firstSampleLock = NSLock()
    private var _firstSampleHostSeconds: Double?

    /// Host-clock time (seconds) of the first captured sample — ScreenCaptureKit
    /// timestamps are on the host clock, so this pairs with the mic track's
    /// timestamp to measure how much later system capture actually began.
    var firstSampleHostSeconds: Double? {
        firstSampleLock.lock()
        defer { firstSampleLock.unlock() }
        return _firstSampleHostSeconds
    }

    func start(outputURL: URL) async throws {
        // No lock needed: the stream (and thus the writing side) isn't running yet.
        _firstSampleHostSeconds = nil
        // Requesting shareable content triggers (and requires) the Screen
        // Recording permission. ScreenCaptureKit needs a display to attach to.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // don't record our own UI sounds
        config.sampleRate = 48_000
        config.channelCount = 2
        // Video is required by the API but unused; keep it minimal.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureError.cannotAddInput }
        writer.add(input)
        self.writer = writer
        self.audioInput = input

        // Lossless sidecar for the offline echo canceller: cancelling through
        // the AAC round-trip costs ~10 dB of depth, so EchoCanceller prefers
        // this copy and deletes it when its analysis is done. Best-effort —
        // without it the canceller falls back to the AAC track.
        let rawSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2
        ]
        let rawURL = outputURL.deletingLastPathComponent().appendingPathComponent("system-raw.m4a")
        self.rawFile = try? AVAudioFile(forWriting: rawURL, settings: rawSettings)
        self.rawConverter = nil

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        self.stream = stream

        try await stream.startCapture()
        logger.info("System audio capture started")
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        await finishWriting()
        logger.info("System audio capture stopped")
    }

    private func finishWriting() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sampleQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.rawFile = nil      // closes the sidecar
                self.rawConverter = nil
                guard let writer = self.writer, let input = self.audioInput else {
                    continuation.resume()
                    return
                }
                input.markAsFinished()
                if writer.status == .writing {
                    writer.finishWriting {
                        self.writer = nil
                        self.audioInput = nil
                        continuation.resume()
                    }
                } else {
                    self.writer = nil
                    self.audioInput = nil
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // This runs on `sampleQueue`, the same queue we mutate the writer on.
        guard type == .audio,
              CMSampleBufferDataIsReady(sampleBuffer),
              let writer = self.writer,
              let input = self.audioInput else { return }

        if writer.status == .unknown {
            let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: start)
            firstSampleLock.lock()
            _firstSampleHostSeconds = CMTimeGetSeconds(start)
            firstSampleLock.unlock()
        }

        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
        writeRawSidecar(sampleBuffer)
    }

    /// Append the sample buffer to the lossless sidecar, converting from the
    /// stream's PCM layout to the file's processing format when they differ.
    private func writeRawSidecar(_ sampleBuffer: CMSampleBuffer) {
        guard let rawFile,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: description)
        guard frames > 0,
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames) else { return }
        source.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                           into: source.mutableAudioBufferList) == noErr else { return }

        if source.format == rawFile.processingFormat {
            try? rawFile.write(from: source)
            return
        }
        if rawConverter == nil || rawConverter?.inputFormat != source.format {
            rawConverter = AVAudioConverter(from: source.format, to: rawFile.processingFormat)
        }
        guard let converter = rawConverter,
              let converted = AVAudioPCMBuffer(pcmFormat: rawFile.processingFormat, frameCapacity: frames) else { return }
        do {
            try converter.convert(to: converted, from: source)
            try rawFile.write(from: converted)
        } catch {
            logger.error("Lossless sidecar write failed: \(error.localizedDescription)")
            self.rawFile = nil   // don't spam per-buffer errors; canceller falls back to AAC
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("System audio stream stopped with error: \(error.localizedDescription)")
    }
}
