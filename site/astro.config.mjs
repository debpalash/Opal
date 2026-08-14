// @ts-check
import { defineConfig } from "astro/config";
import react from "@astrojs/react";
import tailwindcss from "@tailwindcss/vite";

// Static output: the page is content plus two small interactive bits, so
// everything ships as HTML and only the islands carry JavaScript. Cloudflare
// Pages serves `dist/` directly — no adapter, no server, nothing to keep alive.
export default defineConfig({
  site: "https://opal.palash.dev",
  output: "static",
  integrations: [react()],
  // Tailwind is here for registry components (react-bits / shadcn), which are
  // written in utility classes. See src/styles/tailwind.css — Preflight is off
  // so it cannot restyle the hand-written pages.
  vite: { plugins: [tailwindcss()] },
  build: { inlineStylesheets: "auto" },
});
