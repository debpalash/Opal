import { useEffect, useState } from "react";
import {
  PLATFORMS,
  REPO,
  assetFor,
  getReleases,
  newest,
  platform,
  type Platform,
} from "../lib/releases";

/**
 * The download-started page.
 *
 * Two jobs. First, a fallback: browsers block or lose a programmatic download
 * often enough that "it didn't start" needs a real link, and this page resolves
 * the same asset again to provide one. Second, the install steps — the macOS
 * quarantine dialog and the Firefox temporary-add-on flow are where people give
 * up, and the moment they need that is right after the file lands.
 *
 * `?os=` is untrusted input from the URL, so it is matched against the platform
 * table rather than interpolated anywhere.
 */
export default function ThanksPanel() {
  const [href, setHref] = useState<string | null>(null);
  const [tag, setTag] = useState<string | null>(null);
  const [os, setOs] = useState<Platform | null>(null);

  useEffect(() => {
    const want = new URLSearchParams(window.location.search).get("os");
    const p = platform(want) ?? null;
    setOs(p);
    let live = true;
    getReleases()
      .then((releases) => {
        if (!live) return;
        setTag(newest(releases)?.tag_name ?? null);
        if (p) setHref(assetFor(releases, p));
      })
      .catch(() => {});
    return () => {
      live = false;
    };
  }, []);

  const steps = os?.next ?? [];

  return (
    <>
      <p className="eyebrow">{os ? `${os.short}${tag ? ` · ${tag}` : ""}` : "Downloading"}</p>
      <h1>Your download is on its way.</h1>
      <p className="tagline">
        {href ? (
          <>
            Nothing happening? <a href={href}>Start it again</a>.
          </>
        ) : (
          <>
            Nothing happening? <a href={`${REPO}/releases/latest`}>Grab it from the releases page</a>.
          </>
        )}
      </p>

      {steps.length ? (
        <ol className="steps">
          {steps.map((s, i) => (
            <li key={i} dangerouslySetInnerHTML={{ __html: mark(s) }} />
          ))}
        </ol>
      ) : (
        <div className="dl">
          {PLATFORMS.map((p) => (
            <a key={p.id} href={`/thanks?os=${p.id}`}>
              <span className="os">{p.icon}</span>
              <span className="grow">
                {p.short} <span className="meta">{p.meta}</span>
              </span>
            </a>
          ))}
        </div>
      )}
    </>
  );
}

/** `code` spans only — the step strings are ours, not user input, but keeping
 *  the conversion to one narrow rule means it stays that way. */
function mark(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/`([^`]+)`/g, "<code>$1</code>");
}
