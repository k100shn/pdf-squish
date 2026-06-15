import SwiftUI
import UniformTypeIdentifiers

// MARK: - Per-file result model

struct CompressedFile: Identifiable, Equatable {
    let id = UUID()
    let filename: String
    let originalSize: String
    let compressedSize: String
    let savings: String
    let method: String
    let fallbackReason: String?
    let signatureWarning: String?
    let outputURL: URL
    let alreadyOptimized: Bool
}

// MARK: - Main View

struct ContentView: View {
    enum ViewState: Equatable {
        case idle
        case compressing(current: Int, total: Int)
        case done
        case error(String)
    }

    @SwiftUI.State private var state: ViewState = .idle
    @SwiftUI.State private var dragOver = false
    @SwiftUI.State private var hasQPDF = PDFCompressor.isQPDFAvailable
    @SwiftUI.State private var pulseOpacity: Double = 1.0
    @SwiftUI.State private var results: [CompressedFile] = []
    @SwiftUI.State private var cancelToken: UUID? = nil

    private var isDone: Bool {
        if case .done = state { return true }
        return false
    }

    private var isCompressing: Bool {
        if case .compressing = state { return true }
        return false
    }

    var body: some View {
        ZStack {
            VisualEffectBlur()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                titleBar

                mainContent
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        }
        .frame(width: 420, height: 480)
        // Drop target on the entire window so drag & drop always works
        .onDrop(of: [.pdf], isTargeted: $dragOver) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("PDFSquish")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)

            Spacer()

            engineStatus
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("PDFSquish — \(hasQPDF ? "qpdf engine active" : "qpdf not installed")")
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 10) {
            dropZone
                .frame(maxWidth: .infinity, maxHeight: isDone ? 60 : .infinity)

            if isDone && !results.isEmpty {
                resultsView
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if case .error(let msg) = state {
                errorCard(message: msg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            bottomButtons
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: state)
    }

    // MARK: - Engine Status

    private var engineStatus: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(hasQPDF ? Color.green : Color.orange)
                .frame(width: 5, height: 5)

            if hasQPDF {
                Text("qpdf")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("Install qpdf")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)

                Button {
                    if let url = URL(string: "https://formulae.brew.sh/formula/qpdf") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("brew install qpdf")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(.ultraThinMaterial))
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    dragOver ? Color.accentColor : Color.secondary.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1.5, dash: [10, 5])
                )
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(dragOver ? Color.accentColor.opacity(0.05) : Color.secondary.opacity(0.02))
                )

            if case .compressing(let current, let total) = state {
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(1.1)
                    Text(total > 1 ? "Compressing \(current)/\(total)…" : "Compressing (lossless)…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .opacity(pulseOpacity)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                                pulseOpacity = 0.5
                            }
                        }
                        .onDisappear { pulseOpacity = 1.0 }
                }
                .transition(.opacity)
            } else if isDone {
                VStack(spacing: 2) {
                    Text(results.count == 1 ? (results.first?.filename ?? "Done") : "\(results.count) files compressed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Drop to replace")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .transition(.opacity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: dragOver ? "arrow.down.doc.fill" : "arrow.down.doc")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(dragOver ? .blue : .secondary)

                    Text(dragOver ? "Drop to compress" : "Drop PDFs here")
                        .font(.system(size: 13))
                        .foregroundStyle(dragOver ? Color.blue : Color.secondary.opacity(0.6))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: dragOver)
        .accessibilityLabel("PDF drop target. Drop PDF files here or use the Choose PDF button.")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Results View (scrollable for multi-file)

    private var resultsView: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(results) { file in
                    singleResultCard(file: file)
                }
            }
        }
        .frame(maxHeight: results.count == 1 ? 200 : 260)
    }

    private func singleResultCard(file: CompressedFile) -> some View {
        VStack(spacing: 10) {
            // Hero: savings or already optimized
            if file.alreadyOptimized {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                    Text("Already optimized")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 13))
                    Text("\(file.savings)% smaller")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.1))
                .clipShape(Capsule())
            }

            // Size row
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Original")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(file.originalSize)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(.tertiary)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Compressed")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(file.compressedSize)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
            }

            // Signature warning
            if let warning = file.signatureWarning {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: 10))
                    Text(warning)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.yellow.opacity(0.06))
                )
            }

            // Fallback warning
            if let reason = file.fallbackReason {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 10))
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.orange.opacity(0.06))
                )
            }

            // Method + Finder
            HStack {
                Text("via \(file.method)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                if !file.alreadyOptimized {
                    Button {
                        NSWorkspace.shared.selectFile(file.outputURL.path, inFileViewerRootedAtPath: file.outputURL.deletingLastPathComponent().path)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(file.alreadyOptimized ? Color.secondary.opacity(0.15) : Color.green.opacity(0.2))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.filename): \(file.originalSize) to \(file.compressedSize), \(file.savings) percent smaller")
    }

    // MARK: - Error Card

    private func errorCard(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .accessibilityLabel("Error: \(message)")
    }

    // MARK: - Bottom Buttons

    private var bottomButtons: some View {
        HStack(spacing: 10) {
            if isCompressing {
                Button {
                    cancelCompression()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.red)
            } else {
                Button {
                    pickFiles()
                } label: {
                    Label("Choose PDF", systemImage: "folder.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Actions

    /// File picker: supports multiple selection and auto-compresses.
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose PDFs to compress"

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            compressPDFs(urls: panel.urls)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isCompressing else { return false }

        // Collect ALL dropped files, not just the first
        var pendingCount = providers.count
        var collectedURLs: [URL] = []
        let lock = NSLock()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer {
                        lock.lock()
                        pendingCount -= 1
                        let done = pendingCount == 0
                        let urls = collectedURLs
                        lock.unlock()

                        if done {
                            DispatchQueue.main.async {
                                let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
                                if pdfs.isEmpty {
                                    state = .error("Please drop PDF files.")
                                    scheduleErrorDismissal()
                                } else {
                                    compressPDFs(urls: pdfs)
                                }
                            }
                        }
                    }

                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        lock.lock()
                        collectedURLs.append(url)
                        lock.unlock()
                    }
                }
            } else {
                lock.lock()
                pendingCount -= 1
                lock.unlock()
            }
        }

        return true
    }

    private func cancelCompression() {
        cancelToken = nil
        PDFCompressor.cancel()
        state = .idle
        results = []
    }

    /// Compress one or more PDFs sequentially, updating progress.
    private func compressPDFs(urls: [URL]) {
        guard !isCompressing else { return }

        let token = UUID()
        cancelToken = token
        results = []
        let total = urls.count
        state = .compressing(current: 1, total: total)

        PDFCompressor.invalidateQPDFCache()
        PDFCompressor.resetCancellation()
        hasQPDF = PDFCompressor.isQPDFAvailable

        DispatchQueue.global(qos: .userInitiated).async {
            var newResults: [CompressedFile] = []

            for (index, url) in urls.enumerated() {
                // Check cancellation between files (lock-guarded, no main-thread hop)
                if PDFCompressor.isCancelled { break }

                DispatchQueue.main.async {
                    state = .compressing(current: index + 1, total: total)
                }

                do {
                    let result = try PDFCompressor.compress(inputURL: url)
                    let file = CompressedFile(
                        filename: url.lastPathComponent,
                        originalSize: result.formattedOriginal,
                        compressedSize: result.formattedCompressed,
                        savings: String(format: "%.0f", result.savings),
                        method: result.method.rawValue,
                        fallbackReason: result.fallbackReason,
                        signatureWarning: result.signatureWarning,
                        outputURL: result.outputURL,
                        alreadyOptimized: result.alreadyOptimized
                    )
                    newResults.append(file)
                } catch {
                    if case PDFCompressor.CompressionError.cancelled = error {
                        break // Stop batch on cancellation
                    }
                    let file = CompressedFile(
                        filename: url.lastPathComponent,
                        originalSize: PDFCompressor.Result.formatBytes(PDFCompressor.fileSize(at: url)),
                        compressedSize: "—",
                        savings: "0",
                        method: "error",
                        fallbackReason: error.localizedDescription,
                        signatureWarning: nil,
                        outputURL: url,
                        alreadyOptimized: false
                    )
                    newResults.append(file)
                }
            }

            DispatchQueue.main.async {
                // Only update if not already cancelled (cancelCompression resets state)
                if cancelToken == token {
                    results = newResults
                    state = .done
                    hasQPDF = PDFCompressor.isQPDFAvailable
                }
            }
        }
    }

    private func scheduleErrorDismissal() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if case .error = state { state = .idle }
        }
    }
}

// MARK: - Visual Effect Blur

struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .frame(width: 420, height: 480)
    }
}
