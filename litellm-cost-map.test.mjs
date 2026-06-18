import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { copyFileSync, mkdirSync, mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import test from "node:test"

import {
  applyCosts,
  buildLiteLlmModelHubUrl,
  buildRequestHeaders,
  costFromLiteLlmInfo,
  findCostInfo,
  indexLiteLlmModelHub,
  normalizeModelConfig,
  normalizeBaseUrl,
  resolveTemplate,
  tlsFetchOptions,
} from "./litellm-cost-map-lib.mjs"
import * as pluginModule from "./litellm-cost-map.js"

const testDir = dirname(fileURLToPath(import.meta.url))

function findPowerShell() {
  for (const command of ["powershell", "pwsh"]) {
    const result = spawnSync(command, ["-NoProfile", "-Command", "$PSVersionTable.PSVersion.Major"], {
      encoding: "utf8",
    })
    if (result.status === 0) return command
  }
  return undefined
}

function psQuote(value) {
  return `'${String(value).replaceAll("'", "''")}'`
}

test("runtime plugin module only exports the plugin entrypoint", () => {
  assert.deepEqual(Object.keys(pluginModule), ["default"])
})

test("runtime plugin writes success summary to stdout instead of stderr", async () => {
  const originalFetch = globalThis.fetch
  const originalLog = console.log
  const originalError = console.error
  const logs = []
  const errors = []

  globalThis.fetch = async (url) => {
    const href = String(url)
    if (href.includes("/public/model_hub")) {
      return Response.json([
        {
          model_group: "priced",
          input_cost_per_token: 0.000001,
          output_cost_per_token: 0.000002,
        },
      ])
    }
    return Response.json({})
  }
  console.log = (...args) => logs.push(args.join(" "))
  console.error = (...args) => errors.push(args.join(" "))

  try {
    const plugin = await pluginModule.default()
    await plugin.config({
      provider: {
        litellm: {
          npm: "@ai-sdk/openai-compatible",
          options: { baseURL: "https://litellm.example.com/v1" },
          models: { priced: {} },
        },
      },
    })

    assert.deepEqual(errors, [])
    assert.deepEqual(logs, ["[litellm-cost-map] Updated 1 model costs from LiteLLM; 0 kept existing cost fallback"])
  } finally {
    globalThis.fetch = originalFetch
    console.log = originalLog
    console.error = originalError
  }
})

test("PowerShell installer dry-run can bootstrap runtime files from GitHub when not run from a clone", { skip: !findPowerShell() }, () => {
  const powershell = findPowerShell()
  const tempRoot = mkdtempSync(join(tmpdir(), "litellm-cost-map-install-"))
  try {
    const scriptDir = join(tempRoot, "scripts")
    mkdirSync(scriptDir, { recursive: true })
    const scriptPath = join(scriptDir, "install.ps1")
    copyFileSync(join(testDir, "scripts", "install.ps1"), scriptPath)

    const result = spawnSync(
      powershell,
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPath, "-DryRun", "-ConfigDir", join(tempRoot, "config")],
      { encoding: "utf8" },
    )

    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
    assert.match(result.stdout, /Source mode\s+: remote GitHub raw files/)
    assert.match(result.stdout, /Would download litellm-cost-map\.js/)
    assert.match(result.stdout, /Would download litellm-cost-map-lib\.mjs/)
  } finally {
    rmSync(tempRoot, { recursive: true, force: true })
  }
})

test("PowerShell installer scriptblock invocation returns control to the caller", { skip: !findPowerShell() }, () => {
  const powershell = findPowerShell()
  const tempRoot = mkdtempSync(join(tmpdir(), "litellm-cost-map-install-"))
  try {
    const scriptDir = join(tempRoot, "scripts")
    mkdirSync(scriptDir, { recursive: true })
    const scriptPath = join(scriptDir, "install.ps1")
    copyFileSync(join(testDir, "scripts", "install.ps1"), scriptPath)

    const command = [
      `$script = Get-Content -Raw -LiteralPath ${psQuote(scriptPath)}`,
      `& ([scriptblock]::Create($script)) -DryRun -ConfigDir ${psQuote(join(tempRoot, "config"))}`,
      "'after-installer'",
    ].join("; ")

    const result = spawnSync(powershell, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command], {
      encoding: "utf8",
    })

    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
    assert.match(result.stdout, /after-installer/)
  } finally {
    rmSync(tempRoot, { recursive: true, force: true })
  }
})

test("PowerShell installer pipeline invocation returns control to the caller", { skip: !findPowerShell() }, () => {
  const powershell = findPowerShell()
  const tempRoot = mkdtempSync(join(tmpdir(), "litellm-cost-map-install-"))
  try {
    const command = [
      `$env:OPENCODE_CONFIG = ${psQuote(join(tempRoot, "config"))}`,
      `Get-Content -Raw -LiteralPath ${psQuote(join(testDir, "scripts", "install.ps1"))} | Invoke-Expression`,
      "'after-installer'",
    ].join("; ")

    const result = spawnSync(powershell, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command], {
      cwd: testDir,
      encoding: "utf8",
    })

    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
    assert.match(result.stdout, /after-installer/)
  } finally {
    rmSync(tempRoot, { recursive: true, force: true })
  }
})

test("tlsFetchOptions disables TLS verification only when provider opts in", () => {
  // Some internal LiteLLM proxies serve a leaf cert that Node/Bun cannot verify.
  // Providers can opt into skipping verification per-request; default stays secure.
  assert.deepEqual(tlsFetchOptions({ options: {} }), {})
  assert.deepEqual(tlsFetchOptions({ options: { insecureSkipTLSVerify: false } }), {})
  assert.deepEqual(tlsFetchOptions({ options: { insecureSkipTLSVerify: true } }), {
    tls: { rejectUnauthorized: false },
  })
})

test("buildLiteLlmModelHubUrl targets the unauthenticated /public/model_hub endpoint", () => {
  assert.equal(buildLiteLlmModelHubUrl("https://litellm.example.com/"), "https://litellm.example.com/public/model_hub")
  assert.equal(buildLiteLlmModelHubUrl("https://litellm.example.com/v1"), "https://litellm.example.com/public/model_hub")
  assert.equal(buildLiteLlmModelHubUrl("https://litellm.example.com/proxy/v1/"), "https://litellm.example.com/proxy/public/model_hub")
})

test("indexLiteLlmModelHub maps the flat /public/model_hub array keyed by model_group", () => {
  const index = indexLiteLlmModelHub([
    {
      model_group: "gemini-2.5-flash",
      providers: ["vertex_ai"],
      max_input_tokens: 1048576,
      max_output_tokens: 65535,
      input_cost_per_token: 3e-7,
      output_cost_per_token: 2.5e-6,
      supports_vision: true,
      supports_reasoning: true,
      supports_function_calling: true,
    },
  ])

  assert.deepEqual(Array.from(index.keys()), ["gemini-2.5-flash"])
  const info = index.get("gemini-2.5-flash")
  assert.equal(info.input_cost_per_token, 3e-7)
  assert.equal(info.output_cost_per_token, 2.5e-6)
  assert.equal(info.max_input_tokens, 1048576)
})

test("costFromLiteLlmInfo converts LiteLLM per-token prices to opencode per-million-token costs", () => {
  // opencode computes cost as tokens * cost / 1_000_000, so model.cost.* must be USD per 1M tokens.
  // LiteLLM reports USD per single token, so every field must be scaled by 1_000_000.
  assert.deepEqual(
    costFromLiteLlmInfo({
      input_cost_per_token: 0.000003,
      output_cost_per_token: 0.000015,
      cache_read_input_token_cost: 0.0000003,
      cache_creation_input_token_cost: 0.00000375,
      input_cost_per_token_above_200k_tokens: 0.000006,
      output_cost_per_token_above_200k_tokens: 0.0000225,
      cache_read_input_token_cost_above_200k_tokens: 0.0000006,
      cache_creation_input_token_cost_above_200k_tokens: 0.0000075,
    }),
    {
      input: 3,
      output: 15,
      cache_read: 0.3,
      cache_write: 3.75,
      context_over_200k: {
        input: 6,
        output: 22.5,
        cache_read: 0.6,
        cache_write: 7.5,
      },
    },
  )
})

test("findCostInfo prefers LiteLLM proxy model info over upstream fallback", () => {
  const proxy = new Map([
    ["alias-model", { input_cost_per_token: 0.1, output_cost_per_token: 0.2 }],
    ["real-model", { input_cost_per_token: 0.3, output_cost_per_token: 0.4 }],
  ])
  const upstream = new Map([["alias-model", { input_cost_per_token: 9, output_cost_per_token: 9 }]])

  assert.deepEqual(findCostInfo("alias-model", { id: "real-model" }, proxy, upstream), {
    input_cost_per_token: 0.1,
    output_cost_per_token: 0.2,
  })
})

test("findCostInfo can use model id and provider-prefixed keys", () => {
  const upstream = new Map([["vertex_ai/claude-opus-4-8", { input_cost_per_token: 0.1, output_cost_per_token: 0.2 }]])
  assert.deepEqual(findCostInfo("claude-opus-4-8", { id: "vertex_ai/claude-opus-4-8" }, new Map(), upstream), {
    input_cost_per_token: 0.1,
    output_cost_per_token: 0.2,
  })
})

test("applyCosts mutates configured model costs and preserves fallback when missing", () => {
  const cfg = {
    provider: {
      litellm: {
        npm: "@ai-sdk/openai-compatible",
        options: { baseURL: "https://litellm.example.com/v1" },
        models: {
          priced: { cost: { input: 1, output: 1 } },
          unpriced: { cost: { input: 2, output: 2 } },
        },
      },
    },
  }
  const sources = new Map([
    ["litellm", { proxy: new Map([["priced", { input_cost_per_token: 0.000001, output_cost_per_token: 0.000002 }]]), upstream: new Map() }],
  ])

  const result = applyCosts(cfg, sources)

  assert.equal(result.updated, 1)
  assert.equal(result.missing, 1)
  assert.deepEqual(cfg.provider.litellm.models.priced.cost, { input: 1, output: 2 })
  assert.deepEqual(cfg.provider.litellm.models.unpriced.cost, { input: 2, output: 2 })
})

test("normalizeModelConfig fills required opencode model defaults from LiteLLM info", () => {
  const model = {}
  normalizeModelConfig("alias-model", model, {
    key: "upstream-model",
    max_input_tokens: 1000,
    max_output_tokens: 200,
    supports_function_calling: true,
    supports_reasoning: true,
    supports_vision: true,
  })

  assert.equal(model.id, "upstream-model")
  assert.equal(model.name, "alias-model")
  assert.deepEqual(model.limit, { context: 1000, output: 200 })
  assert.equal(model.attachment, true)
  assert.equal(model.reasoning, true)
  assert.equal(model.temperature, true)
  assert.equal(model.tool_call, true)
})

test("buildRequestHeaders resolves env api keys and merges provider headers", () => {
  const headers = buildRequestHeaders(
    {
      options: {
        apiKey: "{env:LITELLM_TEST_KEY}",
        headers: { "x-openwebui-user-email": "test@example.com" },
      },
    },
    { LITELLM_TEST_KEY: "sk-test" },
  )

  assert.equal(headers.authorization, "Bearer sk-test")
  assert.equal(headers["x-openwebui-user-email"], "test@example.com")
})

test("resolveTemplate resolves env placeholders and leaves unknown placeholders unchanged", () => {
  assert.equal(resolveTemplate("{env:KNOWN}", { KNOWN: "value" }), "value")
  assert.equal(resolveTemplate("Bearer {env:KNOWN}", { KNOWN: "value" }), "Bearer value")
  assert.equal(resolveTemplate("{env:UNKNOWN}", {}), "{env:UNKNOWN}")
})

test("normalizeBaseUrl returns undefined for invalid URLs", () => {
  assert.equal(normalizeBaseUrl("not a url"), undefined)
})
