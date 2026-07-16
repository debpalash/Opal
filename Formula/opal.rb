class Opal < Formula
  # Binary formula: installs the prebuilt release binary.
  #
  # This used to build from source, which meant `depends_on "zig" => :build` and
  # `depends_on xcode: ["15.0", :build]` — so `brew install debpalash/tap/opal`
  # died on any machine that had only the Command Line Tools:
  #
  #   opal: A full installation of Xcode.app 15.0 is required to compile
  #   this software. Installing just the Command Line Tools is not sufficient.
  #
  # Nobody should need a 15 GB Xcode download to install a media player. We already
  # publish a compiled arm64 binary with every release, so install that.
  desc "Pure-Zig desktop media browser + AI copilot (dvui + mpv + apfel)"
  homepage "https://github.com/debpalash/Opal"
  version "0.4.0"
  license "GPL-3.0-only"

  url "https://github.com/debpalash/Opal/releases/download/v0.4.0/opal-0.4.0-macos-arm64.tar.gz"
  sha256 "bed21b84b2223dda99c4e515ea2ecf74a2c7bf7c59d84f349b7032040d76f9e4"

  # The published binary is Apple-silicon only (GitHub retired the Intel runners).
  # Say so up front instead of installing something that cannot run.
  depends_on arch: :arm64
  depends_on :macos

  # Runtime — this is a bare binary, so it links against Homebrew's dylibs. (The
  # .app bundle from the same release vendors these instead and needs none of them;
  # that is what scripts/install.sh installs by default.)
  depends_on "libtorrent-rasterbar"
  depends_on "mpv"
  depends_on "onnxruntime"
  depends_on "sqlite"

  # AI copilot.
  depends_on "apfel" => :recommended

  # Voice pipeline (all optional; voice mode degrades gracefully if missing).
  depends_on "ffmpeg" => :recommended      # mic capture via avfoundation
  depends_on "whisper-cpp" => :recommended # STT default backend

  def install
    bin.install "opal"
  end

  def caveats
    <<~EOS
      Opal stores config + models in ~/.config/opal/.

      This formula installs the command-line binary. For the GUI app bundle
      (self-contained — it vendors mpv/SDL and needs no Homebrew deps):
        curl -fsSL https://raw.githubusercontent.com/debpalash/Opal/main/scripts/install.sh | sh

      To enable voice/STT, keep `whisper-cpp` and `ffmpeg` on PATH.
    EOS
  end

  test do
    # A GUI binary with no --version flag (it would open a window and never exit),
    # so assert install shape rather than launching it.
    assert_predicate bin/"opal", :executable?
  end
end
