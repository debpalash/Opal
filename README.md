<div align="center">
  <img src="assets/opal_logo.png" alt="Opal Logo" width="250px" />

  # Opal
  **The blazing-fast, decentralized, local-first intelligent media runtime.**
</div>

---

## 💎 Why Opal Matters

Modern media consumption is heavily fragmented across slow, web-based Electron apps that harvest telemetry, trap you in subscription silos, and rely on centralized servers.

**Opal** is built from the ground up to break that mold. It's a completely native, memory-safe desktop application written in **Zig**, unifying the capabilities of Jellyfin, Stremio, and a local AI orchestrator into a single, lightning-fast binary. 

Opal runs seamlessly on your own hardware, leveraging local intelligence, peer-to-peer torrent streaming, and hardware-accelerated playback to guarantee that your media is entirely yours—fast, private, and exceptionally beautiful.

## ✨ Core Features

* 🚀 **Native Speed**: Zero-downtime hot-reloading in development and millisecond launch times in production. No Electron overhead.
* 🎥 **Decentralized Streaming**: Direct `.torrent` and magnet link stream buffering powered by `libtorrent` with piece prioritization to start playback instantly.
* 🧠 **Built-in AI Intelligence**: Integrated ONNX OCR processing, internal ML vector search via `sqlite-vec`, and local LLM chat processing for metadata extractions and smart recommendations.
* 📡 **Universal Sync**: Connect local media, native RSS feeds, Jellyfin libraries, YouTube, and trackers into one seamless interface.
* 🎨 **Premium UI**: Immediate-mode GUI built with `dvui`, natively rendering polished glassmorphism elements, hardware-accelerated interfaces, and split-screen multiplayer support.

## 🛠 Tech Stack

Opal pushes the boundary of what's possible in modern desktop client engineering:

| Technology | Purpose |
| -----------|---------|
| **Zig (0.16.x)** | Core programming language for memory safety and pure performance. |
| **dvui** | State-of-the-art immediate mode UI framework without web-engine bloat. |
| **libtorrent**| Industry-standard C++ peer-to-peer engine wrapper. |
| **mpv** | Integrated video pipeline for flawless `hwdec=auto-safe` decoding. |
| **ONNX Runtime**| Local machine learning execution. |
| **sqlite-vec** | SQLite extension for lightning-fast embedded vector search mapping. |

## 🚀 Getting Started

Opal features an instant hot-module-replacement (HMR) development loop.

```bash
# Clone the repository
git clone https://github.com/debpalash/Opal.git
cd Opal
git submodule update --init

# Run the dev server (Watch mode)
# Automatically rebuilds and restarts while maintaining player state!
./dev.sh
```

*(Note: Ensure you are on Zig 0.16.x to benefit from the new millisecond-incremental build engine).*

---
<div align="center">
  Built with ❤️ in ⚡️ Zig.
</div>
