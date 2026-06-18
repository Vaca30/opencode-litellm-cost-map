# opencode-litellm-cost-map

An OpenCode plugin that automatically injects LiteLLM model costs into the OpenCode runtime config for openai-compatible providers so that per-session cost is computed correctly.

## Why it exists

OpenCode computes the cost of a session locally, from token counts and the `model.cost` values in your configuration. The relevant formula (source: `packages/opencode/src/session/session.ts`) is:

```
cost = tokens.input      * model.cost.input        / 1_000_000
     + tokens.output     * model.cost.output       / 1_000_000
     + tokens.cache.read  * model.cost.cache_read   / 1_000_000
     + tokens.cache.write * model.cost.cache_write  / 1_000_000
     + tokens.reasoning   * model.cost.output       / 1_000_000
```

Two facts follow from this, and the plugin addresses both:

1. **OpenCode never reads the real request cost.** Even though LiteLLM can return the actual cost of a request, OpenCode ignores it. The only source of cost is `model.cost` multiplied by token counts. The price therefore has to be pre-filled into the configuration.
2. **The price unit is "per 1,000,000 tokens".** OpenCode divides by `1_000_000`, so `model.cost.input` must be expressed in USD per 1M tokens (the models.dev convention). LiteLLM, however, reports prices **per single token** (for example `input_cost_per_token: 3e-5`, which is $30 per 1M tokens). If a per-token value were placed into the config unchanged, OpenCode would divide it by a million again and the resulting cost would be effectively zero. The plugin scales every LiteLLM price by `1,000,000`.

## What it does

On OpenCode startup the plugin runs in the `config` hook and performs the following:

1. Scans every provider in the configuration and selects the ones that are LiteLLM-style, that is, a provider whose `npm` is `@ai-sdk/openai-compatible` **and** whose `options.baseURL` is a string.
2. For each selected provider it loads pricing from two sources:
   - the provider's own LiteLLM **`/public/model_hub`** endpoint (primary, unauthenticated), and
   - the **BerriAI upstream cost map** (`model_prices_and_context_window.json` on GitHub) as a fallback.
3. For each model in the provider config it finds the matching pricing entry (see [Model lookup order](#model-lookup-order)), converts every price from per-token to per-million, and updates `model.cost` in the in-memory OpenCode runtime config. It also fills in missing metadata, limits, and capabilities from the source entry.

The plugin never crashes startup. If a source cannot be fetched (offline, 403, TLS failure, HTML login page), it falls through to the next source and finally leaves the static `model.cost` from your configuration in place.

## Recommended production setup

Use a hybrid configuration approach. This plugin is a runtime refresh layer, not a replacement for a well-managed global or managed OpenCode config.

In production, keep your global config (`~/.config/opencode/opencode.json`) or managed config (`OPENCODE_CONFIG`, deployment-managed config, or equivalent) responsible for the security baseline:

- `enabled_providers` contains only the providers your organization allows.
- The LiteLLM provider contains only approved production models under `models`.
- Every production model has a static fallback `cost` in USD per 1M tokens.
- The plugin is allowed to refine those prices at startup from LiteLLM `/public/model_hub`.

The plugin does **not** rewrite `opencode.json` on disk. It runs in OpenCode's `config(cfg)` hook, mutates the already-loaded config object in memory, and must fetch prices again after every OpenCode restart. If LiteLLM is unavailable or a model has no matching price entry, OpenCode keeps the fallback `model.cost` already present in config.

```text
opencode.json / managed config
   ↓
OpenCode loads config into memory
   ↓
plugin config(cfg) hook runs
   ↓
plugin loads prices from LiteLLM /public/model_hub
   ↓
plugin updates model.cost in runtime config
   ↓
OpenCode calculates local session cost
```

Example production config:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "enabled_providers": ["litellm"],
  "model": "litellm/gpt-4o",
  "small_model": "litellm/gpt-4o-mini",
  "provider": {
    "litellm": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LiteLLM",
      "options": {
        "baseURL": "https://litellm.company.com/v1",
        "apiKey": "{env:LITELLM_API_KEY}"
      },
      "models": {
        "gpt-4o": {
          "cost": {
            "input": 5,
            "output": 15
          }
        },
        "gpt-4o-mini": {
          "cost": {
            "input": 0.15,
            "output": 0.6
          }
        },
        "claude-sonnet-4": {
          "cost": {
            "input": 3,
            "output": 15
          }
        }
      }
    }
  }
}
```

Treat the numbers above as fallback examples and replace them with your approved production price list. If the plugin finds a fresher value in LiteLLM, the runtime value is updated for that OpenCode process only.

## File layout

| File | Purpose |
|---|---|
| `litellm-cost-map.js` | Runtime entry point. Exports **only `default`**, and is `.js` **on purpose** so OpenCode's auto-discovery glob `{plugin,plugins}/*.{ts,js}` picks it up. |
| `litellm-cost-map-lib.mjs` | All plugin logic (URL building, header building, price conversion, indexing, fallback). It is `.mjs` **on purpose** so the glob does **not** match it and it is never loaded as a separate plugin; the `.js` entry still imports from it. |
| `litellm-cost-map.test.mjs` | Unit tests (Node test runner). **Never deploy this into a plugin directory** — see the note below. |
| `scripts/` | Installation helpers (`install.ps1`, `install.sh`). |
| `agents/` | Repository agent definitions used during development. |

> The auto-discovery glob is non-recursive (one level deep) and has **no test-file exclusion**: every `.js`/`.ts` file in the plugin directory is loaded as a plugin. Never place `litellm-cost-map.test.mjs` (or any `*.test.js` / `*.test.ts`) into a plugin directory. Keeping the logic in a `.mjs` file is what keeps it out of the glob while the `.js` entry can still import it.
>
> OpenCode's legacy loader calls **every export** of a plugin module as a plugin factory. That is why the entry exports only `default`; any extra export would be invoked as a plugin and would fail.

## Install

See [INSTALL.md](./INSTALL.md) for installation methods and full verification and troubleshooting steps.

### PowerShell one-liner

This downloads the installer from this repository, installs the two runtime plugin files, then starts OpenCode with logs visible:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/Vaca30/opencode-litellm-cost-map/main/scripts/install.ps1 | iex; if (Get-Command opencode -ErrorAction SilentlyContinue) { opencode --print-logs } else { 'OpenCode CLI not found on PATH. Restart OpenCode and run: opencode --print-logs' }"
```

When the script is not run from a local clone, the installer should print `Source mode    : remote GitHub raw files` and then `Install complete.` If OpenCode is on `PATH`, `opencode --print-logs` opens a fresh OpenCode process so the plugin can be loaded and its diagnostics are visible.

Local clone usage:

```powershell
# Windows PowerShell, from the repository root
.\scripts\install.ps1
```

```bash
# macOS / Linux, from the repository root
./scripts/install.sh
```

The installer copies only the two runtime files (`litellm-cost-map.js` and `litellm-cost-map-lib.mjs`) into your plugins directory. Restart OpenCode afterward.

## Provider configuration

The plugin activates for any provider that has `npm: "@ai-sdk/openai-compatible"` and a string `options.baseURL`. A generic openai-compatible provider looks like this:

```jsonc
{
  "provider": {
    "litellm": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LiteLLM",
      "options": {
        "baseURL": "https://litellm.example.com/",
        "apiKey": "{env:LITELLM_API_KEY}",
        "headers": {
          "x-openwebui-user-email": "you@example.com"
        }
      },
      "models": {
        "gpt-4o": {},
        "claude-sonnet": {}
      }
    }
  }
}
```

Header values support `{env:NAME}` placeholders, which are resolved from the environment when the hub request is built. Any headers you configure are also sent on the `/public/model_hub` request, so a provider behind a header-based gateway still resolves its model hub.

### Internal proxies with unverifiable TLS certificates

Some internal LiteLLM proxies serve a leaf certificate that the runtime cannot verify, producing `UNABLE_TO_VERIFY_LEAF_SIGNATURE`. The actual supported option is `insecureSkipTLSVerify: true` under that provider's `options`:

```jsonc
{
  "provider": {
    "litellm-internal": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Internal LiteLLM",
      "options": {
        "baseURL": "https://llm.internal.example.com/v1",
        "apiKey": "{env:LITELLM_API_KEY}",
        "headers": { "x-openwebui-user-email": "you@example.com" },
        "insecureSkipTLSVerify": true
      },
      "models": { "internal-model": {} }
    }
  }
}
```

`insecureSkipTLSVerify: true` skips certificate verification **only for that provider's hub fetch**; it never disables verification globally or for any other provider or the upstream cost map.

> Warning: use `insecureSkipTLSVerify: true` only for internal development or as a temporary workaround. Do not make it the production default. In production, fix the CA chain, install the correct corporate CA, or replace the certificate so normal TLS verification succeeds.

> `tls: { rejectUnauthorized: false }` is a Bun fetch extension. It works because OpenCode plugins run on Bun. It would not work in a standalone Node script.

## Provider options

| Key in `options` | Type | Meaning |
|---|---|---|
| `baseURL` | string | Base LiteLLM URL. Required to activate the plugin. The plugin derives `<base>/public/model_hub` from it, first stripping a trailing `/v1` from the path. |
| `headers` | object | Headers sent on the hub request. Values support the `{env:NAME}` placeholder. |
| `apiKey` | string | If set and fully resolved, added as `Authorization: Bearer ...`. Supports `{env:NAME}`. `/public/model_hub` usually does not require it. |
| `insecureSkipTLSVerify` | boolean | When `true`, skips TLS verification for this provider's hub fetch only. |

## Model lookup order

For each model in the provider config, the plugin builds candidate keys and searches with them. The keys are, in order:

1. the model key from the config (the key under `models`),
2. `model.id`,
3. the part after `/` (for example `vertex_ai/claude-opus-4-8` yields `claude-opus-4-8`).

For each candidate key the plugin checks the **LiteLLM hub index first**, then the **upstream map**. The first hit wins.

## `/public/model_hub` vs `/model/info`

The plugin uses `/public/model_hub` because it is unauthenticated.

| | `/public/model_hub` | `/model/info` |
|---|---|---|
| Auth | None | Requires an API key |
| Shape | Flat array: `[{ model_group, input_cost_per_token, ... }]` | `{ data: [{ model_name, model_info: { ... } }] }` |
| Model key field | `model_group` | `model_name` |
| Scope | Only models the proxy admin marked public | All models |

Because `/public/model_hub` lists only the model groups the proxy admin marked public, it **can be empty**. When the hub is empty or unreachable, the plugin falls back to the BerriAI upstream cost map and then to the static `model.cost` in the configuration.

## Static fallback costs

If a model is found in neither the hub nor the upstream map, the `model.cost` value already in the configuration is used as-is. **These static values must also be per-million** (USD per 1M tokens), otherwise that model's cost will be wrong. Example of a correct static fallback:

```jsonc
"cost": {
  "input": 5,
  "output": 30,
  "cache_read": 0.5,
  "context_over_200k": { "input": 10, "output": 45, "cache_read": 1 }
}
```

## How to verify

Restart OpenCode after installation or config changes, then run:

```powershell
opencode --print-logs
```

After OpenCode loads a config that contains a LiteLLM provider and models, expect a plugin line like:

```text
[litellm-cost-map] Updated N model costs from LiteLLM; M kept existing cost fallback
```

`Updated N` means `N` configured models received a runtime `model.cost` from LiteLLM `/public/model_hub` or the upstream cost map. `M kept existing cost fallback` means `M` configured models had no matching dynamic price, so their static `model.cost` from config stayed in place. If no LiteLLM provider or no models are configured, there may be no update line.

Success summaries are written to stdout. Fetch failures are written to stderr. `--print-logs` makes both visible.

| Message | Meaning |
|---|---|
| `[litellm-cost-map] Updated N model costs from LiteLLM; M kept existing cost fallback` | Success. `N` models received a price from a source; `M` kept their static fallback cost. |
| `[litellm-cost-map] Failed to load <url>: 403 Forbidden` | The hub requires auth or gateway headers that are missing. The plugin falls back to upstream/static. |
| `[litellm-cost-map] Failed to load <url>: ...JSON...` | The endpoint returned HTML instead of JSON, typically a gateway login page. Falls back to upstream/static. |
| `[litellm-cost-map] Failed to load <url>: ... UNABLE_TO_VERIFY_LEAF_SIGNATURE` | Unverifiable TLS certificate. Set `insecureSkipTLSVerify: true` for that provider. |
| `[litellm-cost-map] Failed to load <url>: fetch failed` | The endpoint is unreachable (network or VPN). Falls back to upstream/static. |
| `[litellm-cost-map] Failed to load upstream cost map: ...` | The BerriAI upstream map could not be fetched. Static config costs are used. |

To confirm cost works, restart OpenCode, run any prompt, and check the session cost. It should be non-zero and roughly match the model's price.

## Recommended production checklist

- Allowed providers are defined in global or managed OpenCode config, for example with `enabled_providers`.
- Production models are explicitly listed under the managed LiteLLM provider's `models` object.
- Every production model has a static fallback `cost` in USD per 1M tokens.
- LiteLLM `/public/model_hub` is reachable from the client environment that runs OpenCode.
- SSL certificates are valid and trusted by the OpenCode runtime.
- `insecureSkipTLSVerify: true` is used only temporarily or in internal/dev environments, never as the production default.
- Plugin logs are checked with `opencode --print-logs` after installation and after price/config changes.
- Closed environments have egress policy that prevents unapproved internet fallback access; static fallback prices cover missing hub data.

## Testing

The tests use the Node test runner, make no network calls, and require no npm dependencies:

```bash
node --test
```

or

```bash
npm test
```

They cover price-unit conversion, hub and upstream parsing, model lookup, fallback behavior, TLS opt-in, header building, URL building, and PowerShell installer bootstrap behavior. PowerShell installer tests run when `powershell` or `pwsh` is available.

## Development (TDD)

All logic lives in `litellm-cost-map-lib.mjs` and is tested by `litellm-cost-map.test.mjs`. When changing behavior:

1. Add or update a test first (RED).
2. Run `node --test` and confirm it fails for the right reason.
3. Implement the minimal change (GREEN).
4. Keep the entry point `litellm-cost-map.js` minimal — only the `default` export.

## Known limitations

- OpenCode never reads the real request cost from LiteLLM; the displayed cost is always a token-based estimate from the cost map. Small differences from LiteLLM's own billing are expected.
- `cache_write` is usually not populated for openai-compatible providers (the OpenAI wire format carries no cache-write token count), so that portion of the cost may be missing.
- `/public/model_hub` returns only public model groups; non-public models resolve through the upstream map or the static fallback.
