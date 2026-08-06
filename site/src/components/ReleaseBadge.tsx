import { useEffect, useState } from "react";

/**
 * "v0.6.4 · free & open source".
 *
 * Renders the licence line on the server and only adds the version once the
 * API answers — so the pill is never empty, never shifts layout by more than a
 * few characters, and a blocked api.github.com just leaves it as it started.
 */
export default function ReleaseBadge() {
  const [tag, setTag] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    fetch("https://api.github.com/repos/debpalash/Opal/releases/latest")
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
      .then((rel: { tag_name?: string }) => {
        if (live && rel.tag_name) setTag(rel.tag_name);
      })
      .catch(() => {});
    return () => {
      live = false;
    };
  }, []);

  return (
    <span className="pill">
      {tag ? <b>{tag}</b> : <b>Free &amp; open source</b>}
      {tag ? " · free & open source" : ""}
    </span>
  );
}
