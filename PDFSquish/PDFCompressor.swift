import Foundation
import PDFKit

/// Lossless PDF compression engine.
///
/// Uses `qpdf` (installable via Homebrew) for true lossless optimization:
///   - Recompress all streams with Flate at max level (zlib 9)
///   - Generate object streams (bundles small objects together)
///   - Remove unreferenced objects
///   - Zero quality loss — every pixel, glyph, and vector preserved
///
/// Falls back to PDFKit re-serialization if qpdf isn't installed.
/// PDFKit preserves all document structure (annotations, form fields,
/// bookmarks, metadata, named destinations) but achieves less compression
/// than qpdf.
final class PDFCompressor {

    // MARK: - Constants

    /// Maximum input file size: 500 MB.
    static let maxFileSize: Int64 = 500_000_000

    // MARK: - Types

    enum CompressionError: LocalizedError {
        case cannotOpenInput
        case cannotCreateOutput
        case noPages
        case fileTooLarge(Int64)
        case qpdfFailed(String)
        case alreadyOptimized(Int64)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .cannotOpenInput:
                return "Could not open the input PDF."
            case .cannotCreateOutput:
                return "Could not create the output file."
            case .noPages:
                return "The PDF has no pages."
            case .fileTooLarge(let bytes):
                let formatted = Result.formatBytes(bytes)
                return "File is too large (\(formatted)). Maximum size is 500 MB."
            case .qpdfFailed(let msg):
                return "qpdf error: \(msg)"
            case .alreadyOptimized(let bytes):
                let formatted = Result.formatBytes(bytes)
                return "Already optimized (\(formatted)) — no further compression possible."
            case .cancelled:
                return "Compression was cancelled."
            }
        }
    }

    enum Method: String {
        case qpdf = "qpdf (lossless)"
        case pdfKit = "PDFKit (lossless, metadata-safe)"
    }

    struct Result {
        let originalSize: Int64
        let compressedSize: Int64
        let outputURL: URL
        let method: Method
        /// Non-nil if qpdf was attempted but failed, triggering the PDFKit fallback.
        let fallbackReason: String?
        /// True if the file could not be compressed further.
        let alreadyOptimized: Bool
        /// Non-nil if the input PDF contains digital signatures that were invalidated.
        let signatureWarning: String?

        init(originalSize: Int64, compressedSize: Int64, outputURL: URL, method: Method,
             fallbackReason: String? = nil, alreadyOptimized: Bool = false,
             signatureWarning: String? = nil) {
            self.originalSize = originalSize
            self.compressedSize = compressedSize
            self.outputURL = outputURL
            self.method = method
            self.fallbackReason = fallbackReason
            self.alreadyOptimized = alreadyOptimized
            self.signatureWarning = signatureWarning
        }

        var savings: Double {
            guard originalSize > 0 else { return 0 }
            return Double(originalSize - compressedSize) / Double(originalSize) * 100
        }

        var formattedOriginal: String   { Self.formatBytes(originalSize) }
        var formattedCompressed: String  { Self.formatBytes(compressedSize) }

        static func formatBytes(_ bytes: Int64) -> String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: bytes)
        }
    }

    // MARK: - Public API

    /// Compress a PDF losslessly. Tries qpdf first, falls back to PDFKit.
    ///
    /// If compression yields ≤1% savings, the output file is removed and the
    /// result is marked `alreadyOptimized = true` with no duplicate created.
    static func compress(inputURL: URL, outputURL: URL? = nil) throws -> Result {
        let size = fileSize(at: inputURL)
        guard size > 0 else { throw CompressionError.cannotOpenInput }
        guard size <= maxFileSize else { throw CompressionError.fileTooLarge(size) }
        guard !isCancelled else { throw CompressionError.cancelled }

        let destination = outputURL ?? defaultOutput(for: inputURL)

        // Check for digital signatures before compression
        let sigWarning: String? = hasDigitalSignatures(at: inputURL)
            ? "This PDF contains digital signatures that will be invalidated by re-serialization."
            : nil

        let result: Result
        if let qpdfPath = findQPDF() {
            result = try compressWithQPDF(qpdfPath: qpdfPath, inputURL: inputURL, outputURL: destination)
        } else {
            result = try compressWithPDFKit(inputURL: inputURL, outputURL: destination)
        }

        // Check cancellation after compression completes
        if isCancelled {
            try? FileManager.default.removeItem(at: destination)
            throw CompressionError.cancelled
        }

        // If savings ≤ 1%, remove the output file — don't create a duplicate
        if result.savings <= 1 {
            try? FileManager.default.removeItem(at: destination)
            return Result(
                originalSize: result.originalSize,
                compressedSize: result.originalSize,
                outputURL: inputURL,  // point back to original, no duplicate
                method: result.method,
                fallbackReason: result.fallbackReason,
                alreadyOptimized: true,
                signatureWarning: sigWarning
            )
        }

        return Result(
            originalSize: result.originalSize,
            compressedSize: result.compressedSize,
            outputURL: result.outputURL,
            method: result.method,
            fallbackReason: result.fallbackReason,
            signatureWarning: sigWarning
        )
    }

    /// Check whether qpdf is available on the system.
    static var isQPDFAvailable: Bool { findQPDF() != nil }

    /// Force a re-check of qpdf availability (e.g., after user installs it).
    static func invalidateQPDFCache() {
        _qpdfLock.lock()
        _qpdfChecked = false
        _cachedQPDFPath = nil
        _qpdfLock.unlock()
    }

    // MARK: - Cancellation

    private static var _currentProcess: Process?
    private static let _processLock = NSLock()
    private static var _cancelled = false

    /// Cancel the current compression. Terminates any running qpdf process.
    static func cancel() {
        _processLock.lock()
        _cancelled = true
        let proc = _currentProcess
        _currentProcess = nil
        _processLock.unlock()
        proc?.terminate()
    }

    /// Reset cancellation state. Call before starting a new compression batch.
    static func resetCancellation() {
        _processLock.lock()
        _cancelled = false
        _processLock.unlock()
    }

    /// Whether cancellation has been requested.
    static var isCancelled: Bool {
        _processLock.lock()
        defer { _processLock.unlock() }
        return _cancelled
    }

    // MARK: - Digital Signature Detection

    /// Check if a PDF contains digital signatures (invalidated by re-serialization).
    static func hasDigitalSignatures(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // Signature dictionaries (/ByteRange + /Type /Sig) are usually appended
        // near the END of the file via an incremental update, so scan both the
        // head and the tail (up to ~1 MB each) rather than only the first chunk.
        let chunk = 1_048_576
        let end = (try? handle.seekToEnd()) ?? 0
        var blob = Data()
        try? handle.seek(toOffset: 0)
        blob.append(handle.readData(ofLength: chunk))
        if end > UInt64(chunk) {
            try? handle.seek(toOffset: end - UInt64(chunk))
            blob.append(handle.readData(ofLength: chunk))
        }
        guard let text = String(data: blob, encoding: .isoLatin1) else { return false }
        return text.contains("/ByteRange") &&
            (text.contains("/Type/Sig") || text.contains("/Type /Sig"))
    }

    // MARK: - qpdf (lossless)

    private static func compressWithQPDF(
        qpdfPath: String,
        inputURL: URL,
        outputURL: URL
    ) throws -> Result {
        let originalSize = fileSize(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: qpdfPath)
        process.arguments = [
            inputURL.path,
            "--recompress-flate",
            "--compression-level=9",
            "--object-streams=generate",
            "--remove-unreferenced-resources=yes",
            "--",
            outputURL.path
        ]

        let errPipe = Pipe()
        process.standardError = errPipe

        _processLock.lock()
        _currentProcess = process
        _processLock.unlock()

        try process.run()

        // Read stderr BEFORE waiting to prevent pipe buffer deadlock (C1 fix).
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        _processLock.lock()
        _currentProcess = nil
        let wasCancelled = _cancelled
        _processLock.unlock()

        if wasCancelled {
            try? FileManager.default.removeItem(at: outputURL)
            throw CompressionError.cancelled
        }

        if process.terminationStatus != 0 {
            let errMsg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            return try compressWithPDFKit(
                inputURL: inputURL,
                outputURL: outputURL,
                fallbackReason: "qpdf failed: \(errMsg)"
            )
        }

        let compressedSize = fileSize(at: outputURL)
        return Result(
            originalSize: originalSize,
            compressedSize: compressedSize,
            outputURL: outputURL,
            method: .qpdf
        )
    }

    // MARK: - PDFKit fallback (metadata-preserving)

    private static func compressWithPDFKit(
        inputURL: URL,
        outputURL: URL,
        fallbackReason: String? = nil
    ) throws -> Result {
        guard let pdfDoc = PDFDocument(url: inputURL) else {
            throw CompressionError.cannotOpenInput
        }
        guard pdfDoc.pageCount > 0 else { throw CompressionError.noPages }

        let originalSize = fileSize(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)

        guard let data = pdfDoc.dataRepresentation() else {
            throw CompressionError.cannotCreateOutput
        }
        try data.write(to: outputURL)

        let compressedSize = fileSize(at: outputURL)
        return Result(
            originalSize: originalSize,
            compressedSize: compressedSize,
            outputURL: outputURL,
            method: .pdfKit,
            fallbackReason: fallbackReason
        )
    }

    // MARK: - Helpers

    private static let _qpdfLock = NSLock()
    private static var _cachedQPDFPath: String?
    private static var _qpdfChecked = false

    private static func findQPDF() -> String? {
        _qpdfLock.lock()
        defer { _qpdfLock.unlock() }
        if _qpdfChecked { return _cachedQPDFPath }
        _qpdfChecked = true

        let candidates = [
            "/opt/homebrew/bin/qpdf",
            "/usr/local/bin/qpdf",
            "/usr/bin/qpdf"
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                _cachedQPDFPath = path
                return path
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["qpdf"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        // Read stdout BEFORE waitUntilExit to prevent pipe buffer deadlock (matches C1 fix).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let path, FileManager.default.isExecutableFile(atPath: path) {
                _cachedQPDFPath = path
                return path
            }
        }

        _cachedQPDFPath = nil
        return nil
    }

    static func defaultOutput(for inputURL: URL) -> URL {
        let dir = inputURL.deletingLastPathComponent()
        let stem = inputURL.deletingPathExtension().lastPathComponent
        let fm = FileManager.default

        let base = dir.appendingPathComponent("\(stem)-compressed.pdf")
        if !fm.fileExists(atPath: base.path) { return base }

        // Avoid silent overwrites — append numeric suffix
        for n in 2...999 {
            let candidate = dir.appendingPathComponent("\(stem)-compressed-\(n).pdf")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return base // fallback (overwrite) if 999 collisions somehow exist
    }

    static func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}
