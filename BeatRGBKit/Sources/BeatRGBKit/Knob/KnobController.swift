import AudioToolbox
import CoreAudio
import Foundation
import IOKit.hid

public enum KnobEvent: Equatable, Sendable {
    case rotate(Int)   // positive = clockwise
    case press
}

/// Decodes Corsair K70 CORE RGB TKL dial reports, which arrive on the 0xFF42 usage 2 interface once the
/// software-mode key table is written: `00 05 60 00` + signed little-endian Int32 delta (+1 clockwise,
/// -1 anticlockwise; confirmed on this keyboard). Key reports (`00 02 …`) are ignored: the press bit is
/// not identified yet and guessing could turn a keystroke into a mute toggle.
public struct KnobDecoder: Sendable {
    public init() {}

    public mutating func decode(_ bytes: [UInt8]) -> KnobEvent? {
        guard bytes.count >= 8, bytes[1] == 0x05, bytes[2] == 0x60 else { return nil }
        let raw = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        let delta = Int(Int32(bitPattern: raw))
        return delta == 0 ? nil : .rotate(delta)
    }
}

/// Listens to the keyboard's vendor HID interface (read-only, non-exclusive) and maps the dial to
/// system volume via Core Audio. No keyboard/media events are synthesised.
public final class KnobController {
    public enum State: Equatable, Sendable { case off, waiting, listening(String), failed(String) }

    public var onState: ((State) -> Void)?
    public var onEvent: ((KnobEvent, String) -> Void)?
    public var step: Float = 0.03
    public private(set) var recentReports: [String] = []

    private var manager: IOHIDManager?
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private var decoder = KnobDecoder()
    private let vendorID = 0x1B1C
    private let productID = 0x2B01

    public init() {}
    deinit { stop() }

    public func start() {
        stop()
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<KnobController>.fromOpaque(ctx).takeUnretainedValue().attach(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // Opening the manager can fail without Input Monitoring; individual vendor interfaces may still open.
        _ = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        onState?(.waiting)
    }

    public func stop() {
        if let m = manager {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        buffers.forEach { $0.deallocate() }
        buffers.removeAll()
        onState?(.off)
    }

    private func attach(_ device: IOHIDDevice) {
        let page = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
        guard page >= 0xFF00 else { return }
        let rc = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard rc == kIOReturnSuccess else {
            onState?(.failed(String(format: "Could not open vendor interface 0x%04X (IOReturn 0x%08X). Grant Input Monitoring in System Settings.", page, UInt32(bitPattern: rc))))
            return
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        buffers.append(buffer)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 1024, { ctx, _, _, _, _, report, length in
            guard let ctx else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            Unmanaged<KnobController>.fromOpaque(ctx).takeUnretainedValue().handle(bytes)
        }, ctx)
        onState?(.listening(String(format: "Corsair vendor page 0x%04X", page)))
    }

    private func handle(_ bytes: [UInt8]) {
        recentReports.append(bytes.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " "))
        if recentReports.count > 30 { recentReports.removeFirst() }
        guard let event = decoder.decode(bytes) else { return }
        let result: String
        switch event {
        case .rotate(let d): result = SystemVolume.adjust(by: d > 0 ? step : -step)
        case .press: result = SystemVolume.toggleMute()
        }
        onEvent?(event, result)
    }
}

/// Default-output volume through Core Audio's public properties.
public enum SystemVolume {
    private static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr ? id : nil
    }

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    public static func volume() -> Float? {
        guard let dev = defaultOutput() else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &volumeAddress, 0, nil, &size, &v) == noErr ? v : nil
    }

    @discardableResult
    public static func adjust(by delta: Float) -> String {
        guard let dev = defaultOutput(), var v = volume() else { return "This output has no adjustable volume" }
        v = min(1, max(0, v + delta))
        let status = AudioObjectSetPropertyData(dev, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        return status == noErr ? String(format: "Volume %.0f%%", v * 100) : "Volume change refused (\(status))"
    }

    @discardableResult
    public static func toggleMute() -> String {
        guard let dev = defaultOutput() else { return "No output device" }
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                           mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &muted) == noErr else { return "This output cannot be muted" }
        muted = muted == 0 ? 1 : 0
        let status = AudioObjectSetPropertyData(dev, &a, 0, nil, size, &muted)
        return status == noErr ? (muted == 1 ? "Muted" : "Unmuted") : "Mute refused (\(status))"
    }
}
