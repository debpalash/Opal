// Run with ego-browser nodejs -e 'await import("file:///path/to/Opal/scripts/readme-art/render.mjs")'
// Requires ego-browser, FFmpeg, and ImageMagick. Original captures stay untouched.
const fs = await import("node:fs/promises");
const path = await import("node:path");
const os = await import("node:os");
const { execFileSync } = await import("node:child_process");
const { fileURLToPath } = await import("node:url");
const root = fileURLToPath(new URL("../../", import.meta.url));
await fs.access(path.join(root, "scripts/readme-art/layout.html"));
const work = await fs.mkdtemp(path.join(os.tmpdir(), "opal-readme-"));
const output = path.join(root, "assets/readme");
await fs.mkdir(output, { recursive: true });
const task = await taskSpace("Opal README artwork");
console.log({ taskSpaceId: task.spaceId, work });
const page = task.page("p1");
for (const view of ["hero", "search", "player", "connect", "browse", "torrent", "ai"]) {
  await page.cdp("Emulation.setDeviceMetricsOverride", { width: 1600, height: 1400, deviceScaleFactor: 1, mobile: false });
  await page.goto("file://" + path.join(root, "scripts/readme-art/layout.html") + "?view=" + view);
  await page.evaluate(async () => {
    await document.fonts.ready;
    await Promise.all([...document.images].map(img => img.decode()));
    const background = new Image();
    background.src = new URL("../../assets/readme/opalescent.webp", location.href).href;
    await background.decode();
  });
  const geometry = await page.evaluate(() => {
    const stage = document.querySelector(".stage").getBoundingClientRect();
    const screen = document.querySelector(".screen").getBoundingClientRect();
    return { width: stage.width, height: stage.height, x: screen.x, y: screen.y, screenWidth: screen.width, screenHeight: screen.height };
  });
  const capture = path.join(work, view + ".png");
  await page.screenshot({ path: capture, clip: { x: 0, y: 0, width: geometry.width, height: geometry.height } });
  if (["browse", "torrent", "ai"].includes(view)) {
    // The original recording occupies the exact screen slot of the CSS window.
    const source = { browse: "browse", torrent: "stream-a-torrent", ai: "ask-the-ai" }[view];
    // Video changes every pixel; a smaller streaming preview keeps README loading practical.
    const fps = view === "torrent" ? 6 : 8;
    const width = view === "torrent" ? 800 : geometry.width;
    const filter = `[1:v]fps=${fps},scale=${geometry.screenWidth}:${geometry.screenHeight}:flags=lanczos[screen];[0:v][screen]overlay=${geometry.x}:${geometry.y}:shortest=1,scale=${width}:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle[out]`;
    execFileSync("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-loop", "1", "-framerate", String(fps), "-i", capture, "-i", path.join(root, "assets/media", source + ".mp4"), "-filter_complex", filter, "-map", "[out]", "-loop", "0", path.join(output, view + ".gif")]);
    console.log({ view, ...geometry });
  } else {
    execFileSync("magick", [capture, "-quality", "88", path.join(output, view + ".webp")]);
    console.log({ view, ...geometry });
  }
}
await task.finish({ keep: [] });
console.log("README artwork exported to " + output);
