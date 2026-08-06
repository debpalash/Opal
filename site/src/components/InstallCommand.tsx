import { useState } from "react";

const INSTALL =
  "curl -fsSL https://raw.githubusercontent.com/debpalash/Opal/main/scripts/install.sh | sh";

/**
 * The install one-liner, with a copy button.
 *
 * An island rather than page script: the command itself is static content and
 * ships in the HTML, so it is readable and selectable before any JavaScript
 * runs. Only the button needs React.
 */
export default function InstallCommand() {
  const [label, setLabel] = useState("Copy");

  async function copy() {
    try {
      await navigator.clipboard.writeText(INSTALL);
      setLabel("Copied");
      setTimeout(() => setLabel("Copy"), 1600);
    } catch {
      // Clipboard access is permission-gated and blocked outright in some
      // contexts. Say what to do instead of failing silently.
      setLabel("Select it");
    }
  }

  return (
    <div className="oneliner">
      <code>{INSTALL}</code>
      <button className="copy" type="button" onClick={copy}>
        {label}
      </button>
    </div>
  );
}
