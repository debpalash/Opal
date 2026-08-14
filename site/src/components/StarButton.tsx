import { useEffect, useState } from "react";
import { REPO, formatCount, getRepoMeta } from "../lib/releases";

/**
 * GitHub star button with a live count.
 *
 * Deliberately not GitHub's own buttons.github.io widget: that one loads a
 * third-party frame with its own stylesheet on every visit, ignores the theme,
 * would be the only cross-origin request the page makes. This is a link and one
 * number, from a fetch the page already had a reason to make.
 */
export default function StarButton() {
  const [stars, setStars] = useState<number | null>(null);

  useEffect(() => {
    let live = true;
    getRepoMeta()
      .then((r) => live && typeof r?.stargazers_count === "number" && setStars(r.stargazers_count))
      .catch(() => {});
    return () => {
      live = false;
    };
  }, []);

  // Links to the repo itself, not /stargazers: the ask is "go star it", and the
  // stargazer list is a page about other people.
  return (
    <a className="star" href={REPO} title="Give Opal a star on GitHub">
      <svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
        <path
          fill="currentColor"
          d="M8 .8l2.2 4.5 5 .7-3.6 3.5.8 4.9L8 12.1l-4.4 2.3.8-4.9L.8 6l5-.7L8 .8z"
        />
      </svg>
      Star
      {stars !== null ? <span className="count">{formatCount(stars)}</span> : null}
    </a>
  );
}
