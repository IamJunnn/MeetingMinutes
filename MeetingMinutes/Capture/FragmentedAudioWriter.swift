import AVFoundation
import OSLog

/// Writes one audio track as fragmented MPEG-4: the header goes out at the
/// start and a self-contained fragment follows every `fragmentInterval`. A file
/// cut off by a shutdown, crash, or power loss stays playable up to its last
/// fragment. A plain m4a (AVAudioFile, or AVAssetWriter without fragments)
/// only gets its index on close, and without it none of the audio can be opened.
///
/// Accepts both PCM buffers (the mic tap) and sample buffers (ScreenCaptureKit).
/// Appends and `finish()` may come from different threads; a lock serializes them.
final class FragmentedAudioWriter {
    static let fragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

    private let logger = Logger(subsystem: "build.ecoblox.MeetingMinutes", category: "FragmentedAudioWriter")
    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false
    private var finished = false
    private var framesWritten: Int64 = 0
    private var loggedFailure = false

    init(url: URL, settings: [String: Any]) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        writer.movieFragmentInterval = Self.fragmentInterval
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureError.cannotAddInput }
        writer.add(input)
    }

    /// Append PCM on this track's own timeline, starting at zero.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, buffer.frameLength > 0 else { return }
        let rate = CMTimeScale(buffer.format.sampleRate)
        if !started { begin(at: .zero) }
        guard let sample = Self.sampleBuffer(buffer, at: CMTime(value: framesWritten, timescale: rate)) else { return }
        framesWritten += Int64(buffer.frameLength)
        write(sample)
    }

    /// Append a captured sample buffer; the session starts at its timestamp.
    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        if !started { begin(at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) }
        write(sampleBuffer)
    }

    /// Close the file. Safe to call more than once, and on a writer that never
    /// received audio.
    func finish() async {
        let writer: AVAssetWriter? = {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return nil }
            finished = true
            guard started, self.writer.status == .writing else { return nil }
            input.markAsFinished()
            return self.writer
        }()
        guard let writer else { return }
        await writer.finishWriting()
        if writer.status == .failed {
            logger.error("Finishing \(writer.outputURL.lastPathComponent, privacy: .public) failed: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
        }
    }

    // Callers hold `lock`.
    private func begin(at time: CMTime) {
        started = true
        writer.startWriting()
        writer.startSession(atSourceTime: time)
    }

    private func write(_ sample: CMSampleBuffer) {
        guard writer.status == .writing else {
            if !loggedFailure {
                loggedFailure = true
                logger.error("\(self.writer.outputURL.lastPathComponent, privacy: .public) stopped writing: \(self.writer.error?.localizedDescription ?? "unknown", privacy: .public)")
            }
            return
        }
        // Real-time capture can't wait; a busy encoder drops this buffer.
        guard input.isReadyForMoreMediaData else { return }
        input.append(sample)
    }

    private static func sampleBuffer(_ buffer: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: time.timescale), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: buffer.format.formatDescription, sampleCount: CMItemCount(buffer.frameLength),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sample) == noErr,
              let sample,
              CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                             flags: 0, bufferList: buffer.audioBufferList) == noErr
        else { return nil }
        return sample
    }
}
