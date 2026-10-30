import Foundation
import os

/// Lock-protected mono sample ring. The capture callback only copies into it (no allocation,
/// no analysis), and the lighting engine snapshots the most recent window at frame rate.
public final class SampleRing: @unchecked Sendable {
    private var buffer: [Float]
    private var writeIndex = 0
    private var filled = 0
    private var sumSquares: Double = 0
    private var peak: Float = 0
    private var framesSinceRead = 0
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    public private(set) var sampleRate: Double

    public init(capacity: Int = 8192, sampleRate: Double = 48_000) {
        buffer = [Float](repeating: 0, count: capacity)
        self.sampleRate = sampleRate
    }

    deinit { lock.deinitialize(count: 1); lock.deallocate() }

    public func setSampleRate(_ rate: Double) {
        os_unfair_lock_lock(lock); sampleRate = rate; os_unfair_lock_unlock(lock)
    }

    /// Appends mono samples. Called from the capture callback: copy only, no allocation.
    public func append(mono samples: UnsafePointer<Float>, count: Int) {
        os_unfair_lock_lock(lock)
        let cap = buffer.count
        for i in 0..<count {
            let s = samples[i]
            buffer[writeIndex] = s
            writeIndex = (writeIndex + 1) % cap
            sumSquares += Double(s * s)
            let a = abs(s)
            if a > peak { peak = a }
        }
        filled = min(cap, filled + count)
        framesSinceRead += count
        os_unfair_lock_unlock(lock)
    }

    public func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append(mono: $0.baseAddress!, count: $0.count) }
    }

    public struct Snapshot {
        public var window: [Float]
        /// RMS / peak over everything received since the previous snapshot.
        public var rms: Float
        public var peak: Float
        public var newFrames: Int
        public var sampleRate: Double
    }

    /// Copies the most recent `count` samples (zero-padded at the front if not yet filled).
    public func snapshot(count: Int) -> Snapshot {
        var out = [Float](repeating: 0, count: count)
        os_unfair_lock_lock(lock)
        let cap = buffer.count
        let n = min(count, filled, cap)
        var idx = (writeIndex - n + cap) % cap
        for i in (count - n)..<count {
            out[i] = buffer[idx]
            idx = (idx + 1) % cap
        }
        let frames = framesSinceRead
        let rms = frames > 0 ? Float(sqrt(sumSquares / Double(frames))) : 0
        let pk = peak
        sumSquares = 0; peak = 0; framesSinceRead = 0
        let rate = sampleRate
        os_unfair_lock_unlock(lock)
        return Snapshot(window: out, rms: rms, peak: pk, newFrames: frames, sampleRate: rate)
    }

    public func reset() {
        os_unfair_lock_lock(lock)
        for i in buffer.indices { buffer[i] = 0 }
        writeIndex = 0; filled = 0; sumSquares = 0; peak = 0; framesSinceRead = 0
        os_unfair_lock_unlock(lock)
    }
}
