<#
.SYNOPSIS
    Non-destructive, idempotent installer for the OpenCode plugin
    "opencode-litellm-cost-map" (Windows PowerShell 5.1+ compatible).

.DESCRIPTION
    Copies the two runtime files (litellm-cost-map.js and
    litellm-cost-map-lib.mjs) from the repository root into the OpenCode
    plugins directory (<configDir>/plugins). If the script is run outside a
    repository clone, it downloads those two runtime files from GitHub raw URLs.
    The test file is never copied.

    OpenCode auto-discovers local plugins via the glob "{plugin,plugins}/*.{ts,js}",
    so once the entry file (litellm-cost-map.js) lives in <configDir>/plugins it
    is picked up automatically. The .mjs library is imported by the entry file
    (it is not auto-discovered on its own), so both files are copied.

    With default auto-discovery the -Reference step is NOT needed. Reference mode
    is opt-in for users who prefer an explicit "plugin" entry in opencode.json or
    who use a non-standard config directory.

.PARAMETER Reference
    Opt-in. Ensure <configDir>/opencode.json references the installed entry file
    as a file:// URL in its "plugin" array. The file is backed up before editing,
    edits are additive only, and invalid JSON is never overwritten.

.PARAMETER DryRun
    Print every action that WOULD be taken and make zero changes.

.PARAMETER ConfigDir
    Explicit override for the OpenCode config directory. Highest priority.

.PARAMETER Help
    Show this help text.

.NOTES
    Config dir resolution priority:
      1. -ConfigDir <path> (explicit override)
      2. OPENCODE_CONFIG env var (file -> its directory; dir -> used directly)
      3. XDG_CONFIG_HOME/opencode (if XDG_CONFIG_HOME is set)
      4. Default: $env:USERPROFILE\.config\opencode

    Verify success: restart OpenCode, run a prompt, and confirm the session cost
    is non-zero. Use --print-logs and look for the line:
      "Updated N model costs from LiteLLM".
#>

[CmdletBinding()]
param(
    [switch]$Reference,
    [switch]$DryRun,
    [string]$ConfigDir,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Info    { param([string]$Message) Write-Host "[*] $Message" }
function Write-Action  { param([string]$Message) Write-Host "[+] $Message" }
function Write-DryNote { param([string]$Message) Write-Host "[dry-run] $Message" }
function Write-Warn    { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Err     { param([string]$Message) Write-Host "[x] $Message" -ForegroundColor Red }

function Show-Usage {
    Write-Host @"
install.ps1 - installer for opencode-litellm-cost-map

Usage:
  install.ps1 [-Reference] [-DryRun] [-ConfigDir <path>] [-Help]

Options:
  -Reference          Add a file:// reference to the plugin in opencode.json
                      (opt-in; NOT required with default auto-discovery).
  -DryRun             Show what would happen; make no changes.
  -ConfigDir <path>   Explicit OpenCode config directory (overrides env vars).
  -Help               Show this help.

Config dir resolution priority:
  1. -ConfigDir
  2. OPENCODE_CONFIG (file -> its dir; dir -> used directly)
  3. XDG_CONFIG_HOME/opencode
  4. \$env:USERPROFILE\.config\opencode
"@
}

if ($Help) {
    Show-Usage
    exit 0
}

# ---------------------------------------------------------------------------
# Self-locate the repository root when the script lives in <repo>/scripts.
# When piped through Invoke-RestMethod | Invoke-Expression, there is no script
# path, so use the current directory and fall back to remote runtime files.
# ---------------------------------------------------------------------------

# $PSScriptRoot is the directory containing this script. Fall back for safety.
$scriptDir = $PSScriptRoot
$invocationPath = $null
$pathProperty = $MyInvocation.MyCommand.PSObject.Properties['Path']
if ($null -ne $pathProperty) {
    $invocationPath = [string]$pathProperty.Value
}
if ([string]::IsNullOrEmpty($scriptDir) -and -not [string]::IsNullOrEmpty($invocationPath)) {
    $scriptDir = Split-Path -Parent $invocationPath
}
if ([string]::IsNullOrEmpty($scriptDir)) {
    $scriptDir = (Get-Location).Path
}

if ((Split-Path -Leaf $scriptDir) -eq 'scripts') {
    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..')).Path
} else {
    $repoRoot = $scriptDir
}

$entryName = 'litellm-cost-map.js'
$libName   = 'litellm-cost-map-lib.mjs'
$rawBaseUrl = 'https://raw.githubusercontent.com/Vaca30/opencode-litellm-cost-map/main'

$entrySrc = Join-Path $repoRoot $entryName
$libSrc   = Join-Path $repoRoot $libName

# ---------------------------------------------------------------------------
# Resolve runtime source. Local clone wins; raw GitHub fallback enables the
# documented PowerShell one-liner without cloning first.
# ---------------------------------------------------------------------------

$localRuntimeFiles =
    (Test-Path -LiteralPath $entrySrc -PathType Leaf) -and
    (Test-Path -LiteralPath $libSrc   -PathType Leaf)

if ($localRuntimeFiles) {
    $sourceMode = 'local repo files'
} else {
    $sourceMode = 'remote GitHub raw files'
}

# ---------------------------------------------------------------------------
# Resolve the config directory per the documented priority
# ---------------------------------------------------------------------------

function Resolve-ConfigDir {
    param([string]$Override)

    if (-not [string]::IsNullOrEmpty($Override)) {
        return @{ Path = $Override; Source = 'explicit -ConfigDir' }
    }

    $openCfg = [Environment]::GetEnvironmentVariable('OPENCODE_CONFIG')
    if (-not [string]::IsNullOrEmpty($openCfg)) {
        # If it points to an existing file, use its directory.
        if (Test-Path -LiteralPath $openCfg -PathType Leaf) {
            return @{ Path = (Split-Path -Parent $openCfg); Source = 'OPENCODE_CONFIG (file)' }
        }
        # If it is an existing directory, use it directly.
        if (Test-Path -LiteralPath $openCfg -PathType Container) {
            return @{ Path = $openCfg; Source = 'OPENCODE_CONFIG (dir)' }
        }
        # Non-existent path: if it looks like a JSON file, treat parent as dir.
        if ([System.IO.Path]::GetExtension($openCfg)) {
            return @{ Path = (Split-Path -Parent $openCfg); Source = 'OPENCODE_CONFIG (file, not present)' }
        }
        return @{ Path = $openCfg; Source = 'OPENCODE_CONFIG (dir, not present)' }
    }

    $xdg = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME')
    if (-not [string]::IsNullOrEmpty($xdg)) {
        return @{ Path = (Join-Path $xdg 'opencode'); Source = 'XDG_CONFIG_HOME/opencode' }
    }

    $userProfile = [Environment]::GetEnvironmentVariable('USERPROFILE')
    if ([string]::IsNullOrEmpty($userProfile)) {
        $userProfile = $HOME
    }
    return @{ Path = (Join-Path $userProfile '.config\opencode'); Source = 'default ~/.config/opencode' }
}

$resolved   = Resolve-ConfigDir -Override $ConfigDir
$configDir  = $resolved.Path
$cfgSource  = $resolved.Source
$pluginDir  = Join-Path $configDir 'plugins'
$jsonPath   = Join-Path $configDir 'opencode.json'

# ---------------------------------------------------------------------------
# Summary header
# ---------------------------------------------------------------------------

Write-Host ''
Write-Info ("Repo root      : {0}" -f $repoRoot)
Write-Info ("Source mode    : {0}" -f $sourceMode)
Write-Info ("Config dir     : {0}  (source: {1})" -f $configDir, $cfgSource)
Write-Info ("Plugin dir     : {0}" -f $pluginDir)
Write-Info ("Reference mode : {0}" -f $(if ($Reference) { 'ON (will edit opencode.json)' } else { 'off (auto-discovery is enough)' }))
Write-Info ("Dry run        : {0}" -f $(if ($DryRun) { 'YES (no changes)' } else { 'no' }))
Write-Host ''

# ---------------------------------------------------------------------------
# Step 1: ensure plugin directory exists (create only if missing)
# ---------------------------------------------------------------------------

if (Test-Path -LiteralPath $pluginDir -PathType Container) {
    Write-Info ("Plugin directory already exists: {0}" -f $pluginDir)
} else {
    if ($DryRun) {
        Write-DryNote ("Would create plugin directory: {0}" -f $pluginDir)
    } else {
        New-Item -ItemType Directory -Path $pluginDir -Force | Out-Null
        Write-Action ("Created plugin directory: {0}" -f $pluginDir)
    }
}

# ---------------------------------------------------------------------------
# Step 2: copy ONLY the two runtime files (overwrite just those two)
# ---------------------------------------------------------------------------

$copyPairs = @(
    @{ Src = $entrySrc; Url = ("{0}/{1}" -f $rawBaseUrl, $entryName); Dst = (Join-Path $pluginDir $entryName); Name = $entryName },
    @{ Src = $libSrc;   Url = ("{0}/{1}" -f $rawBaseUrl, $libName);   Dst = (Join-Path $pluginDir $libName);   Name = $libName }
)

foreach ($pair in $copyPairs) {
    # Hard guard: never copy test files.
    if ($pair.Name -match '\.test\.(mjs|js|ts)$') {
        Write-Warn ("Skipping test file (never installed): {0}" -f $pair.Name)
        continue
    }
    if ($DryRun) {
        if ($sourceMode -eq 'local repo files') {
            Write-DryNote ("Would copy {0} -> {1}" -f $pair.Src, $pair.Dst)
        } else {
            Write-DryNote ("Would download {0} from {1} -> {2}" -f $pair.Name, $pair.Url, $pair.Dst)
        }
    } else {
        if ($sourceMode -eq 'local repo files') {
            Copy-Item -LiteralPath $pair.Src -Destination $pair.Dst -Force
            Write-Action ("Copied {0} -> {1}" -f $pair.Name, $pair.Dst)
        } else {
            Invoke-WebRequest -Uri $pair.Url -OutFile $pair.Dst -UseBasicParsing -ErrorAction Stop
            Write-Action ("Downloaded {0} -> {1}" -f $pair.Name, $pair.Dst)
        }
    }
}

# ---------------------------------------------------------------------------
# Step 3: optional reference into opencode.json (opt-in)
# ---------------------------------------------------------------------------

function Get-FileUrl {
    param([string]$Path)
    # Normalize to forward slashes and produce a file:// URL.
    $full = [System.IO.Path]::GetFullPath($Path)
    $normalized = $full -replace '\\', '/'
    if ($normalized -match '^[A-Za-z]:/') {
        # Windows drive path -> file:///C:/...
        return "file:///$normalized"
    }
    return "file://$normalized"
}

if ($Reference) {
    $entryInstalled = Join-Path $pluginDir $entryName
    $fileUrl = Get-FileUrl -Path $entryInstalled

    Write-Host ''
    Write-Info ("Reference target: {0}" -f $jsonPath)
    Write-Info ("Reference URL   : {0}" -f $fileUrl)

    if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
        $raw = Get-Content -LiteralPath $jsonPath -Raw -ErrorAction Stop
        $parsed = $null
        $valid = $true
        try {
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $valid = $false
        }

        if (-not $valid -or $null -eq $parsed) {
            Write-Warn ("opencode.json is not valid JSON; skipping reference step (copy already done). File left untouched: {0}" -f $jsonPath)
        } else {
            # Determine current plugin entries.
            $existing = @()
            $hasPluginKey = $false
            if ($parsed.PSObject.Properties.Name -contains 'plugin') {
                $hasPluginKey = $true
                if ($null -ne $parsed.plugin) {
                    $existing = @($parsed.plugin)
                }
            }

            $already = $false
            foreach ($p in $existing) {
                if ([string]$p -eq $fileUrl) { $already = $true; break }
            }

            if ($already) {
                Write-Info "Reference already present; nothing to change."
            } else {
                $newPlugins = @()
                $newPlugins += $existing
                $newPlugins += $fileUrl

                if ($DryRun) {
                    Write-DryNote ("Would back up {0} -> {0}.bak.<timestamp>" -f $jsonPath)
                    Write-DryNote ("Would add plugin reference: {0}" -f $fileUrl)
                } else {
                    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
                    $backup = "$jsonPath.bak.$stamp"
                    Copy-Item -LiteralPath $jsonPath -Destination $backup -Force
                    Write-Action ("Backed up opencode.json -> {0}" -f $backup)

                    if ($hasPluginKey) {
                        $parsed.plugin = $newPlugins
                    } else {
                        $parsed | Add-Member -MemberType NoteProperty -Name 'plugin' -Value $newPlugins
                    }

                    ($parsed | ConvertTo-Json -Depth 50) | Set-Content -LiteralPath $jsonPath -Encoding UTF8
                    Write-Action ("Added plugin reference to {0}" -f $jsonPath)
                }
            }
        }
    } else {
        # File does not exist -> create a minimal valid one.
        if ($DryRun) {
            Write-DryNote ("Would create {0} with plugin reference: {1}" -f $jsonPath, $fileUrl)
        } else {
            if (-not (Test-Path -LiteralPath $configDir -PathType Container)) {
                New-Item -ItemType Directory -Path $configDir -Force | Out-Null
                Write-Action ("Created config directory: {0}" -f $configDir)
            }
            $obj = [ordered]@{
                '$schema' = 'https://opencode.ai/config.json'
                'plugin'  = @($fileUrl)
            }
            ($obj | ConvertTo-Json -Depth 50) | Set-Content -LiteralPath $jsonPath -Encoding UTF8
            Write-Action ("Created {0} with plugin reference" -f $jsonPath)
        }
    }
} else {
    Write-Host ''
    Write-Info "Reference mode off: relying on OpenCode auto-discovery of plugins/*.js (recommended)."
}

# ---------------------------------------------------------------------------
# Next steps
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '=== NEXT STEPS ==='
Write-Host '  1. Restart OpenCode so it re-scans the plugins directory.'
Write-Host '  2. Run any prompt against a LiteLLM (openai-compatible) provider.'
Write-Host '  3. Verify the session cost is non-zero.'
Write-Host '     Run with --print-logs and look for the success line:'
Write-Host '       "Updated N model costs from LiteLLM"'
Write-Host ''

if ($DryRun) {
    Write-Info 'Dry run complete. No changes were made.'
} else {
    Write-Info 'Install complete.'
}

return
