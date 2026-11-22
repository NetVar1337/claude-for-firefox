#Requires -Version 5.1
<#
.SYNOPSIS
    Claude for Firefox — Windows Installer
.DESCRIPTION
    Installs the Claude browser extension for Firefox on Windows.
    Sets up native messaging hosts, injects OAuth tokens from Claude Code,
    and creates launcher scripts.
.PARAMETER Uninstall
    Remove all installed components.
.PARAMETER NodePath
    node.exe (Node.js 18 or later) for the native host and the MCP server, when
    Node.js is not in PATH (the environment variable NODE_BIN works too).
.EXAMPLE
    .\install.ps1
    .\install.ps1 -NodePath C:\tools\node\node.exe
    .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$NodePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ───────────────────────────────────────────────────────────────
$ExtId             = 'claude-for-firefox@anthropic.community'
$ChromeExtId       = 'fcoeoabgfenejglbffodgkkbkcdhcgfn'
$NmhNameBrowser    = 'com.anthropic.claude_browser_extension'
$NmhNameCode       = 'com.anthropic.claude_code_browser_extension'
$InstallDir        = Join-Path $env:USERPROFILE '.claude\firefox'
$ExtDir            = Join-Path $InstallDir 'extension'
$NmhDir            = Join-Path $InstallDir 'nmh'

# ── Helpers ─────────────────────────────────────────────────────────────────
function Write-Info  { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "[OK]    $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }
function Write-Banner { param([string]$Msg) Write-Host "`n-- $Msg --`n" -ForegroundColor White }

function Exit-Fatal {
    param([string]$Msg)
    Write-Err $Msg
    exit 1
}

# Runs a program and returns its output, stderr included, as text. Windows PowerShell 5.1 turns
# a native program's stderr into a terminating error while $ErrorActionPreference is 'Stop'.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } | Out-String
    } finally {
        $ErrorActionPreference = $old
    }
    return $out
}

# Files that other programs parse are written without a byte order mark: Windows
# PowerShell 5.1's "-Encoding UTF8" adds one.
function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# cmd.exe reads a .bat file in the OEM code page, so a path with letters outside ASCII (a
# Cyrillic or Chinese user name, say) breaks in a file written as ASCII. A path in the user's
# profile is written as %USERPROFILE%\..., which cmd expands at run time; the file is written in
# the OEM code page, with CRLF line ends, for any other path.
function ConvertTo-BatPath {
    param([string]$Path)
    $profileDir = $env:USERPROFILE.TrimEnd('\')
    if ($Path.StartsWith($profileDir + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return '%USERPROFILE%' + $Path.Substring($profileDir.Length)
    }
    return $Path
}

function Write-BatFile {
    param([string]$Path, [string]$Content)
    $oem = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    [System.IO.File]::WriteAllText($Path, ($Content -replace "`r?`n", "`r`n"), $oem)
}

# ── Find Claude Code ────────────────────────────────────────────────────────
function Find-Claude {
    # 1. Env var override
    if ($env:CLAUDE_CODE_BIN -and (Test-Path $env:CLAUDE_CODE_BIN)) {
        Write-Info "Using CLAUDE_CODE_BIN override: $($env:CLAUDE_CODE_BIN)"
        return $env:CLAUDE_CODE_BIN
    }

    # 2. PATH
    $inPath = Get-Command claude -ErrorAction SilentlyContinue
    if ($inPath) {
        Write-Info "Found claude in PATH: $($inPath.Source)"
        return $inPath.Source
    }
    $inPathExe = Get-Command claude.exe -ErrorAction SilentlyContinue
    if ($inPathExe) {
        Write-Info "Found claude.exe in PATH: $($inPathExe.Source)"
        return $inPathExe.Source
    }

    # 3. Standard install locations
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\claude-code\claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\claude-code\resources\claude.exe')
    )

    # Versioned installs
    $versionsDir = Join-Path $env:LOCALAPPDATA 'claude\versions'
    if (Test-Path $versionsDir) {
        Get-ChildItem $versionsDir -Directory | Sort-Object Name -Descending | ForEach-Object {
            $candidates += Join-Path $_.FullName 'claude.exe'
        }
    }

    foreach ($c in $candidates) {
        if (Test-Path $c) {
            Write-Info "Found Claude Code at: $c"
            return $c
        }
    }

    Exit-Fatal "Claude Code not found. Install it first or set CLAUDE_CODE_BIN env var."
}

# ── Find Firefox ────────────────────────────────────────────────────────────
function Find-Firefox {
    # Standard paths
    $candidates = @(
        "${env:ProgramFiles}\Mozilla Firefox\firefox.exe",
        "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
    )

    foreach ($c in $candidates) {
        if (Test-Path $c) {
            Write-Info "Found Firefox at: $c"
            return $c
        }
    }

    # Registry
    try {
        $regPaths = @(
            'HKLM:\SOFTWARE\Mozilla\Mozilla Firefox',
            'HKLM:\SOFTWARE\WOW6432Node\Mozilla\Mozilla Firefox'
        )
        foreach ($rp in $regPaths) {
            if (Test-Path $rp) {
                $ver = (Get-ChildItem $rp | Sort-Object Name -Descending | Select-Object -First 1).Name
                $mainKey = Join-Path $rp "$ver\Main"
                if (Test-Path "Registry::$mainKey") {
                    $ffPath = (Get-ItemProperty "Registry::$mainKey" -ErrorAction SilentlyContinue).PathToExe
                    if ($ffPath -and (Test-Path $ffPath)) {
                        Write-Info "Found Firefox via registry: $ffPath"
                        return $ffPath
                    }
                }
            }
        }
    } catch {
        # Registry lookup failed, continue
    }

    # PATH
    $inPath = Get-Command firefox -ErrorAction SilentlyContinue
    if ($inPath) {
        Write-Info "Found Firefox in PATH: $($inPath.Source)"
        return $inPath.Source
    }
    $inPathExe = Get-Command firefox.exe -ErrorAction SilentlyContinue
    if ($inPathExe) {
        Write-Info "Found Firefox in PATH: $($inPathExe.Source)"
        return $inPathExe.Source
    }

    Exit-Fatal "Firefox not found. Install Firefox first."
}

# ── Find Node.js ────────────────────────────────────────────────────────────
function Find-Node {
    $candidates = @()
    foreach ($explicit in @($NodePath, $env:NODE_BIN)) {
        if ($explicit) {
            if (-not (Test-Path -LiteralPath $explicit -PathType Leaf)) {
                Exit-Fatal "node.exe not found at: $explicit"
            }
            $candidates += (Resolve-Path -LiteralPath $explicit).Path
            break
        }
    }
    if ($candidates.Count -eq 0) {
        $cmd = Get-Command node -ErrorAction SilentlyContinue
        if ($cmd) { $candidates += $cmd.Source }
        $candidates += (Join-Path $env:ProgramFiles 'nodejs\node.exe')
    }

    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c -PathType Leaf)) { continue }
        $version = (Invoke-Native -Exe $c -Arguments @('--version')).Trim()
        if ($version -match '^v(\d+)\.' -and [int]$Matches[1] -ge 18) {
            Write-Info "Using Node.js $version at: $c"
            return $c
        }
        Write-Warn "Skipping $c (version '$version'; Node.js 18 or later is needed)."
    }

    Exit-Fatal 'Node.js 18+ not found. Install it, or pass -NodePath <path to node.exe>.'
}

# ── Inject OAuth Tokens ────────────────────────────────────────────────────
function Inject-Tokens {
    Write-Banner 'Injecting OAuth Tokens'

    $tokenFile = Join-Path $ExtDir 'firefox-injected-tokens.json'
    $rawCreds = $null

    # Try CredentialManager module first
    try {
        if (Get-Module -ListAvailable -Name CredentialManager -ErrorAction SilentlyContinue) {
            Import-Module CredentialManager -ErrorAction Stop
            $cred = Get-StoredCredential -Target 'Claude Code-credentials' -ErrorAction SilentlyContinue
            if ($cred) {
                $rawCreds = $cred.GetNetworkCredential().Password
            }
        }
    } catch {
        # Module not available or failed
    }

    # Fallback: cmdkey + PowerShell credential vault
    if (-not $rawCreds) {
        try {
            # Try reading via vaultcmd / direct API
            Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
            $cmdkeyOutput = & cmdkey /list 2>$null | Out-String
            if ($cmdkeyOutput -match 'Claude Code-credentials') {
                Write-Info "Found Claude Code credentials in Credential Manager."
                # cmdkey cannot read passwords directly; try .NET CredentialManager
                try {
                    $code = @'
using System;
using System.Runtime.InteropServices;
public class CredHelper {
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool CredRead(string target, int type, int flags, out IntPtr credential);
    [DllImport("advapi32.dll")]
    public static extern void CredFree(IntPtr buffer);
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct CREDENTIAL {
        public int Flags; public int Type;
        public string TargetName; public string Comment;
        public long LastWritten; public int CredentialBlobSize;
        public IntPtr CredentialBlob; public int Persist;
        public int AttributeCount; public IntPtr Attributes;
        public string TargetAlias; public string UserName;
    }
    public static string Read(string target) {
        IntPtr ptr;
        if (!CredRead(target, 1, 0, out ptr)) return null;
        try {
            var cred = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
            if (cred.CredentialBlobSize > 0)
                return Marshal.PtrToStringUni(cred.CredentialBlob, cred.CredentialBlobSize / 2);
            return null;
        } finally { CredFree(ptr); }
    }
}
'@
                    Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
                    $rawCreds = [CredHelper]::Read('Claude Code-credentials')
                } catch {
                    Write-Warn "Could not read credential blob via .NET interop: $_"
                }
            }
        } catch {
            # cmdkey approach failed
        }
    }

    # Fallback: credentials file written by Claude Code on Windows
    if (-not $rawCreds) {
        $credFile = Join-Path $env:USERPROFILE '.claude\.credentials.json'
        if (Test-Path $credFile) { $rawCreds = Get-Content $credFile -Raw }
    }

    if (-not $rawCreds) {
        Write-Warn "Could not read Claude Code credentials from Windows Credential Manager."
        Write-Warn "Run 'claude' at least once to log in, then re-run this installer."
        return
    }

    try {
        $parsed = $rawCreds | ConvertFrom-Json
        $oauth = $parsed.claudeAiOauth

        if (-not $oauth.accessToken) {
            Write-Warn "No access token found in credentials. Run refresh-tokens after login."
            return
        }

        $tokenObj = @{
            accessToken  = $oauth.accessToken
            refreshToken = $oauth.refreshToken
            expiresAt    = $oauth.expiresAt
        }
        Write-Utf8NoBom -Path $tokenFile -Content ($tokenObj | ConvertTo-Json)
        Write-Ok "OAuth tokens injected."
    } catch {
        Write-Warn "Failed to parse OAuth tokens: $_"
    }
}

# ── Create Native Host Wrapper ──────────────────────────────────────────────
function Create-NmhWrapper {
    param([string]$NodeBin)

    Write-Banner 'Creating Native Host Wrapper'

    foreach ($script in 'firefox-host.mjs', 'firefox-mcp.mjs') {
        Copy-Item -Path (Join-Path $PSScriptRoot "native\$script") -Destination $InstallDir -Force
    }
    Write-Ok "Native host and MCP server copied to $InstallDir"

    # The host script is found next to the wrapper (%~dp0), so no path in the file has to survive
    # the OEM code page.
    $wrapperPath = Join-Path $InstallDir 'firefox-native-host.bat'
    $batNode = ConvertTo-BatPath $NodeBin
    $wrapperContent = @"
@echo off
REM Native messaging host wrapper for Claude for Firefox.
REM Runs the bundled host, which serves its own pipe so it can run next to Claude for Chrome.
"$batNode" "%~dp0firefox-host.mjs" 2>>"%~dp0host.log"
exit /b %ERRORLEVEL%
"@
    Write-BatFile -Path $wrapperPath -Content $wrapperContent
    Write-Ok "Native host wrapper created at $wrapperPath"
    return $wrapperPath
}

# ── Install NMH Manifests ──────────────────────────────────────────────────
function Install-NmhManifests {
    param([string]$WrapperPath)

    Write-Banner 'Installing Native Messaging Host Manifests'

    New-Item -ItemType Directory -Force -Path $NmhDir | Out-Null

    foreach ($nmhName in @($NmhNameBrowser, $NmhNameCode)) {
        $manifestPath = Join-Path $NmhDir "$nmhName.json"
        $manifest = @{
            name               = $nmhName
            description        = 'Claude native messaging host for Firefox'
            path               = $WrapperPath
            type               = 'stdio'
            allowed_extensions = @($ExtId)
        }
        Write-Utf8NoBom -Path $manifestPath -Content ($manifest | ConvertTo-Json -Depth 5)
        Write-Ok "NMH manifest written: $manifestPath"

        # Create registry key pointing to the manifest
        $regPath = "HKCU:\Software\Mozilla\NativeMessagingHosts\$nmhName"
        New-Item -Path $regPath -Force | Out-Null
        Set-ItemProperty -Path $regPath -Name '(Default)' -Value $manifestPath
        Write-Ok "Registry key set: $regPath"
    }
}

# ── Create Launcher Scripts ────────────────────────────────────────────────
function Create-Launchers {
    param([string]$FirefoxPath, [string]$NodeBin)

    Write-Banner 'Creating Launcher Scripts'

    # npx comes with Node.js; the launchers put Node's folder first in PATH, so a Node.js that is
    # not in PATH works too.
    $nodeDir = Split-Path -Parent $NodeBin

    # .bat launcher
    $batPath = Join-Path $InstallDir 'launch.bat'
    $batFirefox = ConvertTo-BatPath $FirefoxPath
    $batNodeDir = ConvertTo-BatPath $nodeDir
    $batContent = @"
@echo off
REM Launch Firefox with Claude extension.
set "EXT_DIR=%USERPROFILE%\.claude\firefox\extension"
set "PATH=$batNodeDir;%PATH%"
if not exist "%EXT_DIR%" (
    echo Error: Extension not installed at %EXT_DIR%. Run install.ps1 first. >&2
    exit /b 1
)
echo Launching Firefox with Claude extension...
start "" /b cmd /c npx --yes web-ext run --source-dir "%EXT_DIR%" --firefox "$batFirefox" --firefox-profile "%USERPROFILE%\.claude\firefox\profile" --profile-create-if-missing --keep-profile-changes --start-url about:blank --pref=browser.startup.homepage_override.mstone=ignore --pref=startup.homepage_welcome_url= --pref=startup.homepage_welcome_url.additional= --pref=browser.aboutwelcome.enabled=false --pref=browser.shell.checkDefaultBrowser=false --pref=datareporting.policy.dataSubmissionPolicyBypassNotification=true --pref=browser.startup.page=0 --pref=trailhead.firstrun.didSeeAboutWelcome=true --no-reload
"@
    Write-BatFile -Path $batPath -Content $batContent
    Write-Ok "Launcher .bat created at $batPath"

    # .ps1 launcher (written with a byte order mark, so Windows PowerShell 5.1 reads any path in it)
    $ps1Path = Join-Path $InstallDir 'launch.ps1'
    $ps1Content = @"
# Launch Firefox with Claude extension.
`$env:PATH = '$nodeDir;' + `$env:PATH
`$extDir = Join-Path `$env:USERPROFILE '.claude\firefox\extension'
if (-not (Test-Path `$extDir)) {
    Write-Error "Extension not installed at `$extDir. Run install.ps1 first."
    exit 1
}
Write-Host 'Launching Firefox with Claude extension...'
& npx --yes web-ext run --source-dir `$extDir --firefox '$FirefoxPath' --firefox-profile (Join-Path `$env:USERPROFILE '.claude\firefox\profile') --profile-create-if-missing --keep-profile-changes --start-url about:blank '--pref=browser.startup.homepage_override.mstone=ignore' '--pref=startup.homepage_welcome_url=' '--pref=startup.homepage_welcome_url.additional=' '--pref=browser.aboutwelcome.enabled=false' '--pref=browser.shell.checkDefaultBrowser=false' '--pref=datareporting.policy.dataSubmissionPolicyBypassNotification=true' '--pref=browser.startup.page=0' '--pref=trailhead.firstrun.didSeeAboutWelcome=true' --no-reload
"@
    Set-Content -Path $ps1Path -Value $ps1Content -Encoding UTF8
    Write-Ok "Launcher .ps1 created at $ps1Path"

    # Token refresh script
    $refreshPath = Join-Path $InstallDir 'refresh-tokens.ps1'
    $refreshContent = @'
# Refresh OAuth tokens from Claude Code's Credential Manager into the Firefox extension.
$ErrorActionPreference = 'Stop'

$tokenFile = Join-Path $env:USERPROFILE '.claude\firefox\extension\firefox-injected-tokens.json'
$rawCreds = $null

# Try CredentialManager module
try {
    if (Get-Module -ListAvailable -Name CredentialManager -ErrorAction SilentlyContinue) {
        Import-Module CredentialManager
        $cred = Get-StoredCredential -Target 'Claude Code-credentials' -ErrorAction SilentlyContinue
        if ($cred) { $rawCreds = $cred.GetNetworkCredential().Password }
    }
} catch {}

# Fallback: .NET interop
if (-not $rawCreds) {
    try {
        $code = @"
using System; using System.Runtime.InteropServices;
public class CredHelper2 {
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool CredRead(string target, int type, int flags, out IntPtr credential);
    [DllImport("advapi32.dll")]
    public static extern void CredFree(IntPtr buffer);
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct CREDENTIAL {
        public int Flags; public int Type; public string TargetName; public string Comment;
        public long LastWritten; public int CredentialBlobSize; public IntPtr CredentialBlob;
        public int Persist; public int AttributeCount; public IntPtr Attributes;
        public string TargetAlias; public string UserName;
    }
    public static string Read(string target) {
        IntPtr ptr;
        if (!CredRead(target, 1, 0, out ptr)) return null;
        try {
            var c = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
            if (c.CredentialBlobSize > 0) return Marshal.PtrToStringUni(c.CredentialBlob, c.CredentialBlobSize / 2);
            return null;
        } finally { CredFree(ptr); }
    }
}
"@
        Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
        $rawCreds = [CredHelper2]::Read('Claude Code-credentials')
    } catch {
        Write-Error "Could not read credentials: $_"
        exit 1
    }
}

if (-not $rawCreds) {
    $credFile = Join-Path $env:USERPROFILE '.claude\.credentials.json'
    if (Test-Path $credFile) { $rawCreds = Get-Content $credFile -Raw }
}

if (-not $rawCreds) {
    Write-Error "No Claude Code credentials found. Log in with 'claude' first."
    exit 1
}

$parsed = $rawCreds | ConvertFrom-Json
$oauth = $parsed.claudeAiOauth
if (-not $oauth.accessToken) {
    Write-Error "No access token in credentials."
    exit 1
}

$tokenDir = Split-Path $tokenFile
if (-not (Test-Path $tokenDir)) { New-Item -ItemType Directory -Force -Path $tokenDir | Out-Null }

@{ accessToken = $oauth.accessToken; refreshToken = $oauth.refreshToken; expiresAt = $oauth.expiresAt } |
    ConvertTo-Json | Set-Content -Path $tokenFile -Encoding UTF8

Write-Host 'Tokens refreshed successfully.'
'@
    Set-Content -Path $refreshPath -Value $refreshContent -Encoding UTF8
    Write-Ok "Token refresh script created at $refreshPath"
}

# ── Uninstall ───────────────────────────────────────────────────────────────
function Do-Uninstall {
    Write-Banner 'Uninstalling Claude for Firefox'

    # Remove registry keys
    foreach ($nmhName in @($NmhNameBrowser, $NmhNameCode)) {
        $regPath = "HKCU:\Software\Mozilla\NativeMessagingHosts\$nmhName"
        if (Test-Path $regPath) {
            Remove-Item -Path $regPath -Force -Recurse
            Write-Ok "Removed registry key: $regPath"
        }
    }

    # Clean up parent key if empty
    $parentKey = 'HKCU:\Software\Mozilla\NativeMessagingHosts'
    if ((Test-Path $parentKey) -and -not (Get-ChildItem $parentKey -ErrorAction SilentlyContinue)) {
        Remove-Item -Path $parentKey -Force -ErrorAction SilentlyContinue
    }

    # Remove MCP registration
    try { & claude mcp remove firefox --scope user 2>$null | Out-Null } catch {}

    # Remove install directory
    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force
        Write-Ok "Removed install directory: $InstallDir"
    }

    Write-Ok 'Uninstall complete.'
    exit 0
}

# ── Main ────────────────────────────────────────────────────────────────────
function Main {
    Write-Banner 'Claude for Firefox - Windows Installer'

    if ($Uninstall) {
        Do-Uninstall
        return
    }

    $claudeBin  = Find-Claude
    $firefoxBin = Find-Firefox
    $nodeBin    = Find-Node

    # Create directories
    New-Item -ItemType Directory -Force -Path $ExtDir | Out-Null
    Write-Ok "Extension directory: $ExtDir"

    # Copy extension files if available
    $srcExtDir = $PSScriptRoot
    $exclude = @('.git','.gm','.agentplug-kv','node_modules','web-ext-artifacts','install.ps1','install.sh','native','README.md','.gitignore')
    Get-ChildItem -Path $srcExtDir -Force | Where-Object { $exclude -notcontains $_.Name -and $_.Name -ne 'firefox-injected-tokens.json' } | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $ExtDir -Recurse -Force
    }
    Write-Ok "Extension files copied to $ExtDir"

    $wrapperPath = Create-NmhWrapper -NodeBin $nodeBin
    Install-NmhManifests -WrapperPath $wrapperPath
    Inject-Tokens
    Create-Launchers -FirefoxPath $firefoxBin -NodeBin $nodeBin

    Write-Banner 'Registering Firefox MCP server'
    # Registered with the full path of node.exe, so Claude Code starts it even when Node.js is not
    # in PATH. An earlier registration (perhaps with a bare "node") is replaced.
    $mcpScript = Join-Path $InstallDir 'firefox-mcp.mjs'
    $mcpList = Invoke-Native -Exe $claudeBin -Arguments @('mcp', 'list')
    if ($mcpList -match '(?m)^firefox:') {
        Invoke-Native -Exe $claudeBin -Arguments @('mcp', 'remove', 'firefox', '--scope', 'user') | Out-Null
    }
    $addOut = Invoke-Native -Exe $claudeBin -Arguments @('mcp', 'add', 'firefox', '--scope', 'user', '--', $nodeBin, $mcpScript)
    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'Registered firefox MCP server with Claude Code (user scope).'
    } else {
        Write-Warn "Could not register the firefox MCP server: $($addOut.Trim())"
    }

    # ── Summary ─────────────────────────────────────────────────────────
    Write-Banner 'Installation Complete'

    Write-Host 'Claude for Firefox has been installed!' -ForegroundColor Green
    Write-Host ''
    Write-Host "Extension dir:  $ExtDir"
    Write-Host "NMH manifests:  $NmhDir"
    Write-Host "Claude binary:  $claudeBin"
    Write-Host "Firefox binary: $firefoxBin"
    Write-Host "Node.js:        $nodeBin"
    Write-Host ''
    Write-Host 'Next steps:' -ForegroundColor Yellow
    Write-Host "  1. Open Firefox and go to about:debugging#/runtime/this-firefox"
    Write-Host "  2. Click 'Load Temporary Add-on...'"
    Write-Host "  3. Navigate to $ExtDir and select manifest.json"
    Write-Host ''
    Write-Host '  Or use the launcher:'
    Write-Host "    $InstallDir\launch.bat"
    Write-Host "    $InstallDir\launch.ps1"
    Write-Host ''
    Write-Host '  To refresh tokens from Claude Code:'
    Write-Host "    $InstallDir\refresh-tokens.ps1"
    Write-Host ''
}

Main
