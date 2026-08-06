// @ts-check
import { defineConfig } from "astro/config";
import react from "@astrojs/react";

// Static output: the page is content plus two small interactive bits, so
// everything ships as HTML and only the islands carry JavaScript. Cloudflare
// Pages serves `dist/` directly — no adapter, no server, nothing to keep alive.
export default defineConfig({
  site: "https://opal.palash.dev",
  output: "static",
  integrations: [react()],
  build: { inlineStylesheets: "auto" },
});
