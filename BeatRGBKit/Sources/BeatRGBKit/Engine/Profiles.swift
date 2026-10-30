import Foundation

public struct LightingProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var settings: LightingSettings

    public init(id: UUID = UUID(), name: String, settings: LightingSettings) {
        self.id = id; self.name = name; self.settings = settings
    }
}

public struct ProfileLibrary: Codable, Equatable, Sendable {
    public var profiles: [LightingProfile]
    public var activeID: UUID?

    public init(profiles: [LightingProfile], activeID: UUID?) {
        self.profiles = profiles; self.activeID = activeID
    }

    public var active: LightingProfile? { profiles.first { $0.id == activeID } ?? profiles.first }

    public static var builtIn: ProfileLibrary {
        func make(_ name: String, _ edit: (inout LightingSettings) -> Void) -> LightingProfile {
            var s = LightingSettings(); edit(&s); return LightingProfile(name: name, settings: s)
        }
        let profiles = [
            make("Rainbow Spectrum") { $0.effect = .spectrum; $0.spectrumStyle = .multicolor },
            make("Bass Party") {
                $0.effect = .bassPulse; $0.primaryColor = ColorValue(hex: 0xFF0040); $0.bassResponse = 1.3
                $0.pulseAttackMs = 15; $0.pulseDecayMs = 220; $0.baseline = 0.05; $0.brightness = 1
            },
            make("Relaxed Ambient") {
                $0.effect = .rainbowWave; $0.speed = 0.4; $0.smoothing = 0.8; $0.brightness = 0.55
                $0.idle = .breathing; $0.idleColor = ColorValue(hex: 0x3C6CFF)
            },
            make("Gaming") {
                $0.effect = .ripple; $0.primaryColor = ColorValue(hex: 0x00FFA0); $0.speed = 1.4
                $0.idle = .staticColor; $0.idleColor = ColorValue(hex: 0x00C080)
            },
            make("Work Mode") {
                $0.effect = .fullReact; $0.brightness = 0.35; $0.smoothing = 0.85; $0.sensitivity = 0.6
                $0.idle = .staticColor; $0.idleColor = ColorValue(hex: 0xFFE6C8)
            },
            make("Club Strobe") { $0.effect = .beatStrobe; $0.speed = 1.2; $0.idle = .rainbow },
            make("Campfire") {
                $0.effect = .fire; $0.bassResponse = 1.2; $0.idle = .breathing; $0.idleColor = ColorValue(hex: 0xFF5A00)
            },
            make("Starlight") {
                $0.effect = .sparkle; $0.primaryColor = ColorValue(hex: 0x7FA8FF); $0.idle = .breathing
                $0.idleColor = ColorValue(hex: 0x203060)
            },
            make("Centre EQ") {
                $0.effect = .mirrorSpectrum; $0.primaryColor = ColorValue(hex: 0x00E5FF)
                $0.secondaryColor = ColorValue(hex: 0xFF00C8)
            },
            make("Screen Mirror") { $0.effect = .screenMirror; $0.brightness = 1; $0.smoothing = 0.5 },
        ]
        return ProfileLibrary(profiles: profiles, activeID: profiles[0].id)
    }
}

/// Stores profiles as JSON in ~/Library/Application Support/BeatRGB/profiles.json.
public final class ProfileStore {
    public let url: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeatRGB", isDirectory: true)
        url = dir.appendingPathComponent("profiles.json")
    }

    public func load() -> ProfileLibrary {
        guard let data = try? Data(contentsOf: url),
              let lib = try? JSONDecoder().decode(ProfileLibrary.self, from: data),
              !lib.profiles.isEmpty else { return .builtIn }
        return lib
    }

    public func save(_ library: ProfileLibrary) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(library).write(to: url, options: .atomic)
    }
}
