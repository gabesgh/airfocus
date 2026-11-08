import CoreAudio
import Foundation

/// Default output device and AirPods presence. AirPods only stream head motion while they are the
/// *current* audio output (R§1.7), so the menu shows this to diagnose "0 Hz".
struct AudioDevice: Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Heuristic: head-tracking headphones announce themselves by name (user renames usually keep it).
    var looksLikeHeadTrackingHeadphones: Bool {
        isBluetooth && (name.localizedCaseInsensitiveContains("AirPods") || name.localizedCaseInsensitiveContains("Beats"))
    }

    var transportName: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        default: return String(format: "0x%08x", transport)
        }
    }
}

enum AudioRoute {
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func device(_ id: AudioDeviceID) -> AudioDevice {
        var nameAddr = address(kAudioObjectPropertyName)
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let nameStatus = AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &size, &cfName)
        let name = nameStatus == noErr ? (cfName?.takeRetainedValue() as String?) ?? "Unknown" : "Unknown"

        var tAddr = address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &tAddr, 0, nil, &size, &transport)
        return AudioDevice(id: id, name: name, transport: transport)
    }

    static func defaultOutput() -> AudioDevice? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != 0 else { return nil }
        return device(dev)
    }

    /// All devices with at least one output stream.
    static func outputDevices() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasOutput).map(device)
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    /// Connected AirPods/Beats that could stream head motion (whether or not they are the output).
    static func headphoneCandidates() -> [AudioDevice] {
        outputDevices().filter(\.looksLikeHeadTrackingHeadphones)
    }
}

/// Notifies (on main) when the default output or the device list changes.
final class AudioRouteMonitor {
    var onChange: (() -> Void)?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block) == noErr {
                listeners.append((addr, block))
            }
        }
    }

    deinit {
        for (addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, block)
        }
    }
}
