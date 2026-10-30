import Foundation

/// One-pole attack/release follower with time constants in seconds.
public struct Envelope: Sendable {
    public var attack: Double
    public var release: Double
    public private(set) var value: Float = 0

    public init(attack: Double, release: Double, value: Float = 0) {
        self.attack = attack; self.release = release; self.value = value
    }

    @discardableResult
    public mutating func process(_ target: Float, dt: Double) -> Float {
        let tau = target > value ? attack : release
        let k = tau <= 0 ? 1 : Float(1 - exp(-dt / tau))
        value += (target - value) * k
        return value
    }

    public mutating func reset(_ v: Float = 0) { value = v }
}

/// Slow peak tracker in dB used for adaptive gain: rises instantly, decays at `decayDBPerSecond`,
/// and never drops below `floorDB` so silence isn't amplified into noise.
public struct AdaptiveGain: Sendable {
    public var decayDBPerSecond: Float
    public var floorDB: Float
    public private(set) var referenceDB: Float

    public init(decayDBPerSecond: Float = 4, floorDB: Float = -50, initialDB: Float = -20) {
        self.decayDBPerSecond = decayDBPerSecond; self.floorDB = floorDB; self.referenceDB = initialDB
    }

    public mutating func update(_ db: Float, dt: Double) -> Float {
        referenceDB = max(db, referenceDB - decayDBPerSecond * Float(dt), floorDB)
        return referenceDB
    }

    /// Maps a level in dB into 0…1 relative to the reference over `rangeDB`.
    public func normalize(_ db: Float, rangeDB: Float) -> Float {
        min(1, max(0, (db - (referenceDB - rangeDB)) / rangeDB))
    }
}

@inline(__always) public func linearToDB(_ x: Float) -> Float { 20 * log10(max(x, 1e-9)) }
