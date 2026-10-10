import AVFoundation
import Accelerate

/// Cheap "is anyone making sound?" check on a PCM buffer. RecordingController
/// uses it to notice a recording that was left running after the meeting
/// ended and stop it on its own.
enum AudioActivity {
    /// RMS level (dBFS) at or below which a buffer counts as silence. Speech
    /// at a normal distance sits around -20…-35 dBFS; a quiet room's noise
    /// floor is typically below -50.
    static let silenceThresholdDB: Float = -45

    /// True when the buffer's RMS level is above the silence threshold.
    /// Non-float formats are treated as active — better to never auto-stop
    /// than to cut a real meeting short on a format we don't meter.
    static func isActive(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let db = decibels(buffer) else { return true }
        return db > silenceThresholdDB
    }

    /// How loud the buffer is, 0 for the noise floor (-60 dBFS and under) to 1 for full scale, for a meter that
    /// moves with the call. Nil for a format we do not meter.
    static func level(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard let db = decibels(buffer) else { return nil }
        return min(1, max(0, (db + 60) / 60))
    }

    /// RMS level in dBFS, or nil for a non-float format. Minus infinity for a buffer of zeros.
    static func decibels(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return -.infinity }

        var meanSquare: Float = 0
        if buffer.format.isInterleaved {
            var rms: Float = 0
            vDSP_rmsqv(channels[0], 1, &rms, vDSP_Length(frames * channelCount))
            meanSquare = rms * rms
        } else {
            for channel in 0..<channelCount {
                var rms: Float = 0
                vDSP_rmsqv(channels[channel], 1, &rms, vDSP_Length(frames))
                meanSquare += rms * rms / Float(channelCount)
            }
        }
        guard meanSquare > 0 else { return -.infinity }
        return 10 * log10(meanSquare)
    }
}
