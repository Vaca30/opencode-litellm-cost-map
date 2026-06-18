# Installing opencode-litellm-cost-map

OpenCode auto-discovers local plugins with the glob `{plugin,plugins}/*.{ts,js}` in each config directory. This has a few consequences that drive how you install this plugin:

- The plugin directory is `plugins/` (plural) in the current convention. The singular `plugin/` still works for backward compatibility, but prefer the plural form.
- Config directories that are scanned:
  - global: `~/.config/opencode/plugins/` (on Windows: `%USERPROFILE%\.config\opencode\plugins\`)
  - project: `.opencode/plugins/`
- Only `.js` and `.ts` files are auto-discovered, and only one level deep. The runtime entry `litellm-cost-map.js` is therefore `.js`, while the logic file `litellm-cost-map-lib.mjs` is `.mjs` so it is **not** auto-loaded as a separate plugin (the `.js` entry imports it).
- The glob has **no test-file exclusion**. Never place `litellm-cost-map.test.mjs` (or any `*.test.js` / `*.test.ts`) into a plugin directory, or OpenCode will try to load it as a plugin.

After any installation method, **restart OpenCode** so the plugin is loaded.

## Method 1 — In-project installer script (recommended)

Clone the repository and run the bundled installer from the repository root.

```powershell
# Windows PowerShell
.\scripts\install.ps1
```

```bash
# macOS / Linux
./scripts/install.sh
```

The installer is non-destructive and idempotent. It copies only the two runtime files (`litellm-cost-map.js` and `litellm-cost-map-lib.mjs`) into your plugins directory, never touches your existing configuration, and never copies the test file.

Available flags (identical contract on both platforms):

| PowerShell | bash | Meaning |
|---|---|---|
| `-DryRun` | `--dry-run` | Print every action that would be taken and make zero changes. |
| `-ConfigDir <path>` | `--config-dir <path>` | Explicit OpenCode config directory (overrides `OPENCODE_CONFIG` / `XDG_CONFIG_HOME` / default). The plugin is installed into `<path>/plugins`. |
| `-Reference` | `--reference` | Opt-in. Also add a `file://` reference to the plugin in `opencode.json` (backed up first, additive only). Not required with default auto-discovery. |
| `-Help` | `--help` | Show usage. |

```powershell
# Preview only, no changes
.\scripts\install.ps1 -DryRun

# Install into a custom config directory
.\scripts\install.ps1 -ConfigDir "D:\opencode-config"

# Also register the plugin explicitly in opencode.json (optional)
.\scripts\install.ps1 -Reference
```

```bash
# Preview only, no changes
./scripts/install.sh --dry-run

# Install into a custom config directory
./scripts/install.sh --config-dir "/opt/opencode-config"

# Also register the plugin explicitly in opencode.json (optional)
./scripts/install.sh --reference
```

By default (no `-Reference`/`--reference`) the installer makes no config changes at all — it relies on OpenCode auto-discovering `plugins/*.js`.

## Method 2 — Manual copy

Create the plugins directory and copy **only** the two runtime files into it.

```powershell
# Windows PowerShell
$dst = "$env:USERPROFILE\.config\opencode\plugins"
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item .\litellm-cost-map.js, .\litellm-cost-map-lib.mjs $dst -Force
```

```bash
# macOS / Linux
dst="$HOME/.config/opencode/plugins"
mkdir -p "$dst"
cp ./litellm-cost-map.js ./litellm-cost-map-lib.mjs "$dst"/
```

> Do **not** copy `litellm-cost-map.test.mjs` into the plugins directory. While `.mjs` files are not matched by the discovery glob, keeping test files out of any plugin directory avoids accidental loading if they are later renamed to `.js`.

Restart OpenCode afterward.

## Method 3 — Reference from opencode.json

Instead of copying files, reference the entry file directly from your `opencode.json` `plugin` array using an absolute `file://` path to `litellm-cost-map.js`:

```jsonc
{
  "plugin": [
    "file:///absolute/path/to/opencode-litellm-cost-map/litellm-cost-map.js"
  ]
}
```

This works for both the CLI and the desktop app and needs no manual copy. The `plugin` array also accepts other reference forms: a bare npm name, a scoped npm name, a versioned `pkg@x.y.z`, and a `./relative` path resolved against the config file.

> Experimental: a `github:Vaca30/opencode-litellm-cost-map` git reference may work, because OpenCode parses the `plugin` array with npm-package-arg (which understands git refs). This path is undocumented and untested end-to-end, so treat it as "may work" rather than a supported method.

## Verification

1. Restart OpenCode.
2. Run any prompt and check the session cost — it should be non-zero and roughly match the model's price.
3. To see the plugin's diagnostic output, run OpenCode with `--print-logs` and look for the success line:

   ```
   [litellm-cost-map] Updated N model costs from LiteLLM; M kept existing cost fallback
   ```

   `N` is the number of models that received a price; `M` is the number that kept their static fallback cost.

## Troubleshooting

| Symptom (log line) | Cause | Fix |
|---|---|---|
| `Failed to load <url>: 403 Forbidden` | The hub requires auth or gateway headers that are missing. | Add the required `headers` (for example gateway access headers) to the provider's `options`. The plugin falls back to upstream/static meanwhile. |
| `Failed to load <url>: ...JSON...` | The endpoint returned HTML/JSON it could not parse, typically a gateway login page. | Provide the correct gateway headers so the hub returns JSON. Falls back to upstream/static. |
| `Failed to load <url>: ... UNABLE_TO_VERIFY_LEAF_SIGNATURE` | The proxy serves an unverifiable TLS leaf certificate. | Set `insecureSkipTLSVerify: true` in that provider's `options`. |
| `Failed to load <url>: fetch failed` | The endpoint is unreachable (network or VPN). | Connect to the network/VPN. Falls back to upstream/static. |
| Empty hub (no models priced from the hub) | `/public/model_hub` lists only public model groups and may be empty. | No action needed; the plugin falls back to the upstream cost map and then to your static config costs. |

## Uninstall

- If you installed by copying files: delete `litellm-cost-map.js` and `litellm-cost-map-lib.mjs` from the plugins directory.
- If you referenced the plugin from `opencode.json`: remove the entry from the `plugin` array.

Restart OpenCode afterward.
