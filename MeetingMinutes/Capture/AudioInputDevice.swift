import CoreAudio
import Foundation

/// Which microphone this Mac is allowed to open.
///
/// A Mac Studio has no microphone of its own. When something asks for audio input and no local device is there,
/// macOS reaches for the owner's iPhone over Continuity, and the phone lights up mid-call asking to connect
/// (Jun, 2026-10-10: "when I hit prompter my iphone is try to connect"). The Prompter must never do that: it takes
/// the microphone attached to this Mac, the Bluetooth headset being used in the call, and nothing else.
///
/// So the choice is made here rather than left to the system default, and a Continuity device is never chosen.
/// With no microphone at all the caller runs on the call's own audio, which is the side that matters anyway.
enum AudioInputDevice {
    /// Transports that mean a microphone physically attached to this Mac. Everything else, Continuity above all but
    /// also virtual loopback drivers like the meeting apps' own, is left alone: a loopback device would feed the
    /// meeting's audio back in as if the owner had said it.
    private static let local: Set<UInt32> = [
        kAudioDeviceTransportTypeBuiltIn,
        kAudioDeviceTransportTypeUSB,
        kAudioDeviceTransportTypeBluetooth,
        kAudioDeviceTransportTypeBluetoothLE,
        kAudioDeviceTransportTypeThunderbolt,
        kAudioDeviceTransportTypeFireWire,
        kAudioDeviceTransportTypePCI,
    ]

    /// The microphone to record from, or nil when this Mac has none worth opening.
    ///
    /// The system default first: that is whatever the owner picked, and a headset becomes it as it connects. If the
    /// default is missing (no input device at all) or is the iPhone, any real local microphone is taken instead.
    static func chosen() -> AudioDeviceID? {
        if let id = systemDefault(), accepts(id) { return id }
        return all().first(where: accepts)
    }

    /// The name of the chosen device, for the log. "none" when there is nothing to open.
    static func describe(_ id: AudioDeviceID?) -> String {
        guard let id else { return "none" }
        return name(id) ?? "device \(id)"
    }

    /// Whether this is the device the system would have handed over anyway.
    static func isSystemDefault(_ id: AudioDeviceID) -> Bool { systemDefault() == id }

    private static func accepts(_ id: AudioDeviceID) -> Bool {
        inputChannels(id) > 0 && local.contains(transport(id))
    }

    private static func systemDefault() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func all() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func name(_ id: AudioDeviceID) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFTypeRef?>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
