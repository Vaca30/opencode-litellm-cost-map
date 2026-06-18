#!/usr/bin/env bash
#
# install.sh - Non-destructive, idempotent installer for the OpenCode plugin
#              "opencode-litellm-cost-map" (POSIX bash; macOS/Linux).
#
# Copies the two runtime files (litellm-cost-map.js and litellm-cost-map-lib.mjs)
# from the repository root into the OpenCode plugins directory
# (<configDir>/plugins). The test file is never copied.
#
# OpenCode auto-discovers local plugins via the glob "{plugin,plugins}/*.{ts,js}",
# so once the entry file (litellm-cost-map.js) lives in <configDir>/plugins it is
# picked up automatically. The .mjs library is imported by the entry file (it is
# not auto-discovered on its own), so both files are copied.
#
# With default auto-discovery the --reference step is NOT needed. Reference mode
# is opt-in for users who prefer an explicit "plugin" entry in opencode.json or
# who use a non-standard config directory.
#
# Config dir resolution priority:
#   1. --config-dir <path>            (explicit override)
#   2. OPENCODE_CONFIG env var        (file -> its directory; dir -> used directly)
#   3. XDG_CONFIG_HOME/opencode       (if XDG_CONFIG_HOME is set)
#   4. Default: ~/.config/opencode
#
# Verify success: restart OpenCode, run a prompt, and confirm the session cost is
# non-zero. Use --print-logs and look for the line:
#   "Updated N model costs from LiteLLM".

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults / flags
# ---------------------------------------------------------------------------

REFERENCE=0
DRY_RUN=0
CONFIG_DIR_OVERRIDE=""

ENTRY_NAME="litellm-cost-map.js"
LIB_NAME="litellm-cost-map-lib.mjs"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

info()    { printf '[*] %s\n' "$1"; }
action()  { printf '[+] %s\n' "$1"; }
drynote() { printf '[dry-run] %s\n' "$1"; }
warn()    { printf '[!] %s\n' "$1" >&2; }
err()     { printf '[x] %s\n' "$1" >&2; }

usage() {
    cat <<'EOF'
install.sh - installer for opencode-litellm-cost-map

Usage:
  install.sh [--reference] [--dry-run] [--config-dir <path>] [--help]

Options:
  --reference          Add a file:// reference to the plugin in opencode.json
                       (opt-in; NOT required with default auto-discovery).
  --dry-run            Show what would happen; make no changes.
  --config-dir <path>  Explicit OpenCode config directory (overrides env vars).
  --help               Show this help.

Config dir resolution priority:
  1. --config-dir
  2. OPENCODE_CONFIG  (file -> its dir; dir -> used directly)
  3. XDG_CONFIG_HOME/opencode
  4. ~/.config/opencode
EOF
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

while [ "$#" -gt 0 ]; do
    case "$1" in
        --reference)
            REFERENCE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --config-dir)
            if [ "$#" -lt 2 ]; then
                err "--config-dir requires a path argument"
                exit 2
            fi
            CONFIG_DIR_OVERRIDE="$2"
            shift 2
            ;;
        --config-dir=*)
            CONFIG_DIR_OVERRIDE="${1#*=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            err "Unknown argument: $1"
            usage
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Self-locate the repository root (this script lives in <repo>/scripts)
# ---------------------------------------------------------------------------

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
# Resolve directory of the script (handle relative invocation).
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd -P)"

ENTRY_SRC="$REPO_ROOT/$ENTRY_NAME"
LIB_SRC="$REPO_ROOT/$LIB_NAME"

# ---------------------------------------------------------------------------
# Validate runtime files exist next to the repo root
# ---------------------------------------------------------------------------

MISSING=""
[ -f "$ENTRY_SRC" ] || MISSING="$MISSING $ENTRY_NAME"
[ -f "$LIB_SRC" ]   || MISSING="$MISSING $LIB_NAME"

if [ -n "$MISSING" ]; then
    err "Required runtime file(s) not found in repo root '$REPO_ROOT':$MISSING"
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve the config directory per the documented priority
# ---------------------------------------------------------------------------

CONFIG_DIR=""
CFG_SOURCE=""

if [ -n "$CONFIG_DIR_OVERRIDE" ]; then
    CONFIG_DIR="$CONFIG_DIR_OVERRIDE"
    CFG_SOURCE="explicit --config-dir"
elif [ -n "${OPENCODE_CONFIG:-}" ]; then
    if [ -f "$OPENCODE_CONFIG" ]; then
        CONFIG_DIR="$(cd "$(dirname "$OPENCODE_CONFIG")" >/dev/null 2>&1 && pwd -P)"
        CFG_SOURCE="OPENCODE_CONFIG (file)"
    elif [ -d "$OPENCODE_CONFIG" ]; then
        CONFIG_DIR="$(cd "$OPENCODE_CONFIG" >/dev/null 2>&1 && pwd -P)"
        CFG_SOURCE="OPENCODE_CONFIG (dir)"
    else
        # Non-existent path: if it looks like a file (has an extension after the
        # last slash), treat its parent as the config dir; otherwise as a dir.
        base="$(basename "$OPENCODE_CONFIG")"
        case "$base" in
            *.*)
                CONFIG_DIR="$(dirname "$OPENCODE_CONFIG")"
                CFG_SOURCE="OPENCODE_CONFIG (file, not present)"
                ;;
            *)
                CONFIG_DIR="$OPENCODE_CONFIG"
                CFG_SOURCE="OPENCODE_CONFIG (dir, not present)"
                ;;
        esac
    fi
elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
    CONFIG_DIR="$XDG_CONFIG_HOME/opencode"
    CFG_SOURCE="XDG_CONFIG_HOME/opencode"
else
    CONFIG_DIR="${HOME}/.config/opencode"
    CFG_SOURCE="default ~/.config/opencode"
fi

PLUGIN_DIR="$CONFIG_DIR/plugins"
JSON_PATH="$CONFIG_DIR/opencode.json"

# ---------------------------------------------------------------------------
# Summary header
# ---------------------------------------------------------------------------

printf '\n'
info "Repo root      : $REPO_ROOT"
info "Config dir     : $CONFIG_DIR  (source: $CFG_SOURCE)"
info "Plugin dir     : $PLUGIN_DIR"
if [ "$REFERENCE" -eq 1 ]; then
    info "Reference mode : ON (will edit opencode.json)"
else
    info "Reference mode : off (auto-discovery is enough)"
fi
if [ "$DRY_RUN" -eq 1 ]; then
    info "Dry run        : YES (no changes)"
else
    info "Dry run        : no"
fi
printf '\n'

# ---------------------------------------------------------------------------
# Step 1: ensure plugin directory exists (create only if missing)
# ---------------------------------------------------------------------------

if [ -d "$PLUGIN_DIR" ]; then
    info "Plugin directory already exists: $PLUGIN_DIR"
else
    if [ "$DRY_RUN" -eq 1 ]; then
        drynote "Would create plugin directory: $PLUGIN_DIR"
    else
        mkdir -p "$PLUGIN_DIR"
        action "Created plugin directory: $PLUGIN_DIR"
    fi
fi

# ---------------------------------------------------------------------------
# Step 2: copy ONLY the two runtime files (overwrite just those two)
# ---------------------------------------------------------------------------

copy_one() {
    # $1 = source path, $2 = dest path, $3 = file name
    local src="$1" dst="$2" name="$3"
    case "$name" in
        *.test.mjs|*.test.js|*.test.ts)
            warn "Skipping test file (never installed): $name"
            return 0
            ;;
    esac
    if [ "$DRY_RUN" -eq 1 ]; then
        drynote "Would copy $src -> $dst"
    else
        cp -f "$src" "$dst"
        action "Copied $name -> $dst"
    fi
}

copy_one "$ENTRY_SRC" "$PLUGIN_DIR/$ENTRY_NAME" "$ENTRY_NAME"
copy_one "$LIB_SRC"   "$PLUGIN_DIR/$LIB_NAME"   "$LIB_NAME"

# ---------------------------------------------------------------------------
# Step 3: optional reference into opencode.json (opt-in)
# ---------------------------------------------------------------------------

make_file_url() {
    # Produce a file:// URL for an absolute POSIX path.
    # $1 = absolute path
    printf 'file://%s' "$1"
}

if [ "$REFERENCE" -eq 1 ]; then
    ENTRY_INSTALLED="$PLUGIN_DIR/$ENTRY_NAME"
    FILE_URL="$(make_file_url "$ENTRY_INSTALLED")"

    printf '\n'
    info "Reference target: $JSON_PATH"
    info "Reference URL   : $FILE_URL"

    if [ -f "$JSON_PATH" ]; then
        # Validate JSON first (prefer node since this is a Node plugin).
        json_valid=0
        if command -v node >/dev/null 2>&1; then
            if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$JSON_PATH" >/dev/null 2>&1; then
                json_valid=1
            fi
        else
            # Without node we cannot reliably validate; assume not-validatable.
            json_valid=2
        fi

        if [ "$json_valid" -eq 0 ]; then
            warn "opencode.json is not valid JSON; skipping reference step (copy already done). File left untouched: $JSON_PATH"
        elif [ "$json_valid" -eq 1 ]; then
            # node available and JSON valid -> safe additive edit via node.
            if [ "$DRY_RUN" -eq 1 ]; then
                # Check whether the reference already exists for an accurate message.
                if node -e '
                    const fs=require("fs");
                    const p=process.argv[1], url=process.argv[2];
                    const j=JSON.parse(fs.readFileSync(p,"utf8"));
                    const arr=Array.isArray(j.plugin)?j.plugin:[];
                    process.exit(arr.includes(url)?0:1);
                ' "$JSON_PATH" "$FILE_URL" >/dev/null 2>&1; then
                    info "Reference already present; nothing to change."
                else
                    drynote "Would back up $JSON_PATH -> $JSON_PATH.bak.<timestamp>"
                    drynote "Would add plugin reference: $FILE_URL"
                fi
            else
                STAMP="$(date +%Y%m%d%H%M%S)"
                node -e '
                    const fs=require("fs");
                    const p=process.argv[1], url=process.argv[2], stamp=process.argv[3];
                    const raw=fs.readFileSync(p,"utf8");
                    const j=JSON.parse(raw);
                    if(!Array.isArray(j.plugin)) j.plugin = (j.plugin==null?[]:[j.plugin]);
                    if(j.plugin.includes(url)){
                        console.log("[*] Reference already present; nothing to change.");
                        process.exit(0);
                    }
                    fs.copyFileSync(p, p + ".bak." + stamp);
                    console.log("[+] Backed up opencode.json -> " + p + ".bak." + stamp);
                    j.plugin.push(url);
                    fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
                    console.log("[+] Added plugin reference to " + p);
                ' "$JSON_PATH" "$FILE_URL" "$STAMP"
            fi
        else
            # node not available: only safe to act if the "plugin" key is absent.
            if grep -q '"plugin"' "$JSON_PATH"; then
                warn "node not found and a \"plugin\" key already exists; cannot safely edit JSON. Skipping reference step (copy already done)."
                warn "Add this entry manually to the \"plugin\" array in $JSON_PATH:"
                warn "  $FILE_URL"
            else
                if [ "$DRY_RUN" -eq 1 ]; then
                    drynote "node not found; would back up $JSON_PATH and append a \"plugin\" key with: $FILE_URL"
                else
                    STAMP="$(date +%Y%m%d%H%M%S)"
                    cp -f "$JSON_PATH" "$JSON_PATH.bak.$STAMP"
                    action "Backed up opencode.json -> $JSON_PATH.bak.$STAMP"
                    warn "node not found; performing a careful append of a \"plugin\" key."
                    warn "Please review $JSON_PATH afterwards."
                    # Insert a "plugin" key right after the opening brace.
                    tmp="$JSON_PATH.tmp.$STAMP"
                    awk -v url="$FILE_URL" '
                        NR==1 && $0 ~ /\{/ && !done {
                            sub(/\{/, "{\n  \"plugin\": [\"" url "\"],", $0)
                            done=1
                        }
                        { print }
                    ' "$JSON_PATH" > "$tmp"
                    mv -f "$tmp" "$JSON_PATH"
                    action "Appended \"plugin\" key to $JSON_PATH"
                fi
            fi
        fi
    else
        # File does not exist -> create a minimal valid one.
        if [ "$DRY_RUN" -eq 1 ]; then
            drynote "Would create $JSON_PATH with plugin reference: $FILE_URL"
        else
            mkdir -p "$CONFIG_DIR"
            cat > "$JSON_PATH" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "plugin": ["$FILE_URL"]
}
EOF
            action "Created $JSON_PATH with plugin reference"
        fi
    fi
else
    printf '\n'
    info "Reference mode off: relying on OpenCode auto-discovery of plugins/*.js (recommended)."
fi

# ---------------------------------------------------------------------------
# Next steps
# ---------------------------------------------------------------------------

printf '\n'
printf '=== NEXT STEPS ===\n'
printf '  1. Restart OpenCode so it re-scans the plugins directory.\n'
printf '  2. Run any prompt against a LiteLLM (openai-compatible) provider.\n'
printf '  3. Verify the session cost is non-zero.\n'
printf '     Run with --print-logs and look for the success line:\n'
printf '       "Updated N model costs from LiteLLM"\n'
printf '\n'

if [ "$DRY_RUN" -eq 1 ]; then
    info "Dry run complete. No changes were made."
else
    info "Install complete."
fi

exit 0
