class Opal < Formula
  desc "Pure-Zig desktop media browser + AI copilot (dvui + mpv + apfel)"
  homepage "https://github.com/debpalash/Opal"
  url "https://github.com/debpalash/Opal.git",
      tag: "v0.1.0",
      revision: "HEAD"
  license "GPL-3.0-only"
  head "https://github.com/debpalash/Opal.git", branch: "main"

  # Build-time
  depends_on "zig" => :build

  # Runtime — media + torrent pipeline
  depends_on "mpv"
  depends_on "sqlite"
  depends_on "libtorrent-rasterbar"
  depends_on "onnxruntime"

  # AI copilot (macOS only)
  depends_on "apfel" => :recommended
  # NB: apfel lives at https://github.com/debpalash/homebrew-tap once published.
  # Until then, `brew install opal/tap/apfel` or a manual install is needed.

  # Voice pipeline (all optional; voice mode degrades gracefully if missing)
  depends_on "ffmpeg" => :recommended       # mic capture via avfoundation
  depends_on "whisper-cpp" => :recommended  # STT default backend
  # sherpa-onnx is an optional alternative backend (streaming STT + Kokoro TTS).
  # Not in core homebrew; install via `brew install k2-fsa/tap/sherpa-onnx`.

  # macOS-only; on Linux, depends_on would include pulseaudio/pipewire
  on_macos do
    depends_on xcode: ["15.0", :build]
  end

  def install
    system ENV["HOMEBREW_PREFIX"].to_s + "/bin/zig", "build",
           "-Doptimize=ReleaseFast",
           "--prefix", prefix
    bin.install "zig-out/bin/opal"
  end

  def post_install
    # Fetch whisper tiny model if missing (user can `brew postinstall opal` anytime).
    model_dir = Pathname.new(Dir.home) / ".config/opal/models"
    model_path = model_dir / "ggml-tiny.en.bin"
    unless model_path.exist?
      model_dir.mkpath
      system "curl", "-L", "-o", model_path.to_s,
             "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin"
    end
  end

  def caveats
    <<~EOS
      Opal stores config + models in ~/.config/opal/.

      To enable AI chat (macOS Apple Intelligence backend), install apfel:
        brew install debpalash/tap/apfel

      To enable voice/STT, make sure `whisper-cpp` and `ffmpeg` are on PATH
      (installed by default unless you passed --without-*).
    EOS
  end

  test do
    # The binary is a GUI app with no --version flag (it would open a window
    # and never exit), so assert install shape rather than launching it.
    assert_predicate bin/"opal", :executable?
  end
end
