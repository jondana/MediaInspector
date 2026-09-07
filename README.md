# MediaInspector

<p align="center">
  <img src="https://github.com/user-attachments/assets/c29da42a-ceae-46d5-892d-a9e216e68ccf" alt="MediaInspector Screenshot" width="820"/>
</p>

<p align="center">
  <b>A blazing-fast, standalone macOS media inspector and stream analyzer.</b><br/>
  Engineered for video editors, DITs, colorists, and media engineers. Built with CustomTkinter and bundled with a dedicated, zero-dependency static FFprobe engine.
</p>

<p align="center">
  <a href="https://ko-fi.com/jondana"><img src="https://img.shields.io/badge/Support_on-Ko--fi-FF5E5B?style=for-the-badge&logo=kofi&logoColor=white" alt="Support on Ko-fi"/></a>
  <img src="https://img.shields.io/badge/Platform-macOS%2011.0+-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Platform macOS"/>
  <img src="https://img.shields.io/badge/Architecture-Universal%20(Apple%20Silicon%20%2F%20Intel)-2365cf?style=for-the-badge" alt="Architecture Universal"/>
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="License"/>
</p>

---

## 🌟 Overview

**MediaInspector** provides comprehensive, instant technical inspection of media files without indexing stalls, playback lag, or intrusive UI overhead. 

Unlike general video players or generic metadata viewers, MediaInspector pulls deep stream-level metadata directly from a self-contained static `ffprobe` binary—including HDR transfer characteristics, chroma subsampling formats, CFR/VFR timing details, audio channel configurations, and chapter cues—presented in an Apple-native dark UI.

---

## ⚡ Key Features

- 🎯 **HUD Quick-Spec Chips**: Instant at-a-glance stat cards for **Resolution**, **Bitrate**, **Frame Rate** (CFR/VFR status), **Color Space & HDR** (PQ/HLG, primaries, bit depth), **Audio**, and **File Size**.
- 🗂️ **Collapsible Multi-File Queue**:
  - Slide-out drawer displaying all queued media files with dynamic mini-spec badges.
  - Viewport-culled canvas rendering for butter-smooth navigation even when loading hundreds of clips.
  - Add single files, batches, or recursive directories in one drop.
- 🔬 **Deep Technical Inspection**:
  - **General**: Container syntax, file size in bytes/GB, exact duration, bitrates, and capture timestamps.
  - **Video Streams**: Codec, profile & level, dimensions + common industry labels (4K UHD, DCI, FHD), display aspect ratio, bit depth, chroma subsampling (4:2:0, 4:2:2, 4:4:4), color primaries, transfer functions, and color range (TV / Full).
  - **Audio Streams**: Codecs, bitrates, sample rates (kHz), lossless indicators, channel counts, layouts (Mono, Stereo, 5.1), and language tagging.
  - **Images & Covers**: Identification of embedded album covers, standalone images, and raw photography formats (megapixels, color spaces).
  - **Subtitles & Chapters**: Track layouts, languages, and formatted chapter timecode markers.
- 🏎️ **Quartz 120 FPS Kinetic Scroll Engine**: Custom physics-based kinetic scrolling engine optimized for Apple trackpads and high-refresh ProMotion displays.
- 📋 **One-Click Copy & Export**: Copy cleanly formatted text reports directly to your clipboard or export detailed reports as `.txt` or raw `.json`.
- 📁 **macOS Integration**:
  - Drag and drop onto the window or directly onto the macOS Dock icon.
  - Single-click **"Reveal in Finder"** to jump straight to source media.
  - Remembers window dimensions, position, and drawer state across launches.
- 🔒 **100% Self-Contained**: No external dependencies. Bundles its own static, standalone `ffprobe` executable.

---

## 🎞️ Supported Formats

| Category | File Extensions |
| :--- | :--- |
| **Video** | `.mov`, `.mp4`, `.mkv`, `.m4v`, `.mxf`, `.crm`, `.raw`, `.avi`, `.webm`, `.ts`, `.mts`, `.m2ts`, `.wmv`, `.flv`, `.vob`, `.ogv`, `.m2v`, etc. |
| **Audio** | `.wav`, `.aif`, `.aiff`, `.flac`, `.m4a`, `.aac`, `.mp3`, `.ogg`, `.opus`, `.wma`, `.ac3`, `.eac3`, `.m4r` |
| **Images & RAW** | `.png`, `.jpg`, `.jpeg`, `.tiff`, `.tif`, `.heic`, `.webp`, `.bmp`, `.gif`, `.dng`, `.cr2`, `.nef`, `.arw` |

---

## 📥 Installation

### Option 1: Pre-Built DMG
1. Download the latest **`MediaInspector.dmg`** from [Releases](https://github.com/your-username/MediaInspector/releases).
2. Open the `.dmg` and drag **MediaInspector.app** into your `/Applications` folder.

> [!IMPORTANT]
> ### First-Time Launch (Gatekeeper Workaround)
> Because MediaInspector is self-built and ad-hoc signed, macOS Gatekeeper may warn that the app is "damaged" or from an unidentified developer.
>
> To resolve this in one step:
> 1. Open **Terminal** (`Cmd + Space` ➔ `Terminal` ➔ `Enter`).
> 2. Run:
>    ```bash
>    xattr -cr /Applications/MediaInspector.app
>    ```
> 3. Launch **MediaInspector** normally from your Applications folder or Spotlight.

---

## 🛠️ Building from Source

To build a standalone `.app` and distributor `.dmg` on your Mac:

```bash
# 1. Clone the repository
git clone https://github.com/your-username/MediaInspector.git
cd MediaInspector

# 2. Ensure python-tk is installed (Homebrew)
brew install python-tk

# 3. Run the automated build script
chmod +x build_inspector.sh
./build_inspector.sh

The script will automatically:

  - Download the correct static ffprobe binary for your architecture (arm64 or
    x86_64).
  - Set up an isolated build virtualenv.
  - Generate high-resolution multi-scale Apple .icns icons.
  - Bundle everything via PyInstaller into MediaInspector.app and output a
    ready-to-distribute .dmg to your Desktop.

☕ Support & Contributions

MediaInspector is open-source and free for filmmakers, colorists, and engineers.

If MediaInspector saves you time or helps streamline your production pipeline,
consider supporting ongoing development:

📄 License

Distributed under the MIT License. See LICENSE for details.

