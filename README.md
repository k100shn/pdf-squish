# PDFSquish

A minimal macOS app for **lossless** PDF compression. Drop files, get smaller files with zero quality loss.

## Setup

### 1. Install qpdf (recommended)

```bash
brew install qpdf
```

This gives you the real compression engine — stream recompression, object packing, deduplication. Without it the app falls back to PDFKit which achieves less compression but still preserves all metadata.

### 2. Build the app

**Option A: Direct compile**

```bash
./build.sh
open build/PDFSquish.app
```

**Option B: XcodeGen (generates Xcode project)**

```bash
brew install xcodegen    # one-time
./build.sh xcodegen      # generates + opens Xcode project
# Press Cmd+R in Xcode
```

> Intel Mac? The build script auto-detects your architecture.

## How It Works

1. Drag one or more PDFs onto the window (or click "Choose PDF")
2. Each file is compressed sequentially with a progress indicator
3. Compressed files save next to the originals as `filename-compressed.pdf`
4. If a file is already optimized (≤ 1% savings), no duplicate is created

The status pill at the top right shows which engine is active (green = qpdf installed).

### Compression techniques (all lossless)

With qpdf installed, PDFSquish runs these optimizations:

| Technique | What it does |
|---|---|
| **Flate recompression** | Re-deflates all streams at zlib level 9 (max) |
| **Object streams** | Packs small PDF objects into compressed bundles |
| **Unreferenced cleanup** | Removes orphaned objects that bloat the file |

None of these touch image quality, font rendering, or page dimensions. Every pixel comes out identical.

### Fallback engine

Without qpdf, PDFSquish uses Apple's PDFKit for re-serialization. This preserves all document structure — annotations, form fields, bookmarks, metadata, named destinations — but achieves less compression than qpdf.

## Features

- Drag & drop single or multiple PDFs
- Batch compression with per-file progress
- Already-optimized detection (no useless duplicates)
- qpdf lossless engine with PDFKit fallback
- Metadata preservation (annotations, form fields, bookmarks)
- 500 MB file size limit
- Minimal, translucent UI

## Requirements

- macOS 13.0+
- Xcode Command Line Tools (for building)
- qpdf (`brew install qpdf`) — strongly recommended

## Security & privacy

- **100% local.** PDFSquish does no networking — your files never leave your Mac. The app bundle ships a `PrivacyInfo.xcprivacy` manifest declaring no tracking and no data collection.
- **Not sandboxed.** The app runs outside the macOS App Sandbox so it can invoke the `qpdf` command-line binary and write the `-compressed.pdf` output next to your originals. It only touches files you drop in or pick.
- **Subprocess.** When qpdf is installed, it is executed as a separate, system-installed binary (found on the standard Homebrew / `/usr/bin` paths); PDFSquish does not bundle or modify it.

## Acknowledgements

- Lossless compression is powered by [qpdf](https://github.com/qpdf/qpdf), licensed under Apache-2.0. qpdf is invoked as a separately-installed binary and is **not** bundled with this app.
- The app icon is original artwork.

## License

MIT — see [LICENSE](LICENSE).
