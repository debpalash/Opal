import { useState } from "react";

const AUR_BIN = "https://aur.archlinux.org/packages/opal-media-player-bin";
const AUR_SRC = "https://aur.archlinux.org/packages/opal-media-player";

type Way = {
  id: string;
  label: string;
  note: string;
  lines: string[];
};

/**
 * Two AUR packages exist and they conflict: `-bin` installs the official release
 * binary (fast, no toolchain), the other builds from source with zig. The
 * default everywhere is `-bin`; building is one tab away for anyone who wants it.
 */
const WAYS: Way[] = [
  {
    id: "yay",
    label: "yay",
    note: "Installs the official release binary from the AUR and updates with the rest of your system.",
    lines: ["yay -S opal-media-player-bin"],
  },
  {
    id: "paru",
    label: "paru",
    note: "Same package, same result — for paru users.",
    lines: ["paru -S opal-media-player-bin"],
  },
  {
    id: "pacman",
    label: "pacman",
    note: "Opal is not in the official repositories. Download the .pkg.tar.zst from the latest release, then install it with pacman.",
    lines: [
      "curl -s https://api.github.com/repos/debpalash/Opal/releases/latest | grep -o 'https://[^\"]*x86_64\\.pkg\\.tar\\.zst' | xargs curl -LO",
      "sudo pacman -U ./opal-*-x86_64.pkg.tar.zst",
    ],
  },
  {
    id: "makepkg",
    label: "makepkg",
    note: "No AUR helper? Clone the package and let makepkg call pacman for you.",
    lines: [
      "git clone https://aur.archlinux.org/opal-media-player-bin.git",
      "cd opal-media-player-bin && makepkg -si",
    ],
  },
  {
    id: "source",
    label: "build from source",
    note: "Compiles Opal with zig (0.16+) on your machine. It conflicts with the -bin package, so install only one.",
    lines: ["yay -S opal-media-player"],
  },
];

/**
 * Arch Linux install commands, one tab per way in.
 *
 * Like InstallCommand this is an island only for the tabs and copy buttons — the
 * default tab's command is in the server-rendered HTML, so it reads and selects
 * without JavaScript.
 */
export default function ArchInstall() {
  const [id, setId] = useState(WAYS[0].id);
  const [copied, setCopied] = useState(false);
  const way = WAYS.find((w) => w.id === id) ?? WAYS[0];

  async function copy() {
    try {
      await navigator.clipboard.writeText(way.lines.join("\n"));
      setCopied(true);
      setTimeout(() => setCopied(false), 1600);
    } catch {
      // Clipboard is permission-gated; the command is still selectable on screen.
    }
  }

  return (
    <div className="archbox">
      <div className="head">
        <span className="os">🏹</span>
        <span className="grow">
          Arch Linux · Omarchy · Manjaro · EndeavourOS <span className="meta">AUR and pacman</span>
        </span>
      </div>
      <div className="tabs" role="tablist" aria-label="Arch install method">
        {WAYS.map((w) => (
          <button
            key={w.id}
            type="button"
            role="tab"
            aria-selected={w.id === id}
            className={w.id === id ? "on" : ""}
            onClick={() => setId(w.id)}
          >
            {w.label}
          </button>
        ))}
      </div>
      <div className="oneliner stack">
        <div className="lines">
          {way.lines.map((l) => (
            <code key={l}>
              <span className="prompt">$</span> {l}
            </code>
          ))}
        </div>
        <button className="copy" type="button" onClick={copy}>
          {copied ? "Copied" : "Copy"}
        </button>
      </div>
      <p className="hint">{way.note}</p>
      <p className="links">
        <a href={AUR_BIN}>opal-media-player-bin on the AUR</a>
        <a href={AUR_SRC}>opal-media-player on the AUR</a>
        <span>Update later with <code>yay -Syu</code> or <code>sudo pacman -Syu</code>.</span>
      </p>
    </div>
  );
}
