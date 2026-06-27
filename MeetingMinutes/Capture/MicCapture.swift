import AVFoundation
import OSLog

/// Captures the local microphone and writes it to its own AAC (.m4a) file.
///
/// We keep the microphone on a separate track from the system audio so that,
/// downstream, transcription can attribute speech to "You" vs. "Participants"
/// for free — without needing a diarization model.
final class MicCapture {
    private let logger = Logger(subsystem: "build.ecoblox.MeetingMinutes", category: "MicCapture")
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?

    func start(outputURL: URL) throws {
        let input = engine.inputNode

        // Enable macOS voice processing on the mic input: acoustic echo
        // cancellation (so meeting audio played back through the speakers
        // doesn't bleed into the mic and get mislabeled as "You"), plus noise
        // suppression and automatic gain control. Best-effort — if it can't be
        // enabled we fall back to raw capture rather than failing the recording.
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            logger.error("Voice processing unavailable, capturing raw mic: \(error.localizedDescription)")
        }

        // The format the tap will deliver buffers in. Query it *after* enabling
        // voice processing — that forces its own processing format (typically
        // 48 kHz) — and match the file's settings to it so AVAudioFile can write
        // without a format mismatch.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw CaptureError.noMicrophone }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 128_000
        ]
        let file = try AVAudioFile(forWriting: outputURL, settings: settings)
        self.file = file

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }
            do {
                try file.write(from: buffer)
            } catch {
                self.logger.error("Microphone write failed: \(error.localizedDescription)")
            }
        }

        engine.prepare()
        try engine.start()
        logger.info("Microphone capture started at \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
    }

    func stop() {
        guard file != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        logger.info("Microphone capture stopped")
    }
}
