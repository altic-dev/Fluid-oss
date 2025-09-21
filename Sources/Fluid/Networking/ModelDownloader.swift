import Foundation
import CoreML
import FluidAudio

/// A robust downloader for Hugging Face models with progress tracking and error handling.
/// Supports downloading entire model repositories with proper file structure preservation.
/// Can be configured to use different model repositories for flexibility.
final class HuggingFaceModelDownloader
{
    struct HFEntry: Decodable
    {
        let type: String
        let path: String
    }

    struct ModelItem
    {
        let path: String
        let isDirectory: Bool
    }

    // Configure your optimized repository here
    // These can be customized for different model repositories
    private let owner: String
    private let repo: String
    private let revision: String

    private var baseApiURL: URL
    private var baseResolveURL: URL

    /// Initialize with default model repository settings
    init()
    {
        self.owner = "BarathwajAnandan"
        self.repo = "parakeet-tdt-0.6b-v2-coreml-optim"
        self.revision = "main"
        self.baseApiURL = URL(string: "https://huggingface.co/api/models/")!
            .appendingPathComponent(owner)
            .appendingPathComponent(repo)
            .appendingPathComponent("tree")
            .appendingPathComponent(revision)

        self.baseResolveURL = URL(string: "https://huggingface.co/")!
            .appendingPathComponent(owner)
            .appendingPathComponent(repo)
            .appendingPathComponent("resolve")
            .appendingPathComponent(revision)
    }

    /// Initialize with custom model repository settings
    /// - Parameters:
    ///   - owner: Hugging Face username or organization
    ///   - repo: Repository name containing the models
    ///   - revision: Branch or commit hash (default: "main")
    init(owner: String, repo: String, revision: String = "main")
    {
        self.owner = owner
        self.repo = repo
        self.revision = revision
        self.baseApiURL = URL(string: "https://huggingface.co/api/models/")!
            .appendingPathComponent(owner)
            .appendingPathComponent(repo)
            .appendingPathComponent("tree")
            .appendingPathComponent(revision)

        self.baseResolveURL = URL(string: "https://huggingface.co/")!
            .appendingPathComponent(owner)
            .appendingPathComponent(repo)
            .appendingPathComponent("resolve")
            .appendingPathComponent(revision)
    }

    func ensureModelsPresent(at targetRoot: URL, onProgress: ((Double, String) -> Void)? = nil) async throws
    {
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)

        // Build list of files to download (flatten directories via HF API tree)
        var pendingFiles: [String] = []
        for item in requiredItems()
        {
            if item.isDirectory
            {
                let files = try await listFilesRecursively(relativePath: item.path)
                for rel in files
                {
                    let dest = targetRoot.appendingPathComponent(rel)
                    if FileManager.default.fileExists(atPath: dest.path) == false
                    {
                        pendingFiles.append(rel)
                    }
                }
            }
            else
            {
                let dest = targetRoot.appendingPathComponent(item.path)
                if FileManager.default.fileExists(atPath: dest.path) == false
                {
                    pendingFiles.append(item.path)
                }
            }
        }

        // If nothing to download, say so clearly
        if pendingFiles.isEmpty
        {
            print("[ModelDL] All required model files are already present. Nothing to download.")
            onProgress?(1.0, "")
            return
        }

        // Compute total bytes (best-effort) for determinate progress
        var sizeByPath: [String: Int64] = [:]
        var totalBytes: Int64 = 0
        for rel in pendingFiles
        {
            let expected = try await headExpectedLength(relativePath: rel)
            sizeByPath[rel] = expected
            if expected > 0 { totalBytes += expected }
        }

        let totalHuman = Self.formatBytes(totalBytes)
        print("[ModelDL] Files to download: \(pendingFiles.count), total size: \(totalHuman)")

        var downloadedBytes: Int64 = 0
        let fallbackTotal = pendingFiles.count
        var fallbackCompleted = 0

        for (idx, rel) in pendingFiles.enumerated()
        {
            print("[ModelDL] (\(idx+1)/\(pendingFiles.count)) Downloading: \(rel)")
            try await downloadFile(relativePath: rel, to: targetRoot.appendingPathComponent(rel)) { perFilePct in
                if totalBytes > 0
                {
                    let expected = sizeByPath[rel] ?? 0
                    if expected > 0
                    {
                        let overallBase = Double(downloadedBytes) / Double(totalBytes)
                        let combined = min(1.0, overallBase + (perFilePct * Double(expected)) / Double(totalBytes))
                        onProgress?(combined, rel)
                        print(String(format: "[ModelDL] File progress: %.1f%% (%@)", perFilePct * 100.0, rel))
                        print(String(format: "[ModelDL] Overall progress (est.): %.1f%%", combined * 100.0))
                    }
                }
            }
            if totalBytes > 0
            {
                downloadedBytes += (sizeByPath[rel] ?? 0)
                let pct = min(1.0, Double(downloadedBytes) / Double(totalBytes))
                onProgress?(pct, rel)
                print(String(format: "[ModelDL] Overall progress: %.1f%% (\(Self.formatBytes(downloadedBytes))/\(Self.formatBytes(totalBytes)))", pct * 100.0))
            }
            else if fallbackTotal > 0
            {
                fallbackCompleted += 1
                onProgress?(Double(fallbackCompleted) / Double(fallbackTotal), rel)
                print("[ModelDL] Overall progress: \(fallbackCompleted)/\(fallbackTotal)")
            }
        }
    }

    private func requiredItems() -> [ModelItem]
    {
        return [
            // Loader expects this exact name (typo preserved in upstream API)
            ModelItem(path: "Melspectogram.mlmodelc", isDirectory: true),
            ModelItem(path: "ParakeetEncoder_v2.mlmodelc", isDirectory: true),
            ModelItem(path: "ParakeetDecoder.mlmodelc", isDirectory: true),
            ModelItem(path: "RNNTJoint.mlmodelc", isDirectory: true),
            ModelItem(path: "TokenDurationPrediction.mlmodelc", isDirectory: true),
            ModelItem(path: "parakeet_vocab.json", isDirectory: false),
            ModelItem(path: "config.json", isDirectory: false)
        ]
    }

    private func downloadDirectory(relativePath: String, to destination: URL) async throws
    {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Download entire directory by enumerating all files
        let files = try await listFilesRecursively(relativePath: relativePath)
        for rel in files
        {
            let dest = destination.deletingLastPathComponent().appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await downloadFile(relativePath: rel, to: dest)
        }
    }

    private func downloadFile(relativePath: String, to destination: URL, perFileProgress: ((Double) -> Void)? = nil) async throws
    {
        let fileURL = baseResolveURL.appendingPathComponent(relativePath)

        let delegate = DownloadProgressDelegate(onProgress: perFileProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: fileURL)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.onFinish = { tempUrl, response in
                do
                {
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400
                    {
                        continuation.resume(throwing: NSError(domain: "HF", code: http.statusCode))
                        return
                    }
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: destination.path)
                    {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: tempUrl, to: destination)
                    continuation.resume()
                }
                catch
                {
                    continuation.resume(throwing: error)
                }
            }
            delegate.onError = { error in
                continuation.resume(throwing: error)
            }
            task.resume()
        }
    }

    private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate
    {
        private let onProgress: ((Double) -> Void)?
        var onFinish: ((URL, URLResponse) -> Void)?
        var onError: ((Error) -> Void)?

        init(onProgress: ((Double) -> Void)?)
        {
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL)
        {
            guard let response = downloadTask.response else { return }
            onFinish?(location, response)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
        {
            if let error = error { onError?(error) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64)
        {
            guard totalBytesExpectedToWrite > 0 else { return }
            let pct = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            onProgress?(pct)
        }
    }

    private func headExpectedLength(relativePath: String) async throws -> Int64
    {
        let fileURL = baseResolveURL.appendingPathComponent(relativePath)
        var req = URLRequest(url: fileURL)
        req.httpMethod = "HEAD"
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode < 400 else {
            return 0
        }
        return http.expectedContentLength
    }

    private func listFilesRecursively(relativePath: String) async throws -> [String]
    {
        let listingURL = baseApiURL
            .appendingPathComponent(relativePath)
        var comps = URLComponents(url: listingURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "recursive", value: "1")]

        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400
        {
            throw NSError(domain: "HF", code: http.statusCode)
        }

        let decoder = JSONDecoder()
        let entries = try decoder.decode([HFEntry].self, from: data)

        return entries
            .filter { $0.type == "file" }
            .map { $0.path }
    }

    private static func formatBytes(_ bytes: Int64) -> String
    {
        let kb: Double = 1024
        let mb = kb * 1024
        let gb = mb * 1024
        let b = Double(bytes)
        if b >= gb { return String(format: "%.2f GB", b / gb) }
        if b >= mb { return String(format: "%.2f MB", b / mb) }
        if b >= kb { return String(format: "%.2f KB", b / kb) }
        return "\(bytes) B"
    }
}

extension HuggingFaceModelDownloader
{
    /// Load ASR models directly from disk without invoking FluidAudio's DownloadUtils
    func loadLocalAsrModels(from repoDirectory: URL) async throws -> AsrModels
    {
        let config = AsrModels.defaultConfiguration()

        let melUrl = repoDirectory.appendingPathComponent("Melspectogram.mlmodelc")
        let encUrl = repoDirectory.appendingPathComponent("ParakeetEncoder_v2.mlmodelc")
        let decUrl = repoDirectory.appendingPathComponent("ParakeetDecoder.mlmodelc")
        let jointUrl = repoDirectory.appendingPathComponent("RNNTJoint.mlmodelc")
        let tokenUrl = repoDirectory.appendingPathComponent("TokenDurationPrediction.mlmodelc")

        let mel = try MLModel(contentsOf: melUrl, configuration: config)
        let enc = try MLModel(contentsOf: encUrl, configuration: config)
        let dec = try MLModel(contentsOf: decUrl, configuration: config)
        let joint = try MLModel(contentsOf: jointUrl, configuration: config)
        let token = try MLModel(contentsOf: tokenUrl, configuration: config)

        return AsrModels(
            melspectrogram: mel,
            encoder: enc,
            decoder: dec,
            joint: joint,
            tokenDuration: token,
            configuration: config
        )
    }
}


