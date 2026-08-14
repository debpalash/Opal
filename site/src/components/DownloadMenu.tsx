import { useEffect, useRef, useState } from "react";
import {
  PLATFORMS,
  REPO,
  assetFor,
  detectOs,
  getReleases,
  platform,
  startDownload,
  type OsId,
  type Release,
} from "../lib/releases";

/**
 * The download button, with the visitor's platform already chosen.
 *
 * Most people want one file and should not have to know which. The button names
 * the platform it detected and downloads it; the caret opens the full list for
 * everyone else — a Mac user on a work Windows machine, someone grabbing the
 * Linux build for a server, or anyone who wants the browser extension.
 *
 * Before the API answers (or if it never does) the button is still a link to the
 * releases page, so the control is never dead.
 */
export default function DownloadMenu({ variant = "hero" }: { variant?: "hero" | "nav" }) {
  const [releases, setReleases] = useState<Release[] | null>(null);
  const [here, setHere] = useState<OsId | null>(null);
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);

  useEffect(() => {
    setHere(detectOs());
    let live = true;
    getReleases()
      .then((rs) => live && setReleases(rs))
      .catch(() => {});
    return () => {
      live = false;
    };
  }, []);

  // A menu that only closes on its own button is a trap on touch, and one that
  // ignores Escape is a trap for the keyboard.
  useEffect(() => {
    if (!open) return;
    const away = (e: MouseEvent) => {
      if (box.current && !box.current.contains(e.target as Node)) setOpen(false);
    };
    const key = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    document.addEventListener("mousedown", away);
    document.addEventListener("keydown", key);
    return () => {
      document.removeEventListener("mousedown", away);
      document.removeEventListener("keydown", key);
    };
  }, [open]);

  const mine = platform(here) ?? PLATFORMS[0];
  const href = releases ? assetFor(releases, mine) : null;
  const label = variant === "nav" ? "Download" : here ? `Download for ${mine.short}` : "Download";

  return (
    <div className={`dlmenu ${variant}`} ref={box}>
      <a
        className={variant === "hero" ? "btn primary" : "btn nav-dl"}
        href={href ?? `${REPO}/releases/latest`}
        onClick={(e) => href && startDownload(e, href, mine.id)}
      >
        {label}
      </a>
      <button
        type="button"
        className={variant === "hero" ? "btn primary caret" : "btn nav-dl caret"}
        aria-label="Other platforms"
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen(!open)}
      >
        <svg width="11" height="7" viewBox="0 0 11 7" aria-hidden="true">
          <path d="M1 1l4.5 4.5L10 1" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
        </svg>
      </button>

      {open ? (
        <div className="dlpanel" role="menu">
          {PLATFORMS.map((p) => {
            const url = releases ? assetFor(releases, p) : null;
            return (
              <a
                key={p.id}
                role="menuitem"
                href={url ?? `${REPO}/releases/latest`}
                onClick={(e) => {
                  setOpen(false);
                  if (url) startDownload(e, url, p.id);
                }}
              >
                <span className="os">{p.icon}</span>
                <span className="grow">
                  {p.short} <span className="meta">{p.meta}</span>
                </span>
                {p.id === here ? <span className="tag">yours</span> : null}
              </a>
            );
          })}
          <a role="menuitem" className="quiet" href={`${REPO}/releases`}>
            <span className="os">📦</span>
            <span className="grow">
              All files <span className="meta">checksums · older versions</span>
            </span>
          </a>
        </div>
      ) : null}
    </div>
  );
}
