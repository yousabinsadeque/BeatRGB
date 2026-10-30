import AVFoundation
import CoreAudio
import Foundation

public enum CaptureSource: Codable, Equatable, Hashable, Sendable {
    /// Core Audio process tap of everything the Mac plays (excluding BeatRGB itself).
    case systemAudio
    /// An input device chosen explicitly by the user, e.g. a BlackHole loopback. Never chosen automatically.
    case inputDevice(uid: String, name: String)

    public var displayName: String {
        switch self {
        case .systemAudio: return "System audio (Core Audio tap)"
        case .inputDevice(_, let name): return "Input device: \(name)"
        }
    }
}

public enum CaptureState: Equatable, Sendable {
    case stopped
    case starting
    case running(format: String)
    case failed(String)
}

public protocol AudioCapture: AnyObject {
    var ring: SampleRing { get }
    var onStateChange: ((CaptureState) -> Void)? { get set }
    func start() throws
    func stop()
}

struct CoreAudioError: Error, CustomStringConvertible {
    let stage: String
    let status: OSStatus
    var description: String {
        let fourCC = withUnsafeBytes(of: status.bigEndian) { b in
            b.allSatisfy { (0x20...0x7E).contains($0) } ? " '\(String(decoding: b, as: UTF8.self))'" : ""
        }
        return "\(stage) failed (OSStatus \(status)\(fourCC))"
    }
}

@inline(__always) func check(_ status: OSStatus, _ stage: String) throws {
    if status != noErr { throw CoreAudioError(stage: stage, status: status) }
}

// MARK: - System audio via process tap

/// Captures the Mac's mixed output with `AudioHardwareCreateProcessTap` (macOS 14.2+).
/// Audio keeps playing normally (`muteBehavior = .unmuted`); samples are only analysed in memory.
/// The first start triggers macOS's "System Audio Recording" consent prompt
/// (Privacy & Security → Screen & System Audio Recording → System Audio Recording Only).
public final class SystemAudioCapture: AudioCapture {
    public let ring = SampleRing()
    public var onStateChange: ((CaptureState) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "BeatRGB.audio.io", qos: .userInteractive)
    private var mono = [Float](repeating: 0, count: 16_384)
    private var outputListener: AudioObjectPropertyListenerBlock?

    public init() {}
    deinit { stop() }

    public func start() throws {
        stop()
        onStateChange?(.starting)
        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
            description.name = "BeatRGB System Audio"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the system audio tap")

            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "Reading tap format")
            ring.setSampleRate(format.mSampleRate)

            // Tap-only private aggregate: no physical sub-device, so no microphone can leak in.
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "BeatRGB Tap",
                kAudioAggregateDeviceUIDKey: "com.beatrgb.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID), "Creating the capture device")
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, input, _, _, _ in
                self?.consume(input)
            }, "Installing the capture callback")
            try check(AudioDeviceStart(aggregateID, procID), "Starting capture")
            installOutputListener()
            let fmt = String(format: "%.0f Hz, %d ch", format.mSampleRate, format.mChannelsPerFrame)
            onStateChange?(.running(format: fmt))
        } catch {
            stop()
            onStateChange?(.failed("\(error)"))
            throw error
        }
    }

    public func stop() {
        removeOutputListener()
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        ring.reset()
        onStateChange?(.stopped)
    }

    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mData != nil else { return }
        let channelsInFirst = max(1, Int(first.mNumberChannels))
        let frames = min(mono.count, Int(first.mDataByteSize) / (4 * channelsInFirst))
        guard frames > 0 else { return }
        let totalChannels = buffers.reduce(0) { $0 + max(1, Int($1.mNumberChannels)) }
        let scale = 1 / Float(totalChannels)
        mono.withUnsafeMutableBufferPointer { out in
            for i in 0..<frames { out[i] = 0 }
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let ch = max(1, Int(buffer.mNumberChannels))
                for i in 0..<frames {
                    var s: Float = 0
                    for c in 0..<ch { s += data[i * ch + c] }
                    out[i] += s * scale
                }
            }
            ring.append(mono: out.baseAddress!, count: frames)
        }
    }

    /// The global tap follows whatever device is playing, but its format can change with the
    /// default output device (e.g. headphones at 44.1 kHz), so rebuild the tap when that happens.
    private func installOutputListener() {
        var address = Self.defaultOutputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { try? self?.start() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            outputListener = block
        }
    }

    private func removeOutputListener() {
        guard let block = outputListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        outputListener = nil
    }

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    /// BeatRGB's own Core Audio process object, so its own sounds never feed back into the lights.
    static func ownProcessObject() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

// MARK: - Explicit input device (loopback fallback)

/// Captures from an input device the user picked (intended for loopback drivers such as BlackHole).
/// Requires Microphone permission because macOS treats every input device that way.
public final class InputDeviceCapture: AudioCapture {
    public let ring = SampleRing()
    public var onStateChange: ((CaptureState) -> Void)?
    private let uid: String
    private var engine: AVAudioEngine?

    public init(uid: String) { self.uid = uid }
    deinit { stop() }

    public func start() throws {
        stop()
        onStateChange?(.starting)
        guard let deviceID = AudioDevices.deviceID(forUID: uid) else {
            let msg = "Input device is not connected."
            onStateChange?(.failed(msg))
            throw CoreAudioError(stage: msg, status: kAudioHardwareBadDeviceError)
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        do {
            var dev = deviceID
            try check(AudioUnitSetProperty(input.audioUnit!, kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)),
                      "Selecting input device")
            let format = input.outputFormat(forBus: 0)
            ring.setSampleRate(format.sampleRate)
            var scratch = [Float](repeating: 0, count: 16_384)
            let ring = self.ring
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                guard let ch = buffer.floatChannelData else { return }
                let frames = min(Int(buffer.frameLength), scratch.count)
                let channels = Int(buffer.format.channelCount)
                let scale = 1 / Float(max(1, channels))
                for i in 0..<frames {
                    var s: Float = 0
                    for c in 0..<channels { s += ch[c][i] }
                    scratch[i] = s * scale
                }
                scratch.withUnsafeBufferPointer { ring.append(mono: $0.baseAddress!, count: frames) }
            }
            try engine.start()
            self.engine = engine
            onStateChange?(.running(format: String(format: "%.0f Hz, %d ch", format.sampleRate, format.channelCount)))
        } catch {
            input.removeTap(onBus: 0)
            onStateChange?(.failed("\(error)"))
            throw error
        }
    }

    public func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        ring.reset()
        onStateChange?(.stopped)
    }
}

// MARK: - Device helpers

public struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
    public var id: String { uid }
    public var uid: String
    public var name: String
    public var isLikelyLoopback: Bool {
        let n = name.lowercased()
        return ["blackhole", "loopback", "soundflower", "background music"].contains { n.contains($0) }
    }
}

public enum AudioDevices {
    public static func inputDevices() -> [AudioDeviceInfo] {
        allDeviceIDs().compactMap { id in
            guard channelCount(id, scope: kAudioDevicePropertyScopeInput) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName),
                  !uid.hasPrefix("com.beatrgb.") else { return nil }
            return AudioDeviceInfo(uid: uid, name: name)
        }
    }

    public static func defaultOutputName() -> String? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return string(id, kAudioObjectPropertyName)
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let s = value else { return nil }
        return s.takeRetainedValue() as String
    }

    static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
