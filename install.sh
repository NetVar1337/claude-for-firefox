#!/usr/bin/env bash
# Claude for Firefox — Installer (macOS + Linux)
# chmod +x install.sh
set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()  { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
die()   { err "$@"; exit 1; }
banner(){ printf "\n${BOLD}── %s ──${NC}\n\n" "$*"; }

# ── Constants ───────────────────────────────────────────────────────────────
EXT_ID="claude-for-firefox@anthropic.community"
CHROME_EXT_ID="fcoeoabgfenejglbffodgkkbkcdhcgfn"
NMH_NAME_BROWSER="com.anthropic.claude_browser_extension"
NMH_NAME_CODE="com.anthropic.claude_code_browser_extension"
INSTALL_DIR="$HOME/.claude/firefox"
EXT_DIR="$INSTALL_DIR/extension"

# ── OS Detection ────────────────────────────────────────────────────────────
detect_os() {
    case "$(uname -s)" in
        Darwin) OS="macos" ;;
        Linux)  OS="linux" ;;
        *)      die "Unsupported OS: $(uname -s). This installer supports macOS and Linux." ;;
    esac
    info "Detected OS: $OS"
}

# ── NMH Directory ───────────────────────────────────────────────────────────
set_nmh_dir() {
    case "$OS" in
        macos) NMH_DIR="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts" ;;
        linux) NMH_DIR="$HOME/.mozilla/native-messaging-hosts" ;;
    esac
}

# ── Find Claude Code Binary ────────────────────────────────────────────────
find_claude() {
    if [[ -n "${CLAUDE_CODE_BIN:-}" ]] && [[ -x "$CLAUDE_CODE_BIN" ]]; then
        CLAUDE_BIN="$CLAUDE_CODE_BIN"
        info "Using CLAUDE_CODE_BIN override: $CLAUDE_BIN"
        return
    fi

    # 1. which claude
    if command -v claude &>/dev/null; then
        CLAUDE_BIN="$(command -v claude)"
        info "Found claude in PATH: $CLAUDE_BIN"
        return
    fi

    # 2. ~/.local/share/claude/versions/*
    local versions_dir="$HOME/.local/share/claude/versions"
    if [[ -d "$versions_dir" ]]; then
        local latest
        latest="$(find "$versions_dir" -maxdepth 2 -name claude -type f -perm +111 2>/dev/null | sort -V | tail -1 || true)"
        if [[ -n "$latest" && -x "$latest" ]]; then
            CLAUDE_BIN="$latest"
            info "Found claude in versions dir: $CLAUDE_BIN"
            return
        fi
    fi

    # 3. /usr/local/bin/claude
    if [[ -x /usr/local/bin/claude ]]; then
        CLAUDE_BIN="/usr/local/bin/claude"
        info "Found claude at /usr/local/bin/claude"
        return
    fi

    die "Claude Code not found. Install it first or set CLAUDE_CODE_BIN env var."
}

# ── Find Firefox ────────────────────────────────────────────────────────────
find_firefox() {
    case "$OS" in
        macos)
            if [[ -d "/Applications/Firefox.app" ]]; then
                FIREFOX_BIN="/Applications/Firefox.app/Contents/MacOS/firefox"
                info "Found Firefox at /Applications/Firefox.app"
            elif [[ -d "$HOME/Applications/Firefox.app" ]]; then
                FIREFOX_BIN="$HOME/Applications/Firefox.app/Contents/MacOS/firefox"
                info "Found Firefox at ~/Applications/Firefox.app"
            else
                die "Firefox not found. Install Firefox first."
            fi
            ;;
        linux)
            # Any Gecko browser works (Zen, LibreWolf, ...); FIREFOX_BIN overrides.
            FIREFOX_BIN="${FIREFOX_BIN:-$(command -v firefox || command -v zen-browser || command -v zen || command -v librewolf || true)}"
            [[ -x "$FIREFOX_BIN" ]] || die "Firefox (or Gecko fork) not found. Install one or set FIREFOX_BIN."
            info "Found browser: $FIREFOX_BIN"
            ;;
    esac
}

# ── Inject OAuth Tokens ────────────────────────────────────────────────────
inject_tokens() {
    banner "Injecting OAuth Tokens"

    local raw_creds=""
    case "$OS" in
        macos)
            raw_creds="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null || true)"
            ;;
        linux)
            raw_creds="$(secret-tool lookup service 'Claude Code-credentials' 2>/dev/null || true)"
            # Claude Code on Linux usually stores credentials in a file, not the keyring
            [[ -z "$raw_creds" && -f "$HOME/.claude/.credentials.json" ]] && raw_creds="$(<"$HOME/.claude/.credentials.json")"
            ;;
    esac

    if [[ -z "$raw_creds" ]]; then
        warn "Could not read Claude Code credentials from system keychain."
        warn "Run 'claude' at least once to log in, then re-run this installer"
        warn "  or run ~/.claude/firefox/refresh-tokens.sh later."
        return 0
    fi

    # Parse the OAuth JSON and extract just what we need
    local access_token refresh_token expires_at
    access_token="$(printf '%s' "$raw_creds" | python3 -c "
import sys, json
d = json.load(sys.stdin)
o = d.get('claudeAiOauth', {})
print(o.get('accessToken', ''))
" 2>/dev/null || true)"

    refresh_token="$(printf '%s' "$raw_creds" | python3 -c "
import sys, json
d = json.load(sys.stdin)
o = d.get('claudeAiOauth', {})
print(o.get('refreshToken', ''))
" 2>/dev/null || true)"

    expires_at="$(printf '%s' "$raw_creds" | python3 -c "
import sys, json
d = json.load(sys.stdin)
o = d.get('claudeAiOauth', {})
print(o.get('expiresAt', 0))
" 2>/dev/null || true)"

    if [[ -z "$access_token" ]]; then
        warn "Could not parse OAuth tokens from Claude Code credentials."
        warn "Run refresh-tokens.sh after logging into Claude Code."
        return 0
    fi

    cat > "$EXT_DIR/firefox-injected-tokens.json" <<TOKEOF
{
  "accessToken": "$access_token",
  "refreshToken": "$refresh_token",
  "expiresAt": $expires_at
}
TOKEOF
    chmod 600 "$EXT_DIR/firefox-injected-tokens.json"
    ok "OAuth tokens injected into extension directory."
}

# ── Create Native Host Wrapper ──────────────────────────────────────────────
create_nmh_wrapper() {
    banner "Creating Native Host Wrapper"

    cat > "$INSTALL_DIR/firefox-native-host" <<'WRAPEOF'
#!/usr/bin/env bash
# Native messaging host wrapper for Claude for Firefox.
# Delegates to Claude Code's built-in native messaging handler.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve claude binary — same search order as the installer.
if [[ -n "${CLAUDE_CODE_BIN:-}" ]] && [[ -x "$CLAUDE_CODE_BIN" ]]; then
    CLAUDE_BIN="$CLAUDE_CODE_BIN"
elif command -v claude &>/dev/null; then
    CLAUDE_BIN="$(command -v claude)"
elif [[ -x /usr/local/bin/claude ]]; then
    CLAUDE_BIN="/usr/local/bin/claude"
else
    echo '{"error":"claude binary not found"}' >&2
    exit 1
fi

exec "$CLAUDE_BIN" --chrome-native-host
WRAPEOF
    chmod +x "$INSTALL_DIR/firefox-native-host"
    ok "Native host wrapper created at $INSTALL_DIR/firefox-native-host"
}

# ── Install NMH Manifests ──────────────────────────────────────────────────
install_nmh_manifests() {
    banner "Installing Native Messaging Host Manifests"

    mkdir -p "$NMH_DIR"

    local wrapper_path="$INSTALL_DIR/firefox-native-host"

    for nmh_name in "$NMH_NAME_BROWSER" "$NMH_NAME_CODE"; do
        local manifest_path="$NMH_DIR/$nmh_name.json"
        cat > "$manifest_path" <<NMHEOF
{
  "name": "$nmh_name",
  "description": "Claude native messaging host for Firefox",
  "path": "$wrapper_path",
  "type": "stdio",
  "allowed_extensions": ["$EXT_ID"]
}
NMHEOF
        ok "NMH manifest installed: $manifest_path"
        # ponytail: Zen keeps its data in ~/.zen; mirror there in case it looks locally
        if [[ "$OS" == linux && -d "$HOME/.zen" ]]; then
            mkdir -p "$HOME/.zen/native-messaging-hosts"
            cp "$manifest_path" "$HOME/.zen/native-messaging-hosts/"
        fi
    done
}

# ── Create Launcher Script ──────────────────────────────────────────────────
create_launcher() {
    banner "Creating Launcher"

    cat > "$INSTALL_DIR/launch.sh" <<'LAUNCHEOF'
#!/usr/bin/env bash
# Launch Firefox with Claude extension loaded.
set -euo pipefail

EXT_DIR="$HOME/.claude/firefox/extension"

if [[ ! -d "$EXT_DIR" ]]; then
    echo "Error: Extension not installed at $EXT_DIR" >&2
    echo "Run install.sh first." >&2
    exit 1
fi

case "$(uname -s)" in
    Darwin)
        FIREFOX="/Applications/Firefox.app/Contents/MacOS/firefox"
        [[ ! -x "$FIREFOX" ]] && FIREFOX="$HOME/Applications/Firefox.app/Contents/MacOS/firefox"
        ;;
    Linux)
        FIREFOX="${FIREFOX_BIN:-__FIREFOX_BIN__}"
        ;;
esac

if [[ ! -x "${FIREFOX:-}" ]]; then
    echo "Error: Firefox not found." >&2
    exit 1
fi

echo "Launching $FIREFOX with Claude extension..."
# web-ext loads the unsigned extension as a temporary add-on in a fresh profile
exec npx --yes web-ext run --firefox="$FIREFOX" --source-dir="$EXT_DIR" "$@"
LAUNCHEOF
    if [[ "$OS" == linux ]]; then sed -i "s|__FIREFOX_BIN__|$FIREFOX_BIN|" "$INSTALL_DIR/launch.sh"; fi
    chmod +x "$INSTALL_DIR/launch.sh"
    ok "Launcher created at $INSTALL_DIR/launch.sh"
}

# ── Create Token Refresh Script ────────────────────────────────────────────
create_refresh_script() {
    cat > "$INSTALL_DIR/refresh-tokens.sh" <<'REFRESHEOF'
#!/usr/bin/env bash
# Refresh OAuth tokens from Claude Code's keychain into the Firefox extension.
set -euo pipefail

EXT_DIR="$HOME/.claude/firefox/extension"
TOKEN_FILE="$EXT_DIR/firefox-injected-tokens.json"

raw_creds=""
case "$(uname -s)" in
    Darwin)
        raw_creds="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null || true)"
        ;;
    Linux)
        raw_creds="$(secret-tool lookup service 'Claude Code-credentials' 2>/dev/null || true)"
        [[ -z "$raw_creds" && -f "$HOME/.claude/.credentials.json" ]] && raw_creds="$(<"$HOME/.claude/.credentials.json")"
        ;;
    *)
        echo "Unsupported OS for token refresh." >&2; exit 1 ;;
esac

if [[ -z "$raw_creds" ]]; then
    echo "Error: Could not read Claude Code credentials. Log into Claude Code first." >&2
    exit 1
fi

access_token="$(printf '%s' "$raw_creds" | python3 -c "import sys,json; o=json.load(sys.stdin).get('claudeAiOauth',{}); print(o.get('accessToken',''))")"
refresh_token="$(printf '%s' "$raw_creds" | python3 -c "import sys,json; o=json.load(sys.stdin).get('claudeAiOauth',{}); print(o.get('refreshToken',''))")"
expires_at="$(printf '%s' "$raw_creds" | python3 -c "import sys,json; o=json.load(sys.stdin).get('claudeAiOauth',{}); print(o.get('expiresAt',0))")"

if [[ -z "$access_token" ]]; then
    echo "Error: No access token found in credentials." >&2
    exit 1
fi

mkdir -p "$EXT_DIR"
cat > "$TOKEN_FILE" <<EOF
{
  "accessToken": "$access_token",
  "refreshToken": "$refresh_token",
  "expiresAt": $expires_at
}
EOF
chmod 600 "$TOKEN_FILE"
echo "Tokens refreshed successfully."
REFRESHEOF
    chmod +x "$INSTALL_DIR/refresh-tokens.sh"
    ok "Token refresh script created at $INSTALL_DIR/refresh-tokens.sh"
}

# ── macOS App Bundle ────────────────────────────────────────────────────────
create_macos_app() {
    banner "Creating macOS App Bundle"

    local app_dir="$HOME/Applications/Claude Firefox.app"
    local contents_dir="$app_dir/Contents"
    local macos_dir="$contents_dir/MacOS"

    mkdir -p "$macos_dir"

    cat > "$contents_dir/Info.plist" <<'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>launch</string>
    <key>CFBundleIdentifier</key>
    <string>community.anthropic.claude-firefox</string>
    <key>CFBundleName</key>
    <string>Claude Firefox</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
</dict>
</plist>
PLISTEOF

    cat > "$macos_dir/launch" <<'MACLAUNCHEOF'
#!/usr/bin/env bash
exec "$HOME/.claude/firefox/launch.sh"
MACLAUNCHEOF
    chmod +x "$macos_dir/launch"

    ok "macOS app bundle created at $app_dir"
}

# ── Linux Desktop Entry ────────────────────────────────────────────────────
create_linux_desktop() {
    banner "Creating Linux Desktop Entry"

    local desktop_dir="$HOME/.local/share/applications"
    mkdir -p "$desktop_dir"

    cat > "$desktop_dir/claude-firefox.desktop" <<DESKTOPEOF
[Desktop Entry]
Type=Application
Name=Claude Firefox
Comment=Launch Firefox with Claude extension
Exec=$INSTALL_DIR/launch.sh
Terminal=false
Categories=Network;WebBrowser;
StartupNotify=true
DESKTOPEOF

    ok "Desktop entry created at $desktop_dir/claude-firefox.desktop"
}

# ── Uninstall ───────────────────────────────────────────────────────────────
do_uninstall() {
    banner "Uninstalling Claude for Firefox"

    detect_os
    set_nmh_dir

    # Remove NMH manifests
    for nmh_name in "$NMH_NAME_BROWSER" "$NMH_NAME_CODE"; do
        for mf in "$NMH_DIR/$nmh_name.json" "$HOME/.zen/native-messaging-hosts/$nmh_name.json"; do
            if [[ -f "$mf" ]]; then
                rm -f "$mf"
                ok "Removed NMH manifest: $mf"
            fi
        done
    done

    # Remove install dir
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        ok "Removed install directory: $INSTALL_DIR"
    fi

    # OS-specific cleanup
    case "$OS" in
        macos)
            local app_dir="$HOME/Applications/Claude Firefox.app"
            if [[ -d "$app_dir" ]]; then
                rm -rf "$app_dir"
                ok "Removed macOS app bundle: $app_dir"
            fi
            ;;
        linux)
            local desktop_file="$HOME/.local/share/applications/claude-firefox.desktop"
            if [[ -f "$desktop_file" ]]; then
                rm -f "$desktop_file"
                ok "Removed desktop entry: $desktop_file"
            fi
            ;;
    esac

    ok "Uninstall complete."
    exit 0
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    banner "Claude for Firefox — Installer"

    # Handle --uninstall
    if [[ "${1:-}" == "--uninstall" ]]; then
        do_uninstall
    fi

    detect_os
    set_nmh_dir
    find_claude
    find_firefox

    # Create directories
    mkdir -p "$EXT_DIR"
    ok "Extension directory: $EXT_DIR"

    # Install extension files (copy from source if running from repo)
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$script_dir/manifest.json" ]]; then
        # Installer is inside the extension directory — copy everything except install scripts
        rsync -a --exclude='install.sh' --exclude='install.ps1' --exclude='.git' --exclude='.DS_Store' --exclude='node_modules' --exclude='web-ext-artifacts' --exclude='firefox-injected-tokens.json' "$script_dir/" "$EXT_DIR/"
        ok "Extension files copied to $EXT_DIR"
    elif [[ -d "$script_dir/extension" ]]; then
        cp -R "$script_dir/extension/"* "$EXT_DIR/" 2>/dev/null || true
        ok "Extension files copied to $EXT_DIR"
    else
        warn "No extension files found. Skipping extension file copy."
        warn "Place extension source files in $EXT_DIR manually."
    fi

    create_nmh_wrapper
    install_nmh_manifests
    inject_tokens
    create_launcher
    create_refresh_script

    case "$OS" in
        macos) create_macos_app ;;
        linux) create_linux_desktop ;;
    esac

    # ── Summary ─────────────────────────────────────────────────────────────
    banner "Installation Complete"

    printf "${GREEN}${BOLD}Claude for Firefox has been installed!${NC}\n\n"
    printf "${DIM}Extension dir:    ${NC}%s\n" "$EXT_DIR"
    printf "${DIM}NMH manifests:    ${NC}%s\n" "$NMH_DIR"
    printf "${DIM}Claude binary:    ${NC}%s\n" "$CLAUDE_BIN"
    printf "${DIM}Firefox binary:   ${NC}%s\n" "$FIREFOX_BIN"
    echo ""

    printf "${YELLOW}Next steps:${NC}\n"
    echo "  1. Open Firefox and go to about:debugging#/runtime/this-firefox"
    echo "  2. Click 'Load Temporary Add-on...'"
    echo "  3. Navigate to $EXT_DIR and select manifest.json"
    echo ""
    echo "  Or use the launcher:"
    echo "    $INSTALL_DIR/launch.sh"
    echo ""
    echo "  To refresh tokens from Claude Code:"
    echo "    $INSTALL_DIR/refresh-tokens.sh"
    echo ""

    case "$OS" in
        macos)
            echo "  macOS app bundle: ~/Applications/Claude Firefox.app"
            ;;
        linux)
            echo "  Desktop entry installed — search for 'Claude Firefox' in your app launcher."
            ;;
    esac
    echo ""
}

main "$@"
