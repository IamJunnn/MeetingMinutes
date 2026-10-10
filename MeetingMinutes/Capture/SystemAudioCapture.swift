import ScreenCaptureKit
import AVFoundation
import OSLog

/// Captures system audio (everything coming out of the Mac's output — i.e. the
/// other meeting participants) using ScreenCaptureKit, and writes it to its own
/// AAC (.m4a) file, fragmented so a recording cut off by a shutdown stays playable.
///
/// We capture a display purely because ScreenCaptureKit requires a content
/// filter to produce audio; the video frames are tiny and discarded. This works
/// with any meeting app (Zoom, Meet, Teams, …) because it taps the system mix
/// rather than integrating with a specific client.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let logger = Logger(subsystem: "build.ecoblox.MeetingMinutes", category: "SystemAudioCapture")
    private let sampleQueue = DispatchQueue(label: "build.ecoblox.MeetingMinutes.systemaudio")

    private var stream: SCStream?
    // Touched only on `sampleQueue` once capture runs.
    private var writer: FragmentedAudioWriter?
    private var rawWriter: FragmentedAudioWriter?   // lossless sidecar, see start()
    private var sawFirstSample = false

    private let firstSampleLock = NSLock()   // also guards _lastActivityDate
    private var _firstSampleHostSeconds: Double?
    /// Presentation time of the first sample written to disk. Later than the first captured one when the Prompter was
    /// listening and the owner then asked for the rest of the call to be kept.
    private var _firstWrittenHostSeconds: Double?
    private var _lastActivityDate = Date()

    /// A listener on the live call audio, for a transcript while the meeting
    /// runs: each buffer in the stream's own format and whether it carried
    /// sound. Called on the sample queue, so it must hand the buffer on and return.
    var onBuffer: ((AVAudioPCMBuffer, Bool) -> Void)?

    /// When the system mix last carried sound above the silence threshold (or
    /// when capture started). See RecordingController's silence auto-stop.
    var lastActivityDate: Date {
        firstSampleLock.lock()
        defer { firstSampleLock.unlock() }
        return _lastActivityDate
    }

    /// Host-clock time (seconds) of the first captured sample — ScreenCaptureKit
    /// timestamps are on the host clock, so this pairs with the mic track's
    /// timestamp to measure how much later system capture actually began.
    var firstSampleHostSeconds: Double? {
        firstSampleLock.lock()
        defer { firstSampleLock.unlock() }
        return _firstSampleHostSeconds
    }

    /// Time of the first sample in the file on disk, which is what the two tracks are aligned by.
    var firstWrittenHostSeconds: Double? {
        firstSampleLock.lock()
        defer { firstSampleLock.unlock() }
        return _firstWrittenHostSeconds ?? _firstSampleHostSeconds
    }

    /// `outputURL` nil: the stream runs and buffers go to `onBuffer`, and nothing is written to disk.
    private static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
    ]

    /// Lossless sidecar for the offline echo canceller: cancelling through the AAC round trip costs about 10 dB of
    /// depth, so EchoCanceller prefers this copy and deletes it when its analysis is done. Best effort: without it the
    /// canceller falls back to the AAC track.
    private static let rawSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 24,
    ]

    /// Start writing partway through a run, for a Prompter that was only listening until the owner asked to keep the
    /// call. The writers are handed over on the sample queue, the one place they are ever touched.
    func beginWriting(to url: URL) throws {
        guard stream != nil, writer == nil else { throw CaptureError.cannotAddInput }
        let w = try FragmentedAudioWriter(url: url, settings: Self.settings)
        let raw = try? FragmentedAudioWriter(url: url.deletingLastPathComponent().appendingPathComponent("system-raw.m4a"),
                                             settings: Self.rawSettings)
        sampleQueue.async { [weak self] in
            guard let self else { return }
            self.firstSampleLock.lock()
            self._firstWrittenHostSeconds = nil
            self.firstSampleLock.unlock()
            self.rawWriter = raw
            self.writer = w
        }
        logger.info("System audio now writing to disk")
    }

    func start(outputURL: URL?) async throws {
        // No lock needed: the stream (and thus the writing side) isn't running yet.
        _firstSampleHostSeconds = nil
        _firstWrittenHostSeconds = nil
        _lastActivityDate = Date()
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

        self.writer = try outputURL.map { try FragmentedAudioWriter(url: $0, settings: Self.settings) }
        sawFirstSample = false

        let rawURL = outputURL?.deletingLastPathComponent().appendingPathComponent("system-raw.m4a")
        self.rawWriter = rawURL.flatMap { try? FragmentedAudioWriter(url: $0, settings: Self.rawSettings) }

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
        // Hand the writers over on the sample queue so no append races the close.
        let writers: [FragmentedAudioWriter] = await withCheckedContinuation { continuation in
            sampleQueue.async { [weak self] in
                guard let self else { return continuation.resume(returning: []) }
                let writers = [self.writer, self.rawWriter].compactMap { $0 }
                self.writer = nil
                self.rawWriter = nil
                continuation.resume(returning: writers)
            }
        }
        for writer in writers { await writer.finish() }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // This runs on `sampleQueue`, the same queue the writers are handed over on.
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer), self.stream != nil else { return }

        if !sawFirstSample {
            sawFirstSample = true
            firstSampleLock.lock()
            _firstSampleHostSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            firstSampleLock.unlock()
        }
        if writer != nil {
            firstSampleLock.lock()
            if _firstWrittenHostSeconds == nil { _firstWrittenHostSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) }
            firstSampleLock.unlock()
        }
        writer?.append(sampleBuffer)
        rawWriter?.append(sampleBuffer)

        guard let source = Self.pcmBuffer(from: sampleBuffer) else { return }
        let active = AudioActivity.isActive(source)
        if active {
            firstSampleLock.lock()
            _lastActivityDate = Date()
            firstSampleLock.unlock()
        }
        onBuffer?(source, active)
    }

    /// Copy the sample buffer's PCM data into an AVAudioPCMBuffer in the
    /// stream's native format.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: description)
        guard frames > 0,
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames) else { return nil }
        source.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                           into: source.mutableAudioBufferList) == noErr else { return nil }
        return source
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("System audio stream stopped with error: \(error.localizedDescription)")
    }
}
