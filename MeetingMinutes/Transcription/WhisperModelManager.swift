import Foundation
import OSLog

/// Ensures the Whisper model file is present on disk, downloading it on first
/// use. Models are too large to ship in the app/git, so they live in
/// Application Support and are fetched once from Hugging Face.
final class WhisperModelManager: NSObject, URLSessionDownloadDelegate {
    /// Default model: multilingual `small` (~466 MB) with auto language detection.
    static let modelFileName = "ggml-small.bin"
    static let remoteURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!

    private let logger = Logger(subsystem: "build.ecoblox.MeetingMinutes", category: "WhisperModelManager")
    private var progressHandler: ((Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL?

    static func modelsDirectory() throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MeetingMinutes/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func localModelURL() throws -> URL {
        try modelsDirectory().appendingPathComponent(modelFileName)
    }

    var isModelDownloaded: Bool {
        guard let url = try? Self.localModelURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Returns the local model URL, downloading the model first if necessary.
    /// `progress` is called with 0...1 during download (on an arbitrary thread).
    func ensureModel(progress: @escaping (Double) -> Void) async throws -> URL {
        let destination = try Self.localModelURL()
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        logger.info("Downloading Whisper model to \(destination.path)")
        self.destination = destination
        self.progressHandler = progress

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: Self.remoteURL).resume()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let destination else {
            continuation?.resume(throwing: URLError(.cannotCreateFile))
            continuation = nil
            return
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            // The temporary file is deleted when this delegate returns, so move it now.
            try fm.moveItem(at: location, to: destination)
            logger.info("Whisper model download complete")
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }  // success handled in didFinishDownloadingTo
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
