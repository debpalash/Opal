/**
 * Options page: persist host / port / token to chrome.storage.sync and offer a
 * "Test connection" that pings /api/status through the background worker.
 */

import {
  DEFAULT_SETTINGS,
  getSettings,
  saveSettings,
  type OpalResponse,
  type OpalSettings,
} from "../shared";

const hostEl = document.getElementById("host") as HTMLInputElement;
const portEl = document.getElementById("port") as HTMLInputElement;
const tokenEl = document.getElementById("token") as HTMLInputElement;
const form = document.getElementById("form") as HTMLFormElement;
const testBtn = document.getElementById("test") as HTMLButtonElement;
const revealBtn = document.getElementById("reveal") as HTMLButtonElement;
const result = document.getElementById("result") as HTMLDivElement;

function show(kind: "ok" | "err", message: string): void {
  result.hidden = false;
  result.className = `result ${kind}`;
  result.textContent = message;
}

async function load(): Promise<void> {
  const s = await getSettings();
  hostEl.value = s.host;
  portEl.value = String(s.port);
  tokenEl.value = s.token;
  hostEl.placeholder = DEFAULT_SETTINGS.host;
  portEl.placeholder = String(DEFAULT_SETTINGS.port);
}

function read(): OpalSettings {
  return {
    host: hostEl.value.trim() || DEFAULT_SETTINGS.host,
    port: Number(portEl.value) || DEFAULT_SETTINGS.port,
    token: tokenEl.value.trim(),
  };
}

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  await saveSettings(read());
  show("ok", "Saved.");
});

testBtn.addEventListener("click", async () => {
  await saveSettings(read()); // test against what's currently typed
  show("ok", "Testing…");
  const res = (await chrome.runtime.sendMessage({
    kind: "opal",
    action: "status",
  })) as OpalResponse;
  if (res.ok) {
    show("ok", "Connected to Opal ✓");
  } else if (res.status === 401) {
    show("err", "Reached Opal, but the token was rejected (401). Re-copy it from api.token.");
  } else {
    show("err", res.error ?? "Could not reach Opal. Is the desktop app running?");
  }
});

revealBtn.addEventListener("click", () => {
  const revealed = tokenEl.type === "text";
  tokenEl.type = revealed ? "password" : "text";
  revealBtn.textContent = revealed ? "Show token" : "Hide token";
});

load();
