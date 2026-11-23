import Foundation

/// Public client-side MapTiler key, provided by the build configuration.
/// A mobile app cannot keep a map API key secret from a determined user;
/// use a separate restricted key with limits and revoke it when exposed.
enum MapTilerConfiguration {
    static var apiKey: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "MapTilerAPIKey") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("$(") || raw.contains("YOUR_") { return "" }
        return raw
    }

    static var isConfigured: Bool { !apiKey.isEmpty }
}
