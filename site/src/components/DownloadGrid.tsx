import { useEffect, useState } from "react";
import {
  PLATFORMS,
  REPO,
  countFor,
  detectOs,
  fileFor,
  getReleases,
  formatBytes,
  formatCount,
  namedAsset,
  startDownload,
  type Asset,
  type OsId,
  type Release,
} from "../lib/releases";

/**
 * Every file a release ships, grouped by platform.
 *
 * A release is not one file per platform — macOS gets a .dmg, a portable
 * .app.zip and a bare tarball; Linux gets an AppImage, a .deb, an .rpm and a
 * tarball; Windows gets an installer and a portable zip. Offering only the first
 * of each sent anyone who wanted a .deb to the releases page to dig for it.
 *
 * Sizes come from the same release payload. On a phone or a metered connection
 * that number is the difference between "now" and "later".
 *
 * Everything degrades: before the API answers (or if it never does) each button
 * is a link to the releases page, and the section reads exactly the same.
 */
const DESKTOP = PLATFORMS.filter((p) => p.id !== "chrome" && p.id !== "firefox");

export default function DownloadGrid() {
  const [releases, setReleases] = useState<Release[] | null>(null);
  const [here, setHere] = useState<OsId | null>(null);

  useEffect(() => {
    setHere(detectOs());
    let live = true;
    // A rejected fetch leaves the fallback links standing rather than taking
    // the island down with it.
    getReleases()
      .then((rs) => live && setReleases(rs))
      .catch(() => {});
    return () => {
      live = false;
    };
  }, []);

  const sums = releases ? namedAsset(releases, "sha256sums") : null;

  return (
    <div className="dlgroups">
      {/* The two extension zips live with the screenshot that explains them,
          up in the Opal Connect section — not between the desktop builds. */}
      {DESKTOP.map((p) => {
        const count = releases ? countFor(releases, p) : 0;
        return (
          <div key={p.id} className={`dlgroup${here === p.id ? " yours" : ""}`} data-os={p.id}>
            <div className="head">
              <span className="os">{p.icon}</span>
              <span className="grow">
                {p.title} <span className="meta">{p.meta}</span>
              </span>
              {here === p.id ? <span className="tag">your platform</span> : null}
              {count ? (
                <span className="count" title={`${count.toLocaleString()} downloads`}>
                  {formatCount(count)}
                </span>
              ) : null}
            </div>
            <div className="files">
              {p.files.map((f) => {
                const a: Asset | null = releases ? fileFor(releases, f) : null;
                return (
                  <a
                    key={f.label}
                    className="file"
                    href={a?.browser_download_url ?? `${REPO}/releases`}
                    onClick={(e) => a && startDownload(e, a.browser_download_url, p.id)}
                  >
                    <b>{f.label}</b>
                    <span className="hint">{f.hint}</span>
                    {a ? <span className="size">{formatBytes(a.size)}</span> : null}
                  </a>
                );
              })}
            </div>
          </div>
        );
      })}

      {/* Not files — but this is where someone looks for them. */}
      <div className="dlgroup">
        <div className="head">
          <span className="os">📦</span>
          <span className="grow">
            Package managers <span className="meta">installs and updates in place</span>
          </span>
        </div>
        <div className="files pkgs">
          <code>brew install debpalash/tap/opal</code>
          <code>yay -S opal-bin</code>
        </div>
      </div>

      <div className="dlgroup">
        <div className="head">
          <span className="os">🔎</span>
          <span className="grow">
            Verify and browse <span className="meta">checksums, older versions, notes</span>
          </span>
        </div>
        <div className="files">
          <a className="file" href={sums?.browser_download_url ?? `${REPO}/releases`}>
            <b>SHA256SUMS.txt</b>
            <span className="hint">verify your file</span>
          </a>
          <a className="file" href={`${REPO}/releases`}>
            <b>All releases</b>
            <span className="hint">every version</span>
          </a>
          <a className="file" href={`${REPO}/blob/main/CHANGELOG.md`}>
            <b>Changelog</b>
            <span className="hint">what changed</span>
          </a>
        </div>
      </div>
    </div>
  );
}
