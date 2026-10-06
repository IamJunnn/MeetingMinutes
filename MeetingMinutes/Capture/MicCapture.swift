import AVFoundation
import OSLog

/// Captures the local microphone and writes it to its own AAC (.m4a) file,
/// fragmented so a recording cut off by a shutdown stays playable.
///
/// We keep the microphone on a separate track from the system audio so that,
/// downstream, transcription can attribute speech to "You" vs. "Participants"
/// for free — without needing a diarization model.
final class MicCapture {
    private let logger = Logger(subsystem: "build.ecoblox.MeetingMinutes", category: "MicCapture")
    private let engine = AVAudioEngine()
    private var file: FragmentedAudioWriter?
    private var rawFile: FragmentedAudioWriter?

    private let firstSampleLock = NSLock()   // also guards _lastActivityDate
    private var _firstSampleHostSeconds: Double?
    private var _lastActivityDate = Date()

    /// When the mic last picked up sound above the silence threshold (or when
    /// capture started). RecordingController auto-stops a forgotten recording
    /// once both tracks have been quiet for a while.
    var lastActivityDate: Date {
        firstSampleLock.lock()
        defer { firstSampleLock.unlock() }
        return _lastActivityDate
    }

    /// Host-clock time (seconds) of the first captured sample — pairs with the
    /// system track's timestamp to align the two tracks on one timeline.
    var firstSampleHostSeconds: Double? {
        firstSampleLock.lock()
        defer { firstSampleLock.unlock() }
        return _firstSampleHostSeconds
    }

    func start(outputURL: URL) throws {
        let input = engine.inputNode

        // NOTE: macOS voice processing (setVoiceProcessingEnabled) is deliberately
        // NOT used here. It provides acoustic echo cancellation, but on this OS it
        // has two unacceptable side effects the moment recording starts:
        //   1. It *ducks* all other audio — the meeting drops to a low volume. The
        //      documented `voiceProcessingOtherAudioDuckingConfiguration = .min`
        //      remedy does NOT stop this on macOS 26.
        //   2. It reconfigures/seizes the shared input device, which knocks the mic
        //      out from under the meeting app — the other participants stop hearing
        //      you.
        // We therefore capture the raw mic (a passive tap that shares the device),
        // which leaves both the output volume and the meeting app's mic untouched.
        // Echo bleed (meeting audio leaking into the mic on speakers) is removed
        // offline by `EchoCanceller` after the recording, using the system track
        // as the reference signal.

        // The format the tap will deliver buffers in; the file keeps its rate and
        // channel count.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw CaptureError.noMicrophone }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 128_000
        ]
        let file = try FragmentedAudioWriter(url: outputURL, settings: settings)
        self.file = file

        // Lossless sidecar for the offline echo canceller: cancelling through
        // the AAC round-trip costs ~10 dB of depth, so EchoCanceller prefers
        // this copy and deletes it when its analysis is done. Best-effort —
        // without it the canceller falls back to the AAC track.
        let rawSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitDepthHintKey: 24
        ]
        let rawURL = outputURL.deletingLastPathComponent().appendingPathComponent("mic-raw.m4a")
        self.rawFile = try? FragmentedAudioWriter(url: rawURL, settings: rawSettings)

        firstSampleLock.lock()
        _firstSampleHostSeconds = nil
        _lastActivityDate = Date()
        firstSampleLock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self, let file = self.file else { return }
            let active = AudioActivity.isActive(buffer)
            self.firstSampleLock.lock()
            if self._firstSampleHostSeconds == nil, when.isHostTimeValid {
                self._firstSampleHostSeconds = AVAudioTime.seconds(forHostTime: when.hostTime)
            }
            if active { self._lastActivityDate = Date() }
            self.firstSampleLock.unlock()
            file.append(buffer)
            self.rawFile?.append(buffer)
        }

        engine.prepare()
        try engine.start()
        logger.info("Microphone capture started at \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
    }

    func stop() async {
        guard let file else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let rawFile = self.rawFile
        self.file = nil
        self.rawFile = nil
        await file.finish()
        await rawFile?.finish()
        logger.info("Microphone capture stopped")
    }
}
