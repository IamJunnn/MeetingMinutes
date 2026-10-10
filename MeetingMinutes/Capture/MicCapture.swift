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
    /// The tap is running. Its own flag now: with no file to keep, the writer cannot stand for it.
    private var running = false

    private let firstSampleLock = NSLock()   // also guards _lastActivityDate
    private var _firstSampleHostSeconds: Double?
    /// Host time of the first sample actually written to disk. The same as the first captured sample for an ordinary
    /// recording, later than it when the Prompter was listening first and the owner then asked to keep it.
    private var _firstWrittenHostSeconds: Double?
    private var _lastActivityDate = Date()
    /// The tap's format, kept so a file can be opened for it partway through a run.
    private var format: AVAudioFormat?

    /// A listener on the live mic, for a transcript while the meeting runs: each
    /// buffer as captured and whether it carried sound. Called on the audio
    /// thread, so it must hand the buffer on and return.
    var onBuffer: ((AVAudioPCMBuffer, Bool) -> Void)?

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

    /// Host time of the first sample in the file on disk, which is what the two tracks are aligned by.
    var firstWrittenHostSeconds: Double? {
        firstSampleLock.lock()
        defer { firstSampleLock.unlock() }
        return _firstWrittenHostSeconds ?? _firstSampleHostSeconds
    }

    /// `outputURL` nil: the tap runs and buffers go to `onBuffer`, and nothing is written to disk. That is the
    /// Prompter listening without a recording, which the owner asked for (2026-10-09).
    func start(outputURL: URL?) throws {
        // The device is chosen rather than left to the system default. On a Mac with no microphone of its own the
        // default is nothing at all, and opening the input node then has macOS call the owner's iPhone over
        // Continuity: the phone lights up in the middle of the call (Jun, 2026-10-10). See AudioInputDevice.
        guard let device = AudioInputDevice.chosen() else { throw CaptureError.noMicrophone }
        let input = engine.inputNode
        do {
            try input.auAudioUnit.setDeviceID(device)
        } catch {
            // Could not pin it. Carrying on would leave the engine on whatever the system default is, which is the
            // thing being avoided, so that is allowed only when the default is already this device.
            guard AudioInputDevice.isSystemDefault(device) else { throw CaptureError.noMicrophone }
            logger.warning("could not pin the input device, staying on the system default: \(error.localizedDescription)")
        }

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
        self.format = format

        let file = try outputURL.map { try FragmentedAudioWriter(url: $0, settings: Self.settings(for: format)) }
        self.file = file

        let rawURL = outputURL?.deletingLastPathComponent().appendingPathComponent("mic-raw.m4a")
        self.rawFile = rawURL.flatMap { try? FragmentedAudioWriter(url: $0, settings: Self.rawSettings(for: format)) }

        firstSampleLock.lock()
        _firstSampleHostSeconds = nil
        _firstWrittenHostSeconds = nil
        _lastActivityDate = Date()
        firstSampleLock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self, self.running else { return }
            let active = AudioActivity.isActive(buffer)
            self.firstSampleLock.lock()
            if self._firstSampleHostSeconds == nil, when.isHostTimeValid {
                self._firstSampleHostSeconds = AVAudioTime.seconds(forHostTime: when.hostTime)
            }
            if active { self._lastActivityDate = Date() }
            if self.file != nil, self._firstWrittenHostSeconds == nil, when.isHostTimeValid {
                self._firstWrittenHostSeconds = AVAudioTime.seconds(forHostTime: when.hostTime)
            }
            self.firstSampleLock.unlock()
            self.file?.append(buffer)
            self.rawFile?.append(buffer)
            self.onBuffer?(buffer, active)
        }

        running = true
        engine.prepare()
        try engine.start()
        logger.info("Microphone capture started at \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
    }

    private static func settings(for format: AVAudioFormat) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
         AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 128_000]
    }

    /// Lossless sidecar for the offline echo canceller: cancelling through the AAC round trip costs about 10 dB of
    /// depth, so EchoCanceller prefers this copy and deletes it when its analysis is done. Best effort: without it the
    /// canceller falls back to the AAC track.
    private static func rawSettings(for format: AVAudioFormat) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: format.sampleRate,
         AVNumberOfChannelsKey: format.channelCount, AVEncoderBitDepthHintKey: 24]
    }

    /// Start writing partway through a run. The Prompter listens with nothing on disk, and the owner can decide in the
    /// middle of a call to keep the rest of it; the tap is already going, so this only hands it a file to write to.
    func beginWriting(to url: URL) throws {
        guard running, file == nil, let format else { throw CaptureError.cannotAddInput }
        let f = try FragmentedAudioWriter(url: url, settings: Self.settings(for: format))
        let raw = try? FragmentedAudioWriter(url: url.deletingLastPathComponent().appendingPathComponent("mic-raw.m4a"),
                                             settings: Self.rawSettings(for: format))
        firstSampleLock.lock()
        _firstWrittenHostSeconds = nil
        firstSampleLock.unlock()
        rawFile = raw
        file = f   // last: the tap writes as soon as this is set
        logger.info("Microphone now writing to disk")
    }

    func stop() async {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let file = self.file, rawFile = self.rawFile
        self.file = nil
        self.rawFile = nil
        await file?.finish()
        await rawFile?.finish()
        logger.info("Microphone capture stopped")
    }
}
