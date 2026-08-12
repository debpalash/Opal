import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const dist = new URL("../dist/", import.meta.url);
const expected = ["/", "/features/", "/compare/", "/extension/", "/download/", "/faq/", "/privacy/"];
const requiredAssets = ["favicon.ico", "favicon.svg", "apple-touch-icon.png", "icon-192.png", "icon-512.png", "site.webmanifest", "robots.txt", "sitemap.xml"];
const errors = [];
const seenTitles = new Map();
const seenDescriptions = new Map();
const seenCanonicals = new Map();

const routeFile = (route) => new URL(
  route === "/" ? "index.html" : route === "/404/" ? "404.html" : `.${route}index.html`,
  dist,
);
const text = (url) => readFileSync(url, "utf8");
const matches = (html, pattern) => [...html.matchAll(pattern)];

if (!existsSync(dist)) errors.push("dist/ does not exist; run the build first");

for (const asset of requiredAssets) {
  const url = new URL(asset, dist);
  if (!existsSync(url) || statSync(url).size === 0) errors.push(`missing required asset: /${asset}`);
}

const sitemapUrl = new URL("sitemap.xml", dist);
if (existsSync(sitemapUrl)) {
  const sitemap = text(sitemapUrl);
  const listed = matches(sitemap, /<loc>([^<]+)<\/loc>/g).map((match) => new URL(match[1]).pathname);
  for (const route of expected) if (!listed.includes(route)) errors.push(`sitemap is missing ${route}`);
  for (const route of listed) if (!expected.includes(route)) errors.push(`unexpected sitemap route: ${route}`);
}

const builtRoutes = [...expected, "/thanks/", "/404/"];
for (const route of builtRoutes) {
  const file = routeFile(route);
  if (!existsSync(file)) {
    errors.push(`missing built page: ${route}`);
    continue;
  }

  const html = text(file);
  const noindex = /<meta[^>]+name="robots"[^>]+content="[^"]*noindex/i.test(html);
  const title = html.match(/<title>([^<]+)<\/title>/i)?.[1];
  const description = html.match(/<meta[^>]+name="description"[^>]+content="([^"]+)"/i)?.[1];
  const canonical = html.match(/<link[^>]+rel="canonical"[^>]+href="([^"]+)"/i)?.[1];
  const h1s = matches(html, /<h1(?:\s[^>]*)?>/gi).length;
  if (h1s !== 1) errors.push(`${route}: expected one h1, found ${h1s}`);
  if (!/<html[^>]+lang="en"/i.test(html)) errors.push(`${route}: missing html lang`);
  if (!/<title>[^<]{10,}[^<]*<\/title>/i.test(html)) errors.push(`${route}: missing or too-short title`);
  if (!/<meta[^>]+name="description"[^>]+content="[^"]{50,}"/i.test(html)) errors.push(`${route}: missing or too-short description`);
  if (!/<link[^>]+rel="canonical"[^>]+href="https:\/\/opal\.palash\.dev\//i.test(html)) errors.push(`${route}: missing absolute canonical`);
  if (!/<link[^>]+rel="icon"[^>]+href="\/favicon\.ico"/i.test(html)) errors.push(`${route}: missing ICO favicon`);
  if (!/<link[^>]+rel="manifest"[^>]+href="\/site\.webmanifest"/i.test(html)) errors.push(`${route}: missing web manifest`);
  if (!/<meta[^>]+property="og:image"[^>]+content="https:\/\//i.test(html)) errors.push(`${route}: missing absolute og:image`);
  if (!/<script[^>]+type="application\/ld\+json"/i.test(html)) errors.push(`${route}: missing JSON-LD`);
  if (!expected.includes(route) && !noindex) errors.push(`${route}: utility page must be noindex`);
  if (expected.includes(route) && noindex) errors.push(`${route}: sitemap page is noindex`);
  if (expected.includes(route)) {
    const expectedCanonical = `https://opal.palash.dev${route}`;
    if (canonical !== expectedCanonical) errors.push(`${route}: canonical is ${canonical ?? "missing"}, expected ${expectedCanonical}`);
    for (const [value, seen, label] of [[title, seenTitles, "title"], [description, seenDescriptions, "description"], [canonical, seenCanonicals, "canonical"]]) {
      if (!value) continue;
      const previous = seen.get(value);
      if (previous) errors.push(`${route}: duplicate ${label} also used by ${previous}`);
      seen.set(value, route);
    }
  }

  for (const match of matches(html, /<script[^>]+type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/gi)) {
    try { JSON.parse(match[1]); } catch { errors.push(`${route}: invalid JSON-LD`); }
  }

  for (const [tag] of matches(html, /<img\b[^>]*>/gi)) {
    if (!/\balt="[^"]*"/i.test(tag)) errors.push(`${route}: image without alt`);
    if (!/\bwidth="\d+"/i.test(tag) || !/\bheight="\d+"/i.test(tag)) errors.push(`${route}: image without dimensions`);
  }

  for (const [, href] of matches(html, /<a\b[^>]*\bhref="(\/[^"]*)"/gi)) {
    if (href.startsWith("//")) continue;
    const target = new URL(href, "https://opal.palash.dev");
    const targetRoute = target.pathname.endsWith("/") || /\.[a-z0-9]+$/i.test(target.pathname) ? target.pathname : `${target.pathname}/`;
    if (!/\.[a-z0-9]+$/i.test(targetRoute) && !existsSync(routeFile(targetRoute))) errors.push(`${route}: broken internal link ${href}`);
    if (target.pathname === route.replace(/index\.html$/, "") && target.hash) {
      const id = target.hash.slice(1).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      if (!new RegExp(`\\bid="${id}"`).test(html)) errors.push(`${route}: missing fragment target ${target.hash}`);
    }
  }
}

if (errors.length) {
  console.error(`SEO check failed (${errors.length}):\n${errors.map((error) => `  - ${error}`).join("\n")}`);
  process.exit(1);
}

console.log(`SEO check passed: ${expected.length} indexable routes, metadata, structured data, assets and internal links verified.`);
