/**
 * Setup + settings.
 *
 * Setup is the whole point of this page now. It used to be a form whose first
 * field was an API token you had to find yourself, in a file whose path differs
 * per OS, in an app you had already opened — the single worst step in using the
 * extension. It is now: press "Search for Opal", sign in with the account you
 * already have. The token never appears.
 *
 * The three calls setup makes (/health, /api/auth/status, /api/auth/login) are
 * the only unauthenticated ones the server has, precisely because a browser
 * cannot otherwise bootstrap. Pasting a token is still here, one disclosure
 * down, because automation users have one and headless boxes may have no
 * account yet.
 */

import {
  DEFAULT_SETTINGS,
  DISCOVERY_TARGETS,
  getSettings,
  isLoopback,
  saveSettings,
  type OpalAuthStatus,
  type OpalResponse,
  type OpalSettings,
} from "../shared";

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

const hostEl = $<HTMLInputElement>("host");
const portEl = $<HTMLInputElement>("port");
const tokenEl = $<HTMLInputElement>("token");
const usernameEl = $<HTMLInputElement>("username");
const passwordEl = $<HTMLInputElement>("password");
const setupCodeEl = $<HTMLInputElement>("setup-code");
const setupCodeField = $<HTMLElement>("setup-code-field");
const defaultActionEl = $<HTMLSelectElement>("default-action");
const discoverBtn = $<HTMLButtonElement>("discover");
const discoverStatus = $<HTMLElement>("discover-status");
const signinBtn = $<HTMLButtonElement>("signin");
const saveTokenBtn = $<HTMLButtonElement>("save-token");
const testBtn = $<HTMLButtonElement>("test");
const disconnectBtn = $<HTMLButtonElement>("disconnect");
const revealBtn = $<HTMLButtonElement>("reveal");
const setupSection = $<HTMLElement>("setup");
const connectedSection = $<HTMLElement>("connected");
const authTitle = $<HTMLElement>("auth-title");
const authHelp = $<HTMLElement>("auth-help");
const setupResult = $<HTMLDivElement>("setup-result");
const result = $<HTMLDivElement>("result");
const pill = $<HTMLDivElement>("conn-pill");
const pillLabel = $<HTMLSpanElement>("conn-label");
const versionEl = $<HTMLSpanElement>("version");

/** True once /api/auth/status says no account exists — step 2 then CREATES one
 *  rather than asking for credentials that do not exist yet. */
let needsAccount = false;

function show(el: HTMLDivElement, kind: "ok" | "err", message: string): void {
  el.hidden = false;
  el.className = `result ${kind}`;
  el.textContent = message;
}

function setPill(kind: "ok" | "err" | "probing", label: string): void {
  pill.className = `pill ${kind}`;
  pillLabel.textContent = label;
}

function target(): { host: string; port: number } {
  return {
    host: hostEl.value.trim() || DEFAULT_SETTINGS.host,
    port: Number(portEl.value) || DEFAULT_SETTINGS.port,
  };
}

async function currentSettings(): Promise<OpalSettings> {
  const s = await getSettings();
  const t = target();
  return { ...s, host: t.host, port: t.port };
}

function bg(msg: Record<string, unknown>): Promise<OpalResponse> {
  return chrome.runtime.sendMessage({ kind: "opal", ...msg }) as Promise<OpalResponse>;
}

// ── Step 1: find a running Opal ──────────────────────────────────────────────

async function discover(): Promise<void> {
  discoverBtn.disabled = true;
  discoverStatus.textContent = "Looking…";
  // Typed host first, then the usual suspects. Probing /health costs nothing
  // and needs no token, so this can just try until something answers.
  const typed = target();
  const candidates = [typed, ...DISCOVERY_TARGETS.filter(
    (c) => !(c.host === typed.host && c.port === typed.port),
  )];
  for (const c of candidates) {
    const res = await bg({ action: "probe", host: c.host, port: c.port });
    if (res.ok) {
      hostEl.value = c.host;
      portEl.value = String(c.port);
      discoverStatus.textContent = `Found Opal at ${c.host}:${c.port}.`;
      discoverStatus.className = "step-status ok";
      discoverBtn.disabled = false;
      await refreshAuthMode();
      return;
    }
  }
  discoverStatus.className = "step-status err";
  discoverStatus.textContent =
    "No Opal answered. Start the app, then turn on Settings → Web Remote.";
  discoverBtn.disabled = false;
}

/** Ask the server whether it has any account yet, and relabel step 2 to match. */
async function refreshAuthMode(): Promise<void> {
  const t = target();
  const res = await bg({ action: "authStatus", host: t.host, port: t.port });
  const data = res.ok ? (res.data as OpalAuthStatus | undefined) : undefined;
  needsAccount = !!data?.needs_setup;
  if (needsAccount) {
    authTitle.textContent = "Create your account";
    authHelp.textContent =
      "This Opal has no account yet. Enter its one-time setup code to create the admin account.";
    passwordEl.autocomplete = "new-password";
    setupCodeField.hidden = false;
    signinBtn.textContent = "Create account & connect";
  } else {
    authTitle.textContent = "Sign in";
    authHelp.textContent = "Use the account you created in Opal.";
    passwordEl.autocomplete = "current-password";
    setupCodeField.hidden = true;
    signinBtn.textContent = "Connect";
  }
}

// ── Step 2: sign in (or register) and keep the token ────────────────────────

/** A non-loopback host is outside the manifest's granted origins, so fetch()
 *  would fail with a network error that looks exactly like "Opal is down".
 *  Ask for the permission up front instead. */
async function ensureHostPermission(host: string): Promise<boolean> {
  if (isLoopback(host)) return true;
  const origins = [`http://${host}/*`];
  try {
    if (await chrome.permissions.contains({ origins })) return true;
    return await chrome.permissions.request({ origins });
  } catch {
    return false;
  }
}

async function connect(): Promise<void> {
  const t = target();
  const username = usernameEl.value.trim();
  const password = passwordEl.value;
  if (!username || !password) {
    show(setupResult, "err", "Enter a username and password.");
    return;
  }
  const setupToken = setupCodeEl.value.trim();
  if (needsAccount && !/^[0-9a-f]{64}$/.test(setupToken)) {
    show(setupResult, "err", "Enter the 64-character lowercase setup code from Opal.");
    return;
  }
  if (!(await ensureHostPermission(t.host))) {
    show(setupResult, "err", `The browser did not grant access to ${t.host}.`);
    return;
  }
  signinBtn.disabled = true;
  show(setupResult, "ok", needsAccount ? "Creating account…" : "Signing in…");
  const res = await bg({
    action: needsAccount ? "register" : "login",
    host: t.host,
    port: t.port,
    username,
    password,
    setupToken,
  });
  signinBtn.disabled = false;

  const token = res.ok ? ((res.data as { token?: string } | undefined)?.token ?? "") : "";
  if (!token) {
    const err = (res.data as { error?: string } | undefined)?.error;
    show(setupResult, "err", err || res.error || "Could not sign in.");
    return;
  }
  await saveSettings({ ...(await currentSettings()), token });
  passwordEl.value = "";
  setupCodeEl.value = "";
  show(setupResult, "ok", "Connected ✓");
  await probe();
}

async function saveToken(): Promise<void> {
  const t = target();
  const token = tokenEl.value.trim();
  if (!token) {
    show(setupResult, "err", "Paste a token first.");
    return;
  }
  if (!(await ensureHostPermission(t.host))) {
    show(setupResult, "err", `The browser did not grant access to ${t.host}.`);
    return;
  }
  await saveSettings({ ...(await currentSettings()), token });
  await probe();
  show(setupResult, "ok", "Saved.");
}

// ── Connection state ────────────────────────────────────────────────────────

async function probe(): Promise<void> {
  setPill("probing", "Checking…");
  const s = await getSettings();
  if (!s.token) {
    setPill("err", "Not connected");
    setConnected(false);
    return;
  }
  const res = await bg({ action: "status" });
  if (res.ok) {
    setPill("ok", "Connected");
    setConnected(true);
  } else if (res.status === 401) {
    // A revoked session or a rotated token — the credentials are stale, so put
    // setup back rather than leaving a dead "Connected" page.
    setPill("err", "Sign-in expired");
    setConnected(false);
  } else {
    setPill("err", "Not running");
    setConnected(false);
  }
}

function setConnected(on: boolean): void {
  setupSection.hidden = on;
  connectedSection.hidden = !on;
}

async function load(): Promise<void> {
  const s = await getSettings();
  hostEl.value = s.host;
  portEl.value = String(s.port);
  tokenEl.value = s.token;
  defaultActionEl.value = s.defaultAction;
  hostEl.placeholder = DEFAULT_SETTINGS.host;
  portEl.placeholder = String(DEFAULT_SETTINGS.port);
  versionEl.textContent = `v${chrome.runtime.getManifest().version}`;
  await probe();
  // No token yet: get the first step out of the way before the user reads
  // anything — in the common case (Opal running locally) it just finds it.
  if (!s.token) discover();
}

// ── Wiring ──────────────────────────────────────────────────────────────────

discoverBtn.addEventListener("click", discover);
signinBtn.addEventListener("click", connect);
saveTokenBtn.addEventListener("click", saveToken);
passwordEl.addEventListener("keydown", (e) => {
  if (e.key === "Enter") needsAccount ? setupCodeEl.focus() : connect();
});
setupCodeEl.addEventListener("keydown", (e) => {
  if (e.key === "Enter") connect();
});

defaultActionEl.addEventListener("change", async () => {
  const s = await getSettings();
  await saveSettings({
    ...s,
    defaultAction: (defaultActionEl.value as OpalSettings["defaultAction"]) || "play",
  });
});

testBtn.addEventListener("click", async () => {
  show(result, "ok", "Testing…");
  const res = await bg({ action: "status" });
  if (res.ok) {
    show(result, "ok", "Connected to Opal ✓");
    setPill("ok", "Connected");
  } else if (res.status === 401) {
    show(result, "err", "Reached Opal, but the credentials were rejected. Connect again.");
    setPill("err", "Sign-in expired");
    setConnected(false);
  } else {
    show(result, "err", res.error ?? "Could not reach Opal. Is the desktop app running?");
    setPill("err", "Not running");
  }
});

disconnectBtn.addEventListener("click", async () => {
  const s = await getSettings();
  await saveSettings({ ...s, token: "" });
  tokenEl.value = "";
  setConnected(false);
  setPill("err", "Not connected");
  refreshAuthMode();
});

revealBtn.addEventListener("click", () => {
  const revealed = tokenEl.type === "text";
  tokenEl.type = revealed ? "password" : "text";
  revealBtn.textContent = revealed ? "Show" : "Hide";
});

load();
