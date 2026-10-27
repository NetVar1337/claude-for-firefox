<p align="center">
  <img src="icon-128.png" width="80" height="80" alt="Claude for Firefox">
</p>

<h1 align="center">Claude for Firefox</h1>

<p align="center">
  <strong>A helping hand across all your tabs — now in Firefox.</strong>
</p>

<p align="center">
  Community port of Anthropic's <a href="https://claude.com/claude-for-chrome">Claude browser extension</a> for Firefox.<br>
  Full feature parity with Claude for Chrome — sidebar chat, browser automation, Claude Code integration.
</p>

<p align="center">
  <a href="#installation"><img src="https://img.shields.io/badge/Firefox-128%2B-FF7139?style=flat&logo=firefox-browser&logoColor=white" alt="Firefox 128+"></a>
  <a href="https://github.com/VoidChecksum/claude-for-firefox/blob/main/manifest.json"><img src="https://img.shields.io/badge/Manifest-V3-blue?style=flat" alt="Manifest V3"></a>
  <a href="#claude-code-integration"><img src="https://img.shields.io/badge/Claude_Code-integrated-cc8833?style=flat" alt="Claude Code"></a>
  <a href="#installation"><img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-999?style=flat" alt="Cross-platform"></a>
</p>

---

## What it does

Claude for Firefox lets Claude work directly in your browser. Open the sidebar, describe what you need, and Claude navigates websites, clicks buttons, fills forms, and runs multi-step workflows — all through natural conversation.

| Capability | Description |
|---|---|
| **Sidebar chat** | Talk to Claude while browsing any website |
| **Browser automation** | Navigate, click, type, and fill forms |
| **Claude Code integration** | Build in terminal, test in browser — seamless loop |
| **Claude Desktop / Cowork** | Start a task in Desktop, let it handle work in the browser |
| **Scheduled tasks** | Set recurring browser workflows that run automatically |
| **Multi-tab workflows** | Claude works across multiple tabs simultaneously |
| **Page reading** | Accessibility tree extraction for understanding page content |
| **Visual indicators** | Glowing border, phantom cursor, and stop button during agent actions |

---

## Installation

### Prerequisites

- **Firefox 128** or later
- **Claude Code** installed and signed in — `claude --version` to verify
- **Node.js 18+** — provides `npx` for the [web-ext](https://github.com/nichochar/web-ext) launcher

### macOS / Linux

```bash
git clone https://github.com/VoidChecksum/claude-for-firefox.git
cd claude-for-firefox
./install.sh
```

### Windows

```powershell
git clone https://github.com/VoidChecksum/claude-for-firefox.git
cd claude-for-firefox
powershell -ExecutionPolicy Bypass -File install.ps1
```

The installer handles everything:

1. Copies extension files to `~/.claude/firefox/extension/`
2. Registers native messaging hosts for Claude Code and Claude Desktop
3. Bootstraps OAuth tokens from your Claude Code session
4. Creates a launcher script (and a macOS app / Linux .desktop entry)

---

## Usage

### Launch

```bash
# macOS / Linux
~/.claude/firefox/launch.sh

# Windows
%USERPROFILE%\.claude\firefox\launch.bat

# Or use the macOS app
open ~/Applications/Claude\ Firefox.app
```

Alternatively, load manually: navigate to `about:debugging#/runtime/this-firefox`, click **Load Temporary Add-on**, and select `manifest.json` from `~/.claude/firefox/extension/`.

### Keyboard shortcut

**Cmd+E** (macOS) or **Ctrl+E** (Linux / Windows) toggles the Claude sidebar.

Or open it via the menu: **View > Sidebar > Claude**.

---

## Claude Code Integration

Claude Code discovers the extension automatically through native messaging — no extra configuration needed.

The installer registers two native messaging hosts:

| Host | Purpose |
|---|---|
| `com.anthropic.claude_code_browser_extension` | Claude Code build-test-fix loop |
| `com.anthropic.claude_browser_extension` | Claude Desktop / Cowork browser control |

Both point to the same wrapper script that runs `claude --chrome-native-host`. The flag name says "chrome" but the protocol is browser-agnostic — it works identically for Firefox.

### How discovery works

```
Firefox extension                              Claude Code
      |                                             |
      |-- connectNative("com.anthropic              |
      |     .claude_code_browser_extension") ------->|
      |                                             |
      |<-- ping/pong --------------------------------|
      |                                             |
      |<-- tool_request (navigate, click, ...) ------|
      |                                             |
      |-- tool_response ---------------------------->|
```

The native host creates a Unix socket at `/tmp/claude-mcp-browser-bridge-{user}/` for MCP communication. Claude Code connects to this socket to execute browser tools — navigation, screenshots, form filling, console log reading, and more.

---

## How it works

Firefox does not support all Chrome extension APIs. This port includes a compatibility layer that bridges the gaps transparently:

| Chrome API | Firefox replacement | Implementation |
|---|---|---|
| `chrome.sidePanel` | `browser.sidebarAction` | `firefox-compat.js` |
| `chrome.tabGroups` | Storage-backed virtual groups | `firefox-compat.js` |
| `chrome.offscreen` | Background page (no-op shim) | `firefox-offscreen-shim.js` |
| `chrome.debugger` | `scripting.executeScript` fallback | `firefox-compat.js` |
| `chrome.identity` | Token bootstrap from Claude Code | `firefox-token-injector.js` |
| `externally_connectable` | Content script message relay | `firefox-claude-ai-bridge.js` |
| Service Worker | Background event page (module) | `firefox-bg-loader.js` |

### OAuth

Anthropic's OAuth server only accepts `chrome-extension://` redirect URIs, which Firefox cannot produce. Instead of the browser OAuth flow, the installer reads tokens from Claude Code's existing authenticated session (stored in the OS keychain) and injects them into the extension's storage. A periodic refresh check keeps them current.

---

## Token refresh

Tokens bootstrapped from Claude Code expire periodically. When authentication errors appear in the sidebar, refresh them:

```bash
# macOS / Linux
~/.claude/firefox/refresh-tokens.sh

# Windows
powershell -File %USERPROFILE%\.claude\firefox\refresh-tokens.ps1
```

This reads current tokens from Claude Code's credential store and writes them to `firefox-injected-tokens.json`. The extension picks up new tokens automatically.

---

## Known limitations

- **Tab groups are virtual.** Firefox has no tab group API. Groups are tracked internally for the extension's logic but do not appear as visual groupings in the tab bar.
- **Debugger API is limited.** Actions that rely on Chrome DevTools Protocol use `scripting.executeScript` as a fallback, which covers most use cases but may behave differently for advanced DOM inspection.
- **Temporary extension.** Firefox release builds require signed extensions. The extension loads as a temporary add-on via `web-ext` and needs to be reloaded on Firefox restart.
- **OAuth is indirect.** Tokens come from Claude Code's session rather than a direct browser OAuth flow. You must have Claude Code installed and signed in.

---

## Troubleshooting

| Problem | Solution |
|---|---|
| Sidebar doesn't appear | Check Firefox 128+. Open `about:debugging` for load errors. Verify `manifest.json` exists. |
| "Native messaging host not found" | Re-run the installer. Check the NMH directory for your OS (see table below). |
| Authentication errors | Run `refresh-tokens.sh`. Make sure Claude Code is signed in (`claude` in terminal). |
| Agent actions fail | Some sites block content script injection. Check browser console (Ctrl+Shift+J). |
| `web-ext` errors | Ensure Node.js 18+ is installed. Run `npx web-ext lint` to check for manifest issues. |

**Native messaging host directories:**

| OS | Path |
|---|---|
| macOS | `~/Library/Application Support/Mozilla/NativeMessagingHosts/` |
| Linux | `~/.mozilla/native-messaging-hosts/` |
| Windows | Registry: `HKCU\Software\Mozilla\NativeMessagingHosts\{name}` |

---

## Project structure

```
claude-for-firefox/
  manifest.json                  Firefox MV3 manifest
  install.sh                     macOS/Linux installer
  install.ps1                    Windows installer
  firefox-bg-loader.js           Background script entry point
  firefox-compat.js              Chrome -> Firefox API shim layer
  firefox-compat-content.js      Content script shim (minimal)
  firefox-token-injector.js      Token lifecycle manager
  firefox-oauth-interceptor.js   chrome-extension:// URL interceptor
  firefox-action-handler.js      Toolbar button -> sidebar toggle
  firefox-offscreen-shim.js      Audio playback shim
  firefox-claude-ai-bridge.js    claude.ai message relay
  oauth_callback.html            OAuth callback page
  sidepanel.html                 Sidebar UI
  options.html                   Extension options
  pairing.html                   Claude Desktop pairing
  assets/                        JS, CSS, fonts (from Chrome v1.0.70)
  i18n/                          11 languages
  sounds/                        Notification audio
```

---

## Contributing

Contributions welcome. Open an issue before large changes to discuss the approach.

When submitting a pull request:

1. Run `npx web-ext lint` — no errors.
2. Test on at least one platform (macOS, Linux, or Windows).
3. Do not commit credentials, tokens, or personal paths.
4. The `firefox-injected-tokens.json` file is gitignored — never include it.

---

## License

Extension assets are from Anthropic's [Claude browser extension](https://claude.com/claude-for-chrome) (v1.0.70). The Firefox compatibility layer, installers, and native messaging host setup are community-contributed under the MIT license.

This is an unofficial community project and is not affiliated with or endorsed by Anthropic.

---

## Running alongside Claude for Chrome

Claude Code's built-in `claude --chrome-native-host` listens on one fixed pipe per user, so a second browser cannot share it, and the claude.ai bridge rejects the `moz-extension://` origin. The installer therefore bundles its own native host (`native/firefox-host.mjs`, own pipe `claude-firefox-bridge-<user>`) and an MCP server (`native/firefox-mcp.mjs`) that it registers with Claude Code as `firefox`.

Chrome keeps using the `claude-in-chrome` tools; Firefox is driven with `mcp__firefox__*` tools (`tabs_context_mcp`, `navigate`, `computer`, `read_page`, `find`, `get_page_text`, `javascript_tool`, ...) which take the same arguments. Both can be used in the same session.

The Firefox host logs to `~/.claude/firefox/host.log`.
