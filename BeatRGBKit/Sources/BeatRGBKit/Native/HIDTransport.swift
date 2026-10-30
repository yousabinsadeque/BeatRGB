import Foundation
import IOKit.hid

/// Minimal request/response channel to one HID interface (what hidapi's hid_write/hid_read give OpenRGB).
public protocol HIDTransport: AnyObject {
    var serialNumber: String { get }
    func write(_ report: [UInt8]) throws
    /// Next input report, or nil after `timeout`.
    func read(timeout: TimeInterval) -> [UInt8]?
    /// Discards queued input reports.
    func drain()
    func close()
}

public enum NativeHIDError: Error, Equatable, CustomStringConvertible {
    case notFound
    case openFailed(Int32)
    case writeFailed(Int32)
    case unexpectedDevice(UInt32)
    case otherSoftwareRunning(String)

    public var description: String {
        switch self {
        case .notFound: return "K70 CORE RGB TKL lighting interface (USB 1B1C:2B01, usage page 0xFF42) not found. Is the keyboard plugged in?"
        case .openFailed(let r): return String(format: "Could not open the keyboard's lighting interface (IOReturn 0x%08X).", UInt32(bitPattern: r))
        case .writeFailed(let r): return String(format: "USB write to the keyboard failed (IOReturn 0x%08X).", UInt32(bitPattern: r))
        case .unexpectedDevice(let pid): return String(format: "The keyboard reported product ID 0x%04X, not 0x2B01; refusing to drive it.", pid)
        case .otherSoftwareRunning(let app): return "\(app) is running and also controls the keyboard. Quit it before using the native backend."
        }
    }
}

/// IOKit implementation: opens (non-exclusively) the vendor command interface and delivers
/// input reports through a dispatch queue.
public final class IOKitHIDTransport: HIDTransport {
    private let device: IOHIDDevice
    private let queue = DispatchQueue(label: "BeatRGB.hid.input")
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
    private let lock = NSCondition()
    private var pending: [[UInt8]] = []
    private var closed = false
    private let cancelled = DispatchSemaphore(value: 0)
    public let serialNumber: String

    public static func open(vendorID: Int = CorsairV2Protocol.vendorID,
                            productID: Int = CorsairV2Protocol.k70CoreTKLProductID) throws -> IOKitHIDTransport {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: vendorID,
            kIOHIDProductIDKey: productID,
            kIOHIDPrimaryUsagePageKey: CorsairV2Protocol.usagePage,
            kIOHIDPrimaryUsageKey: CorsairV2Protocol.commandUsage,
        ] as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = set.first(where: { maxOutput($0) >= CorsairV2Protocol.reportSize }) ?? set.first else {
            throw NativeHIDError.notFound
        }
        return try IOKitHIDTransport(device: device)
    }

    private static func maxOutput(_ d: IOHIDDevice) -> Int {
        (IOHIDDeviceGetProperty(d, kIOHIDMaxOutputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 0
    }

    init(device: IOHIDDevice) throws {
        self.device = device
        serialNumber = (IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String) ?? ""
        let rc = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard rc == kIOReturnSuccess else { buffer.deallocate(); throw NativeHIDError.openFailed(rc) }
        IOHIDDeviceSetDispatchQueue(device, queue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 1024, { ctx, result, _, _, _, report, length in
            guard let ctx, result == kIOReturnSuccess else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            Unmanaged<IOKitHIDTransport>.fromOpaque(ctx).takeUnretainedValue().enqueue(bytes)
        }, ctx)
        let done = cancelled
        IOHIDDeviceSetCancelHandler(device) { done.signal() }
        IOHIDDeviceActivate(device)
    }

    deinit {
        close()
        buffer.deallocate()
    }

    private func enqueue(_ bytes: [UInt8]) {
        lock.lock()
        pending.append(bytes)
        if pending.count > 64 { pending.removeFirst(pending.count - 64) }
        lock.signal()
        lock.unlock()
    }

    public func write(_ report: [UInt8]) throws {
        let rc = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
        }
        guard rc == kIOReturnSuccess else { throw NativeHIDError.writeFailed(rc) }
    }

    public func read(timeout: TimeInterval) -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        defer { lock.unlock() }
        while pending.isEmpty {
            if !lock.wait(until: deadline) { return nil }
        }
        return pending.removeFirst()
    }

    public func drain() {
        lock.lock(); pending.removeAll(); lock.unlock()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        // Cancel completes asynchronously on the queue; wait so no callback outlives `buffer`.
        IOHIDDeviceCancel(device)
        _ = cancelled.wait(timeout: .now() + 1)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}
