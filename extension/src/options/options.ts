/**
 * Settings page: persist host / port / token / default-action to
 * chrome.storage.sync, live connection pill, "Test connection" that pings
 * /api/status through the background worker.
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
const defaultActionEl = document.getElementById("default-action") as HTMLSelectElement;
const form = document.getElementById("form") as HTMLFormElement;
const testBtn = document.getElementById("test") as HTMLButtonElement;
const revealBtn = document.getElementById("reveal") as HTMLButtonElement;
const result = document.getElementById("result") as HTMLDivElement;
const pill = document.getElementById("conn-pill") as HTMLDivElement;
const pillLabel = document.getElementById("conn-label") as HTMLSpanElement;

function show(kind: "ok" | "err", message: string): void {
  result.hidden = false;
  result.className = `result ${kind}`;
  result.textContent = message;
}

function setPill(kind: "ok" | "err" | "probing", label: string): void {
  pill.className = `pill ${kind}`;
  pillLabel.textContent = label;
}

async function load(): Promise<void> {
  const s = await getSettings();
  hostEl.value = s.host;
  portEl.value = String(s.port);
  tokenEl.value = s.token;
  defaultActionEl.value = s.defaultAction;
  hostEl.placeholder = DEFAULT_SETTINGS.host;
  portEl.placeholder = String(DEFAULT_SETTINGS.port);
  probe();
}

function read(): OpalSettings {
  return {
    host: hostEl.value.trim() || DEFAULT_SETTINGS.host,
    port: Number(portEl.value) || DEFAULT_SETTINGS.port,
    token: tokenEl.value.trim(),
    defaultAction: (defaultActionEl.value as OpalSettings["defaultAction"]) || "play",
  };
}

async function probe(): Promise<void> {
  setPill("probing", "Checking…");
  const res = (await chrome.runtime.sendMessage({ kind: "opal", action: "status" })) as OpalResponse;
  if (res.ok) setPill("ok", "Connected");
  else if (res.status === 401) setPill("err", "Token invalid");
  else setPill("err", "Not running");
}

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  await saveSettings(read());
  show("ok", "Saved.");
  probe();
});

defaultActionEl.addEventListener("change", async () => {
  await saveSettings(read());
});

testBtn.addEventListener("click", async () => {
  await saveSettings(read()); // test against what's currently typed
  show("ok", "Testing…");
  const res = (await chrome.runtime.sendMessage({ kind: "opal", action: "status" })) as OpalResponse;
  if (res.ok) {
    show("ok", "Connected to Opal ✓");
    setPill("ok", "Connected");
  } else if (res.status === 401) {
    show("err", "Reached Opal, but the token was rejected (401). Re-copy it from api.token.");
    setPill("err", "Token invalid");
  } else {
    show("err", res.error ?? "Could not reach Opal. Is the desktop app running?");
    setPill("err", "Not running");
  }
});

revealBtn.addEventListener("click", () => {
  const revealed = tokenEl.type === "text";
  tokenEl.type = revealed ? "password" : "text";
  revealBtn.textContent = revealed ? "Show" : "Hide";
});

load();
