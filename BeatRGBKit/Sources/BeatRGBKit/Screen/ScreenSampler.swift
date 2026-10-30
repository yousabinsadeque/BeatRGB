import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os
import ScreenCaptureKit

/// Streams a tiny, downscaled copy of a display with ScreenCaptureKit and keeps the latest frame as a
/// coarse colour grid for the Screen Mirror effect. Nothing is recorded or stored.
/// Requires Screen Recording permission (Privacy & Security → Screen & System Audio Recording).
public final class ScreenSampler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public static let gridWidth = 34
    public static let gridHeight = 12
    private static let captureWidth = 136
    private static let captureHeight = 72

    public enum State: Equatable, Sendable {
        case stopped, starting, running(String), permissionDenied, failed(String)
    }

    public var onStateChange: (@Sendable (State) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "BeatRGB.screen", qos: .userInteractive)
    private let latestGrid = OSAllocatedUnfairLock<ScreenGrid?>(initialState: nil)

    public override init() {}

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    /// Shows the system prompt the first time; afterwards the user must enable it in System Settings.
    @discardableResult public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    public var latest: ScreenGrid? { latestGrid.withLock { $0 } }

    public func start(displayIndex: Int) async {
        await stop()
        onStateChange?(.starting)
        guard Self.hasPermission else {
            Self.requestPermission()
            onStateChange?(.permissionDenied)
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !content.displays.isEmpty else { throw SCStreamError(.noDisplayList) }
            let display = content.displays[min(max(0, displayIndex), content.displays.count - 1)]
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Self.captureWidth
            config.height = Self.captureHeight
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.queueDepth = 3
            config.capturesAudio = false
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
            onStateChange?(.running("Display \(display.displayID) (\(display.width)×\(display.height))"))
        } catch {
            onStateChange?(.failed(error.localizedDescription))
        }
    }

    public func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        latestGrid.withLock { $0 = nil }
        onStateChange?(.stopped)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStateChange?(.failed(error.localizedDescription))
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let grid = Self.downsample(pixelBuffer)
        latestGrid.withLock { $0 = grid }
    }

    /// Box-averages a BGRA pixel buffer into a gridWidth × gridHeight colour grid.
    static func downsample(_ pb: CVPixelBuffer) -> ScreenGrid? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        return downsampleBGRA(ptr, width: w, height: h, bytesPerRow: stride)
    }

    public static func downsampleBGRA(_ ptr: UnsafePointer<UInt8>, width w: Int, height h: Int, bytesPerRow: Int,
                                      gridWidth gw: Int = gridWidth, gridHeight gh: Int = gridHeight) -> ScreenGrid {
        var pixels = [RGBF](repeating: .black, count: gw * gh)
        for gy in 0..<gh {
            let y0 = gy * h / gh, y1 = max(y0 + 1, (gy + 1) * h / gh)
            for gx in 0..<gw {
                let x0 = gx * w / gw, x1 = max(x0 + 1, (gx + 1) * w / gw)
                var r = 0, g = 0, b = 0
                for y in y0..<y1 {
                    let row = ptr + y * bytesPerRow
                    for x in x0..<x1 {
                        let p = row + x * 4
                        b += Int(p[0]); g += Int(p[1]); r += Int(p[2])
                    }
                }
                let n = Float((y1 - y0) * (x1 - x0)) * 255
                pixels[gy * gw + gx] = RGBF(Float(r) / n, Float(g) / n, Float(b) / n)
            }
        }
        return ScreenGrid(width: gw, height: gh, pixels: pixels)
    }
}
