import { useEffect, useState } from "react";
import { getReleases, newest } from "../lib/releases";

/**
 * "v0.7.0 · free & open source".
 *
 * Renders the licence line on the server and only adds the version once the API
 * answers — so the pill is never empty, never shifts layout by more than a few
 * characters, and a blocked api.github.com just leaves it as it started. Shares
 * its one fetch with the download grid, which is where the counts live.
 */
export default function ReleaseBadge() {
  const [tag, setTag] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    getReleases()
      .then((releases) => {
        if (live) setTag(newest(releases)?.tag_name ?? null);
      })
      .catch(() => {});
    return () => {
      live = false;
    };
  }, []);

  if (!tag) return <span className="pill">Free &amp; open source</span>;
  return (
    <span className="pill">
      <b>{tag}</b> · free &amp; open source
    </span>
  );
}
