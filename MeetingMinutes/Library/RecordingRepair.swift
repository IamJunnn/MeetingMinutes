import AudioToolbox
import AVFoundation
import Foundation
import OSLog

/// Rebuilds recordings whose capture was cut off before the files were
/// finalized (shutdown, crash, power loss). An m4a written by AVAudioFile or a
/// non-fragmented AVAssetWriter only gets its index (`moov`) on close; without
/// it every frame of audio is on disk but nothing can open the file.
///
/// Runs at launch. For each unreadable AAC track it recovers the frames and
/// writes them into a fresh m4a without re-encoding. Unreadable lossless
/// sidecars are moved out, since EchoCanceller would otherwise prefer them and
/// fail. Every original is moved to `MeetingMinutes/RecoveryBackup/<folder>/`
/// first, so a repair never destroys anything.
enum RecordingRepair {
    private static let logger = Logger(subsystem: "build.ecoblox.MeetingMinutes", category: "RecordingRepair")

    /// A folder written to more recently than this may still be recording, in
    /// this app or in the other one sharing the Recordings directory. Capture
    /// writes a fragment every couple of seconds, so a live folder is always fresher.
    static let quietPeriod: TimeInterval = 120

    static var recordingsDirectory: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MeetingMinutes/Recordings", isDirectory: true)
    }

    /// Repair in the background, then post `.recordingsRepaired` on the main
    /// queue if anything changed, so lists reload.
    static func repairAllInBackground() {
        Task.detached(priority: .utility) {
            let changed = await repairAll()
            guard !changed.isEmpty else { return }
            await MainActor.run { NotificationCenter.default.post(name: .recordingsRepaired, object: nil) }
        }
    }

    /// Repair every cut-off recording. Returns the folders that changed.
    @discardableResult
    static func repairAll() async -> [URL] {
        guard let base = recordingsDirectory,
              let folders = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var changed: [URL] = []
        for folder in folders.sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
        where (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if repair(folder: folder) { changed.append(folder) }
        }
        return changed
    }

    /// Repair one recording folder in place. True when anything was changed.
    @discardableResult
    static func repair(folder: URL) -> Bool {
        let fm = FileManager.default
        let tracks = ["mic.m4a", "system.m4a"].map { folder.appendingPathComponent($0) }
        let sidecars = ["mic-raw.m4a", "system-raw.m4a"].map { folder.appendingPathComponent($0) }
        let brokenTracks = tracks.filter { fm.fileExists(atPath: $0.path) && !isReadable($0) }
        let brokenSidecars = sidecars.filter { fm.fileExists(atPath: $0.path) && !isReadable($0) }
        guard !brokenTracks.isEmpty || !brokenSidecars.isEmpty else { return false }
        guard !recentlyWritten(folder) else { return false }
        guard let lock = acquireLock(in: folder) else { return false }
        defer { try? fm.removeItem(at: lock) }
        // Another process may have finished the repair while we waited for the lock.
        guard (tracks + sidecars).contains(where: { fm.fileExists(atPath: $0.path) && !isReadable($0) }) else { return false }

        guard let backup = backupFolder(for: folder) else { return false }
        for sidecar in brokenSidecars {
            moveToBackup(sidecar, backup)
            logger.info("\(folder.lastPathComponent, privacy: .public): moved unreadable \(sidecar.lastPathComponent, privacy: .public) to RecoveryBackup")
        }
        for track in brokenTracks {
            let temp = folder.appendingPathComponent("repairing-" + track.lastPathComponent)
            try? fm.removeItem(at: temp)
            let format: AACSalvage.Format? = track.lastPathComponent == "system.m4a"
                ? AACSalvage.Format(sampleRate: 48_000, channels: 2)
                : nil
            let result = AACSalvage.salvage(track, to: temp, format: format, wallClockSeconds: wallClockSeconds(of: track, in: folder))
            moveToBackup(track, backup)
            if let result, isReadable(temp) {
                try? fm.moveItem(at: temp, to: track)
                logger.info("\(folder.lastPathComponent, privacy: .public): recovered \(track.lastPathComponent, privacy: .public), \(Int(result.seconds))s at \(Int(result.format.sampleRate)) Hz")
            } else {
                // Nothing salvageable (a header-only file). Leaving it in place
                // would fail every later step, so the folder keeps the other track.
                try? fm.removeItem(at: temp)
                logger.error("\(folder.lastPathComponent, privacy: .public): \(track.lastPathComponent, privacy: .public) had no recoverable audio; moved to RecoveryBackup")
            }
        }
        // Anything derived from the broken files is stale.
        for derived in ["mic-clean.m4a", "meeting.m4a", "alignment.json"] {
            try? fm.removeItem(at: folder.appendingPathComponent(derived))
        }
        return true
    }

    /// Opens the way the pipeline does (EchoCanceller, AudioDecoder) and has audio.
    static func isReadable(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0
    }

    private static func recentlyWritten(_ folder: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.contains { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return Date().timeIntervalSince(date) < quietPeriod
        }
    }

    /// How long the track was recording: from the folder's timestamp to the
    /// last write. Raw AAC frames don't carry their sample rate; this does.
    private static func wallClockSeconds(of track: URL, in folder: URL) -> Double? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        guard let start = formatter.date(from: folder.lastPathComponent),
              let end = (try? track.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        let seconds = end.timeIntervalSince(start)
        return seconds > 1 ? seconds : nil
    }

    /// Exclusive per-folder lock, so MyIntern and Meeting Minutes launching
    /// together don't repair the same files. A lock older than an hour is a leftover.
    private static func acquireLock(in folder: URL) -> URL? {
        let lock = folder.appendingPathComponent(".repair.lock")
        for _ in 0..<2 {
            let fd = open(lock.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 { close(fd); return lock }
            let age = (try? lock.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate.map { Date().timeIntervalSince($0) } ?? 0
            guard age > 3600 else { return nil }
            try? FileManager.default.removeItem(at: lock)
        }
        return nil
    }

    private static func backupFolder(for folder: URL) -> URL? {
        let backup = folder.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RecoveryBackup", isDirectory: true)
            .appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            return backup
        } catch {
            logger.error("Cannot create backup folder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func moveToBackup(_ file: URL, _ backup: URL) {
        let fm = FileManager.default
        var dest = backup.appendingPathComponent(file.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = backup.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent)-\(n).\(file.pathExtension)")
            n += 1
        }
        try? fm.moveItem(at: file, to: dest)
    }
}

extension Notification.Name {
    /// Posted on the main queue after launch repair rewrote one or more recordings.
    static let recordingsRepaired = Notification.Name("RecordingRepair.recordingsRepaired")
}

/// Recovers raw AAC-LC frames from an m4a that never got its index and writes
/// them, untouched, into a new m4a.
///
/// Raw AAC frames have no length prefix, so each frame's length is found by
/// asking the decoder: a frame cut even one byte short decodes to nothing, the
/// full frame (or more) decodes to 1024 samples. The shortest accepted slice is
/// the frame. Eight frames must chain before a position counts as in sync.
enum AACSalvage {
    struct Format: Equatable {
        let sampleRate: Double
        let channels: UInt32
    }

    struct Result {
        let format: Format
        let packets: Int
        var seconds: Double { Double(packets) * 1024 / format.sampleRate }
    }

    /// How far past the header the first frame may start. A hard shutdown can
    /// zero the header area (60 KB for AVAudioFile); real audio is well inside this.
    static let firstSyncWindow = 256 * 1024

    /// Rates the mic may have been captured at (AVAudioEngine's input format).
    static let candidateRates: [Double] = [48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 8_000]

    static func salvage(_ source: URL, to destination: URL, format known: Format?, wallClockSeconds: Double?) -> Result? {
        guard let data = try? Data(contentsOf: source, options: .alwaysMapped) else { return nil }
        let start = payloadStart(data)

        // Frame parsing doesn't depend on the sample rate, only on the channel count.
        var best: (channels: UInt32, packets: [(offset: Int, length: Int)])?
        for channels in known.map({ [$0.channels] }) ?? [1, 2] {
            guard let packets = scan(data, from: start, channels: channels), !packets.isEmpty else { continue }
            if packets.count > (best?.packets.count ?? 0) { best = (channels, packets) }
        }
        guard let best, best.packets.count > 8 else { return nil }

        let rate: Double
        if let known {
            rate = known.sampleRate
        } else if let wall = wallClockSeconds {
            let frames = Double(best.packets.count) * 1024
            rate = candidateRates.min { abs(frames / $0 - wall) < abs(frames / $1 - wall) } ?? 48_000
        } else {
            rate = 48_000
        }
        let format = Format(sampleRate: rate, channels: best.channels)
        guard write(best.packets, from: data, format: format, to: destination) else { return nil }
        return Result(format: format, packets: best.packets.count)
    }

    /// Where the audio frames begin: after the `mdat` header when one survived,
    /// otherwise right after `ftyp` (a hard shutdown can zero the header area,
    /// the scan skips that).
    private static func payloadStart(_ data: Data) -> Int {
        var offset = 0
        while offset + 8 <= data.count {
            let size = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
            if type == "mdat" { return offset + 8 }
            guard ["ftyp", "wide", "free", "skip"].contains(type), size >= 8 else { break }
            offset += size
        }
        return offset
    }

    private static func scan(_ data: Data, from start: Int, channels: UInt32) -> [(offset: Int, length: Int)]? {
        guard let probe = FrameProbe(channels: channels) else { return nil }
        var packets: [(offset: Int, length: Int)] = []
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = start
            let end = bytes.count
            while offset < end {
                // In sync when eight frames chain from here (or the file ends first).
                var cursor = offset
                var chained = 0
                while chained < 8, let length = probe.frameLength(bytes, at: cursor) {
                    cursor += length
                    chained += 1
                }
                if chained < 8 && cursor < end - FrameProbe.maxFrame {
                    // Wrong channel count never syncs; give up on it early
                    // instead of probing every byte of the file.
                    if packets.isEmpty && offset - start > Self.firstSyncWindow { return nil }
                    offset += 1
                    continue
                }
                if chained == 0 { break }
                while let length = probe.frameLength(bytes, at: offset) {
                    packets.append((offset, length))
                    offset += length
                }
            }
            return packets
        }
    }

    private static func aacDescription(_ format: Format) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: format.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
                                    mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue), mBytesPerPacket: 0,
                                    mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: format.channels,
                                    mBitsPerChannel: 0, mReserved: 0)
    }

    private static func pcmDescription(_ format: Format) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                    mBytesPerPacket: 4 * format.channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * format.channels,
                                    mChannelsPerFrame: format.channels, mBitsPerChannel: 32, mReserved: 0)
    }

    /// The AAC decoder config the m4a needs, taken from an encoder set up with
    /// the same rate and channel count as the original.
    private static func magicCookie(_ format: Format) -> Data? {
        var pcm = pcmDescription(format)
        var aac = aacDescription(format)
        var encoder: AudioConverterRef?
        guard AudioConverterNew(&pcm, &aac, &encoder) == noErr, let encoder else { return nil }
        defer { AudioConverterDispose(encoder) }
        var size: UInt32 = 0
        guard AudioConverterGetPropertyInfo(encoder, kAudioConverterCompressionMagicCookie, &size, nil) == noErr, size > 0 else { return nil }
        var cookie = Data(count: Int(size))
        let status = cookie.withUnsafeMutableBytes { AudioConverterGetProperty(encoder, kAudioConverterCompressionMagicCookie, &size, $0.baseAddress!) }
        return status == noErr ? cookie.prefix(Int(size)) : nil
    }

    private static func write(_ packets: [(offset: Int, length: Int)], from data: Data, format: Format, to url: URL) -> Bool {
        var description = aacDescription(format)
        var file: AudioFileID?
        guard AudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &description, .eraseFile, &file) == noErr, let file else { return false }
        defer { AudioFileClose(file) }
        if let cookie = magicCookie(format) {
            _ = cookie.withUnsafeBytes { AudioFileSetProperty(file, kAudioFilePropertyMagicCookieData, UInt32(cookie.count), $0.baseAddress!) }
        }
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            var index = 0
            let batch = 512
            var buffer = Data()
            var descriptions: [AudioStreamPacketDescription] = []
            while index < packets.count {
                buffer.removeAll(keepingCapacity: true)
                descriptions.removeAll(keepingCapacity: true)
                for packet in packets[index..<min(index + batch, packets.count)] {
                    descriptions.append(AudioStreamPacketDescription(mStartOffset: Int64(buffer.count), mVariableFramesInPacket: 0,
                                                                     mDataByteSize: UInt32(packet.length)))
                    buffer.append(bytes.baseAddress!.advanced(by: packet.offset).assumingMemoryBound(to: UInt8.self), count: packet.length)
                }
                var count = UInt32(descriptions.count)
                let status = buffer.withUnsafeBytes {
                    AudioFileWritePackets(file, false, UInt32($0.count), descriptions, Int64(index), &count, $0.baseAddress!)
                }
                guard status == noErr, count == UInt32(descriptions.count) else { return false }
                index += descriptions.count
            }
            return true
        }
    }
}

/// Decodes single AAC frames to measure where each one ends.
private final class FrameProbe {
    /// Room for the largest frame any channel count here can produce.
    static let maxFrame = 2048

    private var converter: AudioConverterRef
    private let input = UnsafeMutableRawPointer.allocate(byteCount: FrameProbe.maxFrame, alignment: 16)
    private let packet = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    private let output: UnsafeMutableRawPointer
    private let channels: UInt32
    /// The decoder rejects (paramErr) any packet longer than this, 768 bytes
    /// per channel for AAC, so a probe slice must never exceed it.
    private let maxPacket: Int
    private var length = 0
    private var consumed = false

    init?(channels: UInt32) {
        var aac = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC,
                                              mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue), mBytesPerPacket: 0,
                                              mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: channels,
                                              mBitsPerChannel: 0, mReserved: 0)
        var pcm = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
                                              mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var converter: AudioConverterRef?
        guard AudioConverterNew(&aac, &pcm, &converter) == noErr, let converter else { return nil }
        self.converter = converter
        self.channels = channels
        var maxPacket: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumInputPacketSize, &size, &maxPacket) != noErr || maxPacket == 0 {
            maxPacket = 768 * channels
        }
        self.maxPacket = min(Int(maxPacket), Self.maxFrame)
        self.output = .allocate(byteCount: 1024 * 4 * Int(channels), alignment: 16)
    }

    deinit {
        AudioConverterDispose(converter)
        input.deallocate()
        packet.deallocate()
        output.deallocate()
    }

    /// Length of the frame starting at `offset`, nil when no frame starts there.
    func frameLength(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Int? {
        var high = min(maxPacket, bytes.count - offset)
        guard high >= 4, accepts(bytes, offset, high) else { return nil }
        var low = 0   // rejected
        while high - low > 1 {
            let mid = (low + high) / 2
            if accepts(bytes, offset, mid) { high = mid } else { low = mid }
        }
        return high
    }

    private func accepts(_ bytes: UnsafeRawBufferPointer, _ offset: Int, _ count: Int) -> Bool {
        AudioConverterReset(converter)
        memcpy(input, bytes.baseAddress! + offset, count)
        length = count
        consumed = false
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels,
                                                                           mDataByteSize: 1024 * 4 * channels, mData: output))
        var frames: UInt32 = 1024
        _ = AudioConverterFillComplexBuffer(converter, { _, ioPackets, ioData, outDescription, context in
            let probe = Unmanaged<FrameProbe>.fromOpaque(context!).takeUnretainedValue()
            guard !probe.consumed else { ioPackets.pointee = 0; return 1 }
            probe.consumed = true
            ioPackets.pointee = 1
            ioData.pointee.mBuffers.mData = probe.input
            ioData.pointee.mBuffers.mDataByteSize = UInt32(probe.length)
            ioData.pointee.mBuffers.mNumberChannels = probe.channels
            probe.packet.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(probe.length))
            outDescription?.pointee = probe.packet
            return 0
        }, Unmanaged.passUnretained(self).toOpaque(), &frames, &list, nil)
        return frames == 1024
    }
}
