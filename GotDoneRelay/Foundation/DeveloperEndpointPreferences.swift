import Foundation

/// Developer overrides for live sync endpoints (UserDefaults).
enum DeveloperEndpointPreferences {
    private static let relayURLKey = "developer.relayURLOverride"

    static var relayURLOverrideString: String? {
        get {
            let value = UserDefaults.standard.string(forKey: relayURLKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, !value.isEmpty else {
                return nil
            }
            return value
        }
        set {
            let trimmed = newValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                UserDefaults.standard.set(trimmed, forKey: relayURLKey)
            } else {
                UserDefaults.standard.removeObject(forKey: relayURLKey)
            }
        }
    }

    static var relayURLOverride: URL? {
        guard let raw = relayURLOverrideString else {
            return nil
        }
        return URL(string: raw)
    }

    static func clearRelayURLOverride() {
        relayURLOverrideString = nil
    }
}
