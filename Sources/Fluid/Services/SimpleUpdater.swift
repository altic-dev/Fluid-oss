import Foundation
import AppKit
import PromiseKit

enum SimpleUpdateError: Error, LocalizedError {
    case invalidResponse
    case jsonDecoding
    case noSuitableRelease
    case noAsset
    case downloadFailed
    case unzipFailed
    case notAnAppBundle
    case codesignMismatch

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid HTTP response from GitHub."
        case .jsonDecoding: return "The data couldn’t be read because it isn’t in the correct format."
        case .noSuitableRelease: return "No suitable release found."
        case .noAsset: return "No matching asset found in the latest release."
        case .downloadFailed: return "Failed to download update."
        case .unzipFailed: return "Failed to extract the update archive."
        case .notAnAppBundle: return "Extracted content does not contain an app bundle."
        case .codesignMismatch: return "Downloaded app’s code signature does not match current app."
        }
    }
}

struct GHRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let content_type: String
    }
    let tag_name: String
    let prerelease: Bool
    let assets: [Asset]
}

@MainActor
final class SimpleUpdater {
    static let shared = SimpleUpdater()
    private init() {}
    // Allowed Apple Developer Team IDs for code-sign validation
    // Configured per your request; restrict to your actual Team ID only.
    private let allowedTeamIDs: Set<String> = [
        "V4J43B279J"
    ]

    func checkAndUpdate(owner: String, repo: String) async throws {
        let releasesURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases")!

        let (data, response) = try await URLSession.shared.data(from: releasesURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SimpleUpdateError.invalidResponse
        }

        let releases: [GHRelease]
        do {
            releases = try JSONDecoder().decode([GHRelease].self, from: data)
        } catch {
            throw SimpleUpdateError.jsonDecoding
        }

        // choose latest non-prerelease release
        guard let latest = releases.first(where: { !$0.prerelease }) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        let currentVersionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let current = parseVersion(currentVersionString)
        let latestTag = latest.tag_name
        let latestVersion = parseVersion(latestTag)

        // up to date
        if !isVersion(latestVersion, greaterThan: current) {
            throw PMKError.cancelled // mimic AppUpdater semantics for up-to-date
        }

        // Find asset matching: "{repo-lower}-{version-no-v}.*" and zip preferred
        let verString = versionString(latestVersion)
        let prefix = "\(repo.lowercased())-\(verString)"
        let asset = latest.assets.first { asset in
            let base = (asset.name as NSString).deletingPathExtension.lowercased()
            return (base == prefix) && (asset.content_type == "application/zip" || asset.content_type == "application/x-zip-compressed")
        } ?? latest.assets.first { asset in
            let base = (asset.name as NSString).deletingPathExtension.lowercased()
            return (base == prefix)
        }

        guard let asset = asset else { throw SimpleUpdateError.noAsset }

        let tempDir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: Bundle.main.bundleURL, create: true)
        let downloadURL = tempDir.appendingPathComponent(asset.browser_download_url.lastPathComponent)

        do {
            let (tmpFile, _) = try await URLSession.shared.download(from: asset.browser_download_url)
            try FileManager.default.moveItem(at: tmpFile, to: downloadURL)
        } catch {
            throw SimpleUpdateError.downloadFailed
        }

        // unzip
        let extractedBundleURL: URL
        do {
            extractedBundleURL = try await unzip(at: downloadURL)
        } catch {
            throw SimpleUpdateError.unzipFailed
        }

        guard extractedBundleURL.pathExtension == "app" else {
            throw SimpleUpdateError.notAnAppBundle
        }

        // Validate code signing identity matches (skip in DEBUG for easier local testing)
        let currentBundle = Bundle.main
        #if DEBUG
        // In Debug builds the local app is typically signed with a development cert, while
        // releases are signed with Developer ID. Skip strict check to enable testing.
        _ = currentBundle // keep reference used in Release path
        #else
        let curID = try await codeSigningIdentity(for: currentBundle.bundleURL)
        let newID = try await codeSigningIdentity(for: extractedBundleURL)

        func teamID(from identity: String) -> String? {
            // Handle TeamIdentifier= format first
            if identity.hasPrefix("TeamIdentifier=") {
                return String(identity.dropFirst("TeamIdentifier=".count))
            }
            
            // Handle Authority= format (extract team ID from parentheses)
            guard let l = identity.lastIndex(of: "("), let r = identity.lastIndex(of: ")"), l < r else { return nil }
            let inside = identity[identity.index(after: l)..<r]
            return String(inside)
        }

        // Allow update if:
        // - full identity matches OR
        // - Team IDs match OR
        // - both current and new Team IDs are in the allowedTeamIDs set
        // This enables dev→prod updates across your two known Team IDs.
        let sameIdentity = curID == newID
        let curTeam = teamID(from: curID)
        let newTeam = teamID(from: newID)
        let sameTeam = (curTeam != nil && curTeam == newTeam)
        let bothAllowed = (curTeam != nil && newTeam != nil && allowedTeamIDs.contains(curTeam!) && allowedTeamIDs.contains(newTeam!))
        
        guard sameIdentity || sameTeam || bothAllowed else {
            print("SimpleUpdater: Code-sign mismatch. Current=\(curID) New=\(newID)")
            print("SimpleUpdater: Current Team=\(curTeam ?? "none") New Team=\(newTeam ?? "none")")
            throw SimpleUpdateError.codesignMismatch
        }
        #endif

        // Replace and relaunch
        try performSwapAndRelaunch(installedAppURL: currentBundle.bundleURL, downloadedAppURL: extractedBundleURL)
    }

    // MARK: - Helpers
    private func parseVersion(_ s: String) -> [Int] {
        let t = s.hasPrefix("v") ? String(s.dropFirst()) : s
        let comps = t.split(separator: ".").map { Int($0) ?? 0 }
        return [comps[safe:0] ?? 0, comps[safe:1] ?? 0, comps[safe:2] ?? 0]
    }

    private func versionString(_ v: [Int]) -> String {
        // Match asset naming that omits trailing .0
        if v[2] == 0 { return "\(v[0]).\(v[1])" }
        return "\(v[0]).\(v[1]).\(v[2])"
    }

    private func isVersion(_ a: [Int], greaterThan b: [Int]) -> Bool {
        if a[0] != b[0] { return a[0] > b[0] }
        if a[1] != b[1] { return a[1] > b[1] }
        return a[2] > b[2]
    }

    private func unzip(at url: URL) async throws -> URL {
        let workDir = url.deletingLastPathComponent()
        let proc = Process()
        proc.currentDirectoryURL = workDir
        proc.launchPath = "/usr/bin/unzip"
        proc.arguments = [url.path]

        return try await withCheckedThrowingContinuation { cont in
            proc.terminationHandler = { _ in
                // Find first .app in workDir
                if let appURL = try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsSubdirectoryDescendants]).first(where: { $0.pathExtension == "app" }) {
                    cont.resume(returning: appURL)
                } else {
                    cont.resume(throwing: SimpleUpdateError.unzipFailed)
                }
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }

    private func codeSigningIdentity(for bundleURL: URL) async throws -> String {
        let proc = Process()
        proc.launchPath = "/usr/bin/codesign"
        proc.arguments = ["-dvvv", bundleURL.path]
        let pipe = Pipe()
        proc.standardError = pipe

        return try await withCheckedThrowingContinuation { cont in
            proc.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let s = String(data: data, encoding: .utf8) ?? ""
                
                // First try to get TeamIdentifier (most reliable)
                if let teamLine = s.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) {
                    cont.resume(returning: String(teamLine))
                } else {
                    // Fallback to Authority line
                    let line = s.split(separator: "\n").first(where: { $0.hasPrefix("Authority=") })
                    cont.resume(returning: line.map(String.init) ?? "")
                }
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }

    private func performSwapAndRelaunch(installedAppURL: URL, downloadedAppURL: URL) throws {
        // Replace bundle on disk
        try FileManager.default.removeItem(at: installedAppURL)
        try FileManager.default.moveItem(at: downloadedAppURL, to: installedAppURL)

        // Use modern NSWorkspace API for more reliable app launching
        DispatchQueue.main.async {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            
            NSWorkspace.shared.openApplication(at: installedAppURL, configuration: configuration) { app, error in
                if let error = error {
                    print("Failed to relaunch app: \(error)")
                }
                
                // Give the new instance time to fully start before terminating
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
