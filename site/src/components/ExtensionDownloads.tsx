import { useEffect, useState } from "react";
import {
  PLATFORMS,
  REPO,
  countFor,
  fileFor,
  formatBytes,
  formatCount,
  getReleases,
  startDownload,
  type Release,
} from "../lib/releases";

/**
 * The two Opal Connect zips, next to what they are.
 *
 * They used to sit in the download section between the desktop builds, which
 * put the decision "do I want the browser extension?" a long way from the
 * screenshot that answers it. Same release, same shared platform table — only
 * the placement changed.
 */
const BROWSERS = PLATFORMS.filter((p) => p.id === "chrome" || p.id === "firefox");

export default function ExtensionDownloads() {
  const [releases, setReleases] = useState<Release[] | null>(null);

  useEffect(() => {
    let live = true;
    getReleases()
      .then((rs) => live && setReleases(rs))
      .catch(() => {});
    return () => {
      live = false;
    };
  }, []);

  return (
    <div className="extdl">
      {BROWSERS.map((p) => {
        const asset = releases ? fileFor(releases, p.files[0]) : null;
        const count = releases ? countFor(releases, p) : 0;
        return (
          <a
            key={p.id}
            className="file"
            href={asset?.browser_download_url ?? `${REPO}/releases`}
            onClick={(e) => asset && startDownload(e, asset.browser_download_url, p.id)}
          >
            <span className="os">{p.icon}</span>
            <b>{p.meta}</b>
            {asset ? <span className="size">{formatBytes(asset.size)}</span> : null}
            {count ? (
              <span className="count" title={`${count.toLocaleString()} downloads`}>
                {formatCount(count)}
              </span>
            ) : null}
          </a>
        );
      })}
    </div>
  );
}
