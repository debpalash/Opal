import type { APIRoute } from "astro";
import { SITE_PAGES, absoluteUrl } from "../lib/site";

export const prerender = true;

export const GET: APIRoute = () => {
  const urls = SITE_PAGES.map(
    ({ path }) => `  <url>
    <loc>${absoluteUrl(path)}</loc>
    <changefreq>${path === "/" ? "weekly" : "monthly"}</changefreq>
    <priority>${path === "/" ? "1.0" : "0.8"}</priority>
  </url>`,
  ).join("\n");

  return new Response(
    `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`,
    { headers: { "Content-Type": "application/xml; charset=utf-8" } },
  );
};
