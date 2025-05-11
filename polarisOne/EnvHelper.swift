import Foundation

class EnvHelper {
    private static var env: [String: String]? = nil
    private static let envFileName = ".env"

    private static func loadEnv() {
        guard env == nil else { return }
        var result: [String: String] = [:]
        // Try to find the .env file in the main bundle or current directory
        let envURL: URL? = {
            if let bundleURL = Bundle.main.url(forResource: envFileName, withExtension: nil) {
                return bundleURL
            }
            let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(envFileName)
            if FileManager.default.fileExists(atPath: cwdURL.path) {
                return cwdURL
            }
            return nil
        }()
        if let envURL = envURL, let content = try? String(contentsOf: envURL) {
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eqIdx = trimmed.firstIndex(of: "=") else { continue }
                let key = String(trimmed[..<eqIdx]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                result[key] = value
            }
        }
        env = result
    }

    static func value(for key: String) -> String {
        loadEnv()
        return env?[key] ?? ""
    }
} 