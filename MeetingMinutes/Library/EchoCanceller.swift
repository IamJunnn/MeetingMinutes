import AVFoundation
import Accelerate
import Foundation
import OSLog

/// Offline acoustic echo cancellation for a recorded session.
///
/// When the user is on speakers, the mic picks up the meeting audio coming out
/// of them, so the participants' voices land on the mic track a beat behind
/// their clean copy on the system track — audible as an echo in mixed playback
/// and transcribed as phantom "You" lines. The mic is captured raw on purpose
/// (see MicCapture for why live voice-processing AEC is off), so the bleed is
/// removed here, after the fact.
///
/// We hold a perfect reference of exactly what leaked into the mic (the system
/// track) and we process offline — a far easier problem than live AEC:
///  1. Estimate the delay between the tracks by cross-correlating decimated
///     copies. The tracks start at different moments (system capture spins up
///     after the mic), and the estimate is tracked per-chunk so slow clock
///     drift over a long meeting can't walk the echo out of the filter window.
///  2. Run an NLMS adaptive filter over the mic track with the system track as
///     reference, writing the echo-free residual to `mic-clean.m4a`.
///
/// The measured track offset is persisted to `alignment.json` so the mixer and
/// transcription can place both tracks on one shared timeline. If no
/// correlated audio is found (headphones — nothing bled), no cleaned file is
/// written and the raw mic is used as-is.
actor EchoCanceller {
    static let shared = EchoCanceller()

    struct Alignment: Codable {
        /// Seconds the system track starts after the mic track (negative if before).
        var systemOffsetSeconds: Double
        /// Whether speaker bleed was found (and therefore `mic-clean.m4a` exists).
        var bleedDetected: Bool
    }

    private static let logger = Logger(subsystem: "build.ecoblox.MeetingMinutes", category: "EchoCanceller")
    private var inFlight: [String: Task<URL, Never>] = [:]

    static func cleanedURL(in folder: URL) -> URL {
        folder.appendingPathComponent("mic-clean.m4a")
    }

    static func alignmentURL(in folder: URL) -> URL {
        folder.appendingPathComponent("alignment.json")
    }

    /// Lossless copies of both tracks written during capture and deleted once
    /// analysis completes. Cancelling on these instead of the stored AAC files
    /// is worth ~10 dB: the AAC round-trip decorrelates the tracks enough that
    /// a linear filter can no longer model the echo path through them.
    static func rawSidecarURLs(in folder: URL) -> (mic: URL, system: URL) {
        (folder.appendingPathComponent("mic-raw.m4a"),
         folder.appendingPathComponent("system-raw.m4a"))
    }

    /// The persisted alignment analysis, if it has run for this session.
    static func alignment(in folder: URL) -> Alignment? {
        guard let data = try? Data(contentsOf: alignmentURL(in: folder)) else { return nil }
        return try? JSONDecoder().decode(Alignment.self, from: data)
    }

    /// The mic track downstream consumers should use: `mic-clean.m4a` when
    /// bleed was found and cancelled, otherwise the raw mic. Runs the analysis
    /// on first call for a session and caches the result on disk; concurrent
    /// callers for the same folder share one run.
    func cleanedMicURL(in folder: URL) async -> URL {
        let fm = FileManager.default
        let rawMic = folder.appendingPathComponent("mic.m4a")
        let system = folder.appendingPathComponent("system.m4a")
        guard fm.fileExists(atPath: rawMic.path), fm.fileExists(atPath: system.path) else {
            return rawMic
        }

        if let alignment = Self.alignment(in: folder) {
            if !alignment.bleedDetected { return rawMic }
            let cleaned = Self.cleanedURL(in: folder)
            if fm.fileExists(atPath: cleaned.path) { return cleaned }
            // Analysis says bleed but the file is gone — fall through and redo.
        }

        let key = folder.path
        if let running = inFlight[key] { return await running.value }
        let task = Task.detached(priority: .userInitiated) { () -> URL in
            do {
                let hint = SessionTimes.load(in: folder)?.hintOffsetSeconds
                return try Self.process(micURL: rawMic, systemURL: system, folder: folder, hintOffset: hint)
            } catch {
                Self.logger.error("Echo cancellation failed, using raw mic: \(error.localizedDescription)")
                return rawMic
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    // MARK: - Pipeline

    private enum ProcessingError: Error {
        case unreadableAudio
        case unexpectedSystemFormat
    }

    private static func process(micURL: URL, systemURL: URL, folder: URL, hintOffset: Double?) throws -> URL {
        let fm = FileManager.default
        // Work from the lossless sidecars when capture wrote them; the stored
        // AAC tracks are the fallback for older recordings. Same timeline
        // either way — the sidecar duplicates the exact captured buffers.
        let sidecars = rawSidecarURLs(in: folder)
        let micSource = fm.fileExists(atPath: sidecars.mic.path) ? sidecars.mic : micURL
        let refSource = fm.fileExists(atPath: sidecars.system.path) ? sidecars.system : systemURL

        let analysisRate = 8_000.0
        let mic8 = try decodeMono(url: micSource, sampleRate: analysisRate)
        let ref8 = try decodeMono(url: refSource, sampleRate: analysisRate)

        guard let drift = estimateDelays(mic: mic8, ref: ref8, rate: analysisRate, hintOffset: hintOffset) else {
            // Nothing in the mic correlates with the system audio — headphones,
            // or a mostly silent track. No bleed to cancel; just persist the
            // best-known offset for timeline alignment.
            let alignment = Alignment(systemOffsetSeconds: hintOffset ?? 0, bleedDetected: false)
            try save(alignment, in: folder)
            removeSidecars(in: folder)
            logger.info("No speaker bleed detected; keeping raw mic")
            return micURL
        }

        let output = cleanedURL(in: folder)
        try cancelEcho(micURL: micSource, systemURL: refSource, outputURL: output, drift: drift)
        try save(Alignment(systemOffsetSeconds: drift.globalOffsetSeconds, bleedDetected: true), in: folder)
        removeSidecars(in: folder)
        logger.info("Echo-cancelled mic written (system offset \(String(format: "%.3f", drift.globalOffsetSeconds))s)")
        return output
    }

    /// The lossless sidecars are large and only needed for this analysis —
    /// reclaim the space as soon as a result (either way) is on disk.
    private static func removeSidecars(in folder: URL) {
        let sidecars = rawSidecarURLs(in: folder)
        try? FileManager.default.removeItem(at: sidecars.mic)
        try? FileManager.default.removeItem(at: sidecars.system)
    }

    private static func save(_ alignment: Alignment, in folder: URL) throws {
        let data = try JSONEncoder().encode(alignment)
        try data.write(to: alignmentURL(in: folder), options: .atomic)
    }

    // MARK: - Delay estimation

    /// Per-chunk delay of the system audio as heard in the mic, in seconds.
    private struct Drift {
        var perChunkSeconds: [Double]
        var chunkSeconds: Double
        var globalOffsetSeconds: Double

        func delaySeconds(at time: Double) -> Double {
            guard !perChunkSeconds.isEmpty else { return globalOffsetSeconds }
            let index = min(perChunkSeconds.count - 1, max(0, Int(time / chunkSeconds)))
            return perChunkSeconds[index]
        }
    }

    /// Cross-correlate decimated copies of the tracks to find where the system
    /// audio reappears in the mic. Returns nil when no chunk correlates — i.e.
    /// there is no bleed to cancel.
    private static func estimateDelays(mic: [Float], ref: [Float], rate: Double, hintOffset: Double?) -> Drift? {
        let chunkSeconds = 5.0
        let chunkLen = Int(chunkSeconds * rate)
        let window = Int(3 * rate)              // 3s correlation window per chunk
        let confidenceFloor: Float = 0.06        // normalized peak: real bleed sits well above chance
        let activeRMS: Float = 1e-3              // ~-60 dBFS: is anything playing at all?

        guard mic.count > window, ref.count >= window else { return nil }
        let chunkCount = max(1, ref.count / chunkLen)
        var estimates = [Double?](repeating: nil, count: chunkCount)
        var lastDelay: Double?
        var confident: [Double] = []

        for chunk in 0..<chunkCount {
            let refStart = chunk * chunkLen
            guard refStart + window <= ref.count else { break }
            let refWindow = Array(ref[refStart ..< refStart + window])
            var rms: Float = 0
            vDSP_rmsqv(refWindow, 1, &rms, vDSP_Length(window))
            guard rms > activeRMS else { continue }

            // Once locked on, only track small drift; before that, search
            // around the recorded start-gap hint, then the full ±3s.
            let searchRanges: [(Double, Double)]
            if let locked = lastDelay {
                searchRanges = [(locked - 0.25, locked + 0.25)]
            } else if let hint = hintOffset {
                searchRanges = [(hint - 0.75, hint + 0.75), (-3, 3)]
            } else {
                searchRanges = [(-3, 3)]
            }

            for (lo, hi) in searchRanges {
                guard let (delay, peak) = correlate(mic: mic, refWindow: refWindow, refStart: refStart,
                                                    rate: rate, minSeconds: lo, maxSeconds: hi),
                      peak >= confidenceFloor else { continue }
                estimates[chunk] = delay
                confident.append(delay)
                lastDelay = delay
                break
            }
        }

        guard confident.count >= 2 else { return nil }
        let sorted = confident.sorted()
        let median = sorted[sorted.count / 2]

        // Fill silent/unconfident chunks by carrying the nearest estimate.
        var filled = [Double](repeating: median, count: chunkCount)
        var carried = estimates.compactMap { $0 }.first ?? median
        for chunk in 0..<chunkCount {
            if let estimate = estimates[chunk] { carried = estimate }
            filled[chunk] = carried
        }
        return Drift(perChunkSeconds: filled, chunkSeconds: chunkSeconds, globalOffsetSeconds: median)
    }

    /// Slide `refWindow` (taken from the system track at `refStart`) across the
    /// mic and return the best-matching lag in seconds plus its normalized
    /// correlation peak (0…1).
    private static func correlate(mic: [Float], refWindow: [Float], refStart: Int, rate: Double,
                                  minSeconds: Double, maxSeconds: Double) -> (delay: Double, peak: Float)? {
        let windowLen = refWindow.count
        var minLag = Int(minSeconds * rate)
        var maxLag = Int(maxSeconds * rate)
        // Keep the swept mic slice inside the array.
        minLag = max(minLag, -refStart)
        maxLag = min(maxLag, mic.count - windowLen - refStart)
        guard maxLag >= minLag else { return nil }

        let lagCount = maxLag - minLag + 1
        let sweepStart = refStart + minLag
        var correlation = [Float](repeating: 0, count: lagCount)
        mic.withUnsafeBufferPointer { micPtr in
            refWindow.withUnsafeBufferPointer { refPtr in
                vDSP_conv(micPtr.baseAddress! + sweepStart, 1, refPtr.baseAddress!, 1,
                          &correlation, 1, vDSP_Length(lagCount), vDSP_Length(windowLen))
            }
        }

        var refEnergy: Float = 0
        vDSP_svesq(refWindow, 1, &refEnergy, vDSP_Length(windowLen))
        guard refEnergy > 0 else { return nil }

        // Normalize each lag by the mic window's energy (sliding sum) so peaks
        // are comparable regardless of loudness.
        var micEnergy = 0.0
        for i in 0..<windowLen {
            micEnergy += Double(mic[sweepStart + i]) * Double(mic[sweepStart + i])
        }
        var bestLag = 0
        var bestPeak: Float = -.infinity
        for lag in 0..<lagCount {
            let denominator = (Double(refEnergy) * micEnergy).squareRoot() + 1e-9
            let normalized = Float(Double(correlation[lag]) / denominator)
            if normalized > bestPeak {
                bestPeak = normalized
                bestLag = lag
            }
            if lag + 1 < lagCount {
                let leaving = Double(mic[sweepStart + lag])
                let entering = Double(mic[sweepStart + lag + windowLen])
                micEnergy += entering * entering - leaving * leaving
            }
        }
        return (Double(minLag + bestLag) / rate, bestPeak)
    }

    // MARK: - NLMS cancellation

    /// Stream the mic through an NLMS adaptive filter with the (delay-aligned)
    /// system track as reference, writing the residual — the mic minus its
    /// estimate of the speaker bleed — to `outputURL` at 48 kHz mono AAC.
    ///
    /// Two passes, an offline luxury: pass 1 only adapts (output discarded) so
    /// pass 2 starts already converged and can use a small step size — the
    /// written file is deeply cancelled from its first sample instead of
    /// carrying a convergence tail after every far-end onset.
    private static func cancelEcho(micURL: URL, systemURL: URL, outputURL: URL, drift: Drift) throws {
        let rate = 48_000.0
        let taps = 1536                          // ~32ms of echo path around the aligned delay

        let refFile = try AVAudioFile(forReading: systemURL)
        // Random access below indexes the system track by frame, which needs
        // its native rate to be the processing rate (SystemAudioCapture
        // records at 48 kHz).
        guard refFile.processingFormat.sampleRate == rate else {
            throw ProcessingError.unexpectedSystemFormat
        }

        try? FileManager.default.removeItem(at: outputURL)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ]
        let outFile = try AVAudioFile(forWriting: outputURL, settings: settings)

        var weights = [Float](repeating: 0, count: taps)
        try runPass(micURL: micURL, refFile: refFile, drift: drift, weights: &weights,
                    taps: taps, mu: 0.5, rate: rate, output: nil)
        try runPass(micURL: micURL, refFile: refFile, drift: drift, weights: &weights,
                    taps: taps, mu: 0.1, rate: rate, output: outFile)
    }

    private static func runPass(micURL: URL, refFile: AVAudioFile, drift: Drift, weights: inout [Float],
                                taps: Int, mu: Float, rate: Double, output: AVAudioFile?) throws {
        let chunkFrames = 10 * 48_000            // process in 10s chunks
        guard let micReader = MonoStreamReader(url: micURL, sampleRate: rate) else {
            throw ProcessingError.unreadableAudio
        }

        var chunkStart = 0
        while let micBuffer = micReader.read(frames: AVAudioFrameCount(chunkFrames)), micBuffer.frameLength > 0 {
            let frames = Int(micBuffer.frameLength)
            var mic = Array(UnsafeBufferPointer(start: micBuffer.floatChannelData![0], count: frames))

            let midTime = (Double(chunkStart) + Double(frames) / 2) / rate
            let delayFrames = Int((drift.delaySeconds(at: midTime) * rate).rounded())

            // Reference slice covering every tap window of this chunk: output
            // sample chunkStart+t filters ref[(chunkStart+t-delay-taps+1) ... (chunkStart+t-delay)],
            // so local window t is ref[t ..< t+taps] within this slice.
            let refBase = Int64(chunkStart - delayFrames - (taps - 1))
            let ref = try readReferenceMono(file: refFile, start: refBase, count: frames + taps - 1)

            filterChunk(mic: &mic, ref: ref, weights: &weights, taps: taps, mu: mu)

            if let output {
                guard let outBuffer = AVAudioPCMBuffer(pcmFormat: output.processingFormat,
                                                       frameCapacity: AVAudioFrameCount(frames)) else {
                    throw ProcessingError.unreadableAudio
                }
                outBuffer.frameLength = AVAudioFrameCount(frames)
                mic.withUnsafeBufferPointer {
                    outBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: frames)
                }
                try output.write(from: outBuffer)
            }
            chunkStart += frames
        }
    }

    /// One NLMS pass over a chunk, in place: `mic` comes in as the raw signal
    /// and leaves as the echo-cancelled residual. `weights` (the learned echo
    /// path) carries across chunks.
    private static func filterChunk(mic: inout [Float], ref: [Float], weights: inout [Float], taps: Int, mu: Float) {
        let frames = mic.count
        let block = 1024

        mic.withUnsafeMutableBufferPointer { micBuf in
            ref.withUnsafeBufferPointer { refBuf in
                weights.withUnsafeMutableBufferPointer { weightBuf in
                    let m = micBuf.baseAddress!
                    let r = refBuf.baseAddress!
                    let w = weightBuf.baseAddress!

                    var t = 0
                    while t < frames {
                        let blockLen = min(block, frames - t)
                        let sliceLen = vDSP_Length(blockLen + taps - 1)

                        // Nothing playing on the speakers → nothing can have
                        // bled; pass the block through untouched.
                        var refRMS: Float = 0
                        vDSP_rmsqv(r + t, 1, &refRMS, sliceLen)
                        if refRMS < 1e-4 { t += blockLen; continue }

                        // Freeze adaptation while the near end (the user) is
                        // likely talking over the far end, so their voice isn't
                        // absorbed into the echo model (Geigel detector). The
                        // filter still subtracts with its current weights.
                        var micPeak: Float = 0
                        var refPeak: Float = 0
                        vDSP_maxmgv(m + t, 1, &micPeak, vDSP_Length(blockLen))
                        vDSP_maxmgv(r + t, 1, &refPeak, sliceLen)
                        let adapt = micPeak < refPeak

                        let original = Array(UnsafeBufferPointer(start: m + t, count: blockLen))
                        var micEnergy: Float = 0
                        vDSP_svesq(m + t, 1, &micEnergy, vDSP_Length(blockLen))

                        // Running ‖x‖² over the tap window, refreshed each block
                        // so float error can't accumulate.
                        var norm: Float = 0
                        vDSP_svesq(r + t, 1, &norm, vDSP_Length(taps))
                        var runningNorm = Double(norm)
                        var residualEnergy = 0.0

                        for i in t ..< t + blockLen {
                            var estimate: Float = 0
                            vDSP_dotpr(r + i, 1, w, 1, &estimate, vDSP_Length(taps))
                            let residual = m[i] - estimate
                            m[i] = residual
                            residualEnergy += Double(residual) * Double(residual)
                            if adapt {
                                var gain = mu * residual / (Float(runningNorm) + 1e-4)
                                if !gain.isFinite { gain = 0 }
                                // w += gain * x (vsma supports in-place output)
                                vDSP_vsma(r + i, 1, &gain, w, 1, w, 1, vDSP_Length(taps))
                            }
                            if i + 1 < t + blockLen {
                                let entering = Double(r[i + taps])
                                let leaving = Double(r[i])
                                runningNorm += entering * entering - leaving * leaving
                            }
                        }

                        // Safety net: if the filter ever diverges (residual much
                        // louder than the input), reset it and pass the block
                        // through rather than write garbage.
                        if residualEnergy > 4 * Double(micEnergy) + 1e-6 {
                            original.withUnsafeBufferPointer {
                                (m + t).update(from: $0.baseAddress!, count: blockLen)
                            }
                            vDSP_vclr(w, 1, vDSP_Length(taps))
                        }
                        t += blockLen
                    }
                }
            }
        }
    }

    /// Random-access read of the system track as mono floats, zero-padded
    /// wherever the requested range falls outside the file.
    private static func readReferenceMono(file: AVAudioFile, start: Int64, count: Int) throws -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let readStart = max(0, start)
        let readEnd = min(file.length, start + Int64(count))
        let readCount = Int(readEnd - readStart)
        guard readCount > 0 else { return out }

        file.framePosition = readStart
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(readCount)) else { return out }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(readCount))
        guard let channels = buffer.floatChannelData else { return out }

        let got = Int(buffer.frameLength)
        let channelCount = Int(file.processingFormat.channelCount)
        let destinationOffset = Int(readStart - start)
        var scale = 1 / Float(channelCount)
        out.withUnsafeMutableBufferPointer { outBuf in
            let destination = outBuf.baseAddress! + destinationOffset
            for channel in 0..<channelCount {
                // destination += channel * scale (average the channels)
                vDSP_vsma(channels[channel], 1, &scale, destination, 1, destination, 1, vDSP_Length(got))
            }
        }
        return out
    }

    // MARK: - Decoding

    /// Decode an entire file to Float32 mono at the given rate.
    private static func decodeMono(url: URL, sampleRate: Double) throws -> [Float] {
        guard let reader = MonoStreamReader(url: url, sampleRate: sampleRate) else {
            throw ProcessingError.unreadableAudio
        }
        var samples: [Float] = []
        while let buffer = reader.read(frames: 65_536), buffer.frameLength > 0 {
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                                           count: Int(buffer.frameLength)))
        }
        return samples
    }
}

/// Sequentially decodes any audio file to deinterleaved Float32 mono at a fixed
/// sample rate, converting (resample + downmix) as it reads.
private final class MonoStreamReader {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private var sourceDrained = false
    private var finished = false

    init?(url: URL, sampleRate: Double) {
        guard let file = try? AVAudioFile(forReading: url),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return nil }
        self.file = file
        self.target = target
        self.converter = converter
    }

    /// Next buffer of up to `frames` converted frames; nil once the file is done.
    func read(frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard !finished, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames) else { return nil }
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if self.sourceDrained {
                outStatus.pointee = .endOfStream
                return nil
            }
            guard let input = AVAudioPCMBuffer(pcmFormat: self.file.processingFormat, frameCapacity: 8192) else {
                self.sourceDrained = true
                outStatus.pointee = .endOfStream
                return nil
            }
            do {
                try self.file.read(into: input)
            } catch {
                self.sourceDrained = true
                outStatus.pointee = .endOfStream
                return nil
            }
            if input.frameLength == 0 {
                self.sourceDrained = true
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }
        if status == .error { finished = true; return nil }
        if status == .endOfStream { finished = true }
        return out.frameLength > 0 ? out : nil
    }
}
