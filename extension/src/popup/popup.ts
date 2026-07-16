/**
 * Popup UI: connection indicator + quick actions for the current tab.
 * All Opal traffic is delegated to the background worker via messages.
 */

import type { OpalRequest, OpalResponse } from "../shared";

const statusEl = document.getElementById("status") as HTMLDivElement;
const statusText = document.getElementById("status-text") as HTMLSpanElement;
const sendBtn = document.getElementById("send") as HTMLButtonElement;
const downloadBtn = document.getElementById("download") as HTMLButtonElement;
const optionsLink = document.getElementById("options") as HTMLAnchorElement;

function send(req: OpalRequest): Promise<OpalResponse> {
  return chrome.runtime.sendMessage(req) as Promise<OpalResponse>;
}

async function currentTabUrl(): Promise<string> {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab?.url ?? "";
}

async function refreshStatus(): Promise<void> {
  statusEl.className = "status probing";
  statusText.textContent = "Checking Opal…";
  const res = await send({ kind: "opal", action: "status" });
  if (res.ok) {
    statusEl.className = "status ok";
    statusText.textContent = "Opal connected ✓";
    sendBtn.disabled = false;
    downloadBtn.disabled = false;
  } else {
    statusEl.className = "status err";
    statusText.textContent =
      res.status === 401 ? "Token invalid — open Settings" : "Opal not running ✗";
    sendBtn.disabled = res.status === 401 ? true : false;
    downloadBtn.disabled = sendBtn.disabled;
  }
}

sendBtn.addEventListener("click", async () => {
  const url = await currentTabUrl();
  if (!url) return;
  sendBtn.textContent = "Sending…";
  await send({ kind: "opal", action: "open", url, notify: true, label: "Play" } as OpalRequest);
  sendBtn.textContent = "▶ Send current tab to Opal";
});

downloadBtn.addEventListener("click", async () => {
  const url = await currentTabUrl();
  if (!url) return;
  downloadBtn.textContent = "Sending…";
  await send({
    kind: "opal",
    action: "download",
    url,
    notify: true,
    label: "Download",
  } as OpalRequest);
  downloadBtn.textContent = "⬇ Download current tab";
});

optionsLink.addEventListener("click", (e) => {
  e.preventDefault();
  chrome.runtime.openOptionsPage();
});

refreshStatus();
