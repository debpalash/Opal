import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { REPO } from "./site";

/**
 * The changelog page is built from the repository's own CHANGELOG.md at build
 * time — the same file that feeds GitHub release notes — so the site can never
 * say something a release didn't. Headings are `## vX.Y.Z — YYYY-MM-DD`;
 * sections are bullets, occasionally plain paragraphs (v0.1.0).
 */

export type ChangelogRelease = {
  version: string;
  date: string; // YYYY-MM-DD, as written
  /** Each entry is a sanitised HTML fragment for one bullet. */
  items: string[];
  /** Sanitised HTML paragraphs for sections written as prose. */
  paragraphs: string[];
};

// The build is bundled before it runs, so import.meta.url points at a chunk,
// not this file. Walk up from wherever the build was started instead — the
// changelog sits at the repository root.
function findSource(): string {
  for (let dir = process.cwd(); ; dir = dirname(dir)) {
    const candidate = join(dir, "CHANGELOG.md");
    if (existsSync(candidate)) return candidate;
    if (dirname(dir) === dir) throw new Error("CHANGELOG.md not found above " + process.cwd());
  }
}
const HEADING = /^## v(\d+\.\d+\.\d+) — (\d{4}-\d{2}-\d{2})\s*$/;

function escapeHtml(text: string): string {
  return text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

/** The small markdown subset the changelog actually uses, escaped first. */
function inline(text: string): string {
  return escapeHtml(text)
    .replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>")
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2">$1</a>')
    .replace(/#(\d+)\b/g, `<a href="${REPO}/issues/$1">#$1</a>`);
}

export function loadChangelog(): ChangelogRelease[] {
  const releases: ChangelogRelease[] = [];
  let current: ChangelogRelease | null = null;
  // Raw text per entry, joined before rendering: bullets continue on
  // indented lines, paragraphs on flush ones.
  let bullet: string[] = [];
  let paragraph: string[] = [];

  const flush = () => {
    if (!current) return;
    if (bullet.length) current.items.push(inline(bullet.join(" ")));
    if (paragraph.length) current.paragraphs.push(inline(paragraph.join(" ")));
    bullet = [];
    paragraph = [];
  };

  for (const line of readFileSync(findSource(), "utf8").split("\n")) {
    const heading = line.match(HEADING);
    if (heading) {
      flush();
      current = { version: heading[1], date: heading[2], items: [], paragraphs: [] };
      releases.push(current);
      continue;
    }
    if (!current) continue; // the file's own preamble
    if (line.startsWith("- ")) {
      flush();
      bullet = [line.slice(2).trim()];
    } else if (/^\s+\S/.test(line) && bullet.length) {
      bullet.push(line.trim());
    } else if (line.trim() === "") {
      flush();
    } else {
      paragraph.push(line.trim());
    }
  }
  flush();
  return releases;
}

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

/** "2026-08-11" → "11 August 2026", with no Date object or timezone involved. */
export function humanDate(iso: string): string {
  const [y, m, d] = iso.split("-").map(Number);
  return `${d} ${MONTHS[m - 1]} ${y}`;
}
