const UPSTREAM_COST_MAP_URL =
  "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"

const OPENAI_COMPATIBLE_PROVIDER = "@ai-sdk/openai-compatible"

function resolveTemplate(value, env = process.env) {
  if (typeof value !== "string") return value
  return value.replace(/\{env:([^}]+)\}/g, (match, name) => {
    const resolved = env[name]
    return resolved === undefined ? match : resolved
  })
}

function normalizeBaseUrl(baseURL) {
  if (typeof baseURL !== "string" || baseURL.trim() === "") return undefined
  try {
    const url = new URL(resolveTemplate(baseURL))
    url.pathname = url.pathname.replace(/\/+$/, "")
    return url
  } catch {
    return undefined
  }
}

function buildLiteLlmModelHubUrl(baseURL) {
  const url = normalizeBaseUrl(baseURL)
  if (!url) return undefined
  url.pathname = url.pathname.replace(/\/v1$/, "")
  // /public/model_hub is served without authentication, so it works behind Cloudflare Access
  // (with the configured CF-Access headers) and without a LiteLLM API key.
  url.pathname = `${url.pathname}/public/model_hub`.replace(/\/+/g, "/")
  return url.toString()
}

function buildRequestHeaders(provider, env = process.env) {
  const headers = {}
  const configured = provider?.options?.headers
  if (configured && typeof configured === "object") {
    for (const [key, value] of Object.entries(configured)) {
      if (typeof value === "string") headers[key] = resolveTemplate(value, env)
    }
  }

  const apiKey = resolveTemplate(provider?.options?.apiKey, env)
  if (typeof apiKey === "string" && apiKey.trim() !== "" && !apiKey.includes("{env:")) {
    headers.authorization = apiKey.toLowerCase().startsWith("bearer ") ? apiKey : `Bearer ${apiKey}`
  }
  return headers
}

// Some internal LiteLLM proxies serve a leaf certificate that the runtime cannot verify
// (UNABLE_TO_VERIFY_LEAF_SIGNATURE). Providers may opt into skipping verification per-request via
// `options.insecureSkipTLSVerify: true`; this never disables verification globally for other requests.
function tlsFetchOptions(provider) {
  return provider?.options?.insecureSkipTLSVerify === true ? { tls: { rejectUnauthorized: false } } : {}
}

function finite(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined
}

// opencode computes cost as `tokens * model.cost.* / 1_000_000`, so model.cost.* must be USD per 1M
// tokens (the models.dev convention). LiteLLM reports USD per single token, so scale every price by 1e6.
const TOKENS_PER_MILLION = 1_000_000

function perMillion(value) {
  const num = finite(value)
  return num === undefined ? undefined : num * TOKENS_PER_MILLION
}

function costFromLiteLlmInfo(info) {
  const input = perMillion(info?.input_cost_per_token)
  const output = perMillion(info?.output_cost_per_token)
  if (input === undefined || output === undefined) return undefined

  const cost = { input, output }
  const cacheRead = perMillion(info.cache_read_input_token_cost)
  const cacheWrite = perMillion(info.cache_creation_input_token_cost)
  if (cacheRead !== undefined) cost.cache_read = cacheRead
  if (cacheWrite !== undefined) cost.cache_write = cacheWrite

  const over200kInput = perMillion(info.input_cost_per_token_above_200k_tokens)
  const over200kOutput = perMillion(info.output_cost_per_token_above_200k_tokens)
  if (over200kInput !== undefined && over200kOutput !== undefined) {
    cost.context_over_200k = {
      input: over200kInput,
      output: over200kOutput,
    }
    const over200kCacheRead = perMillion(info.cache_read_input_token_cost_above_200k_tokens)
    const over200kCacheWrite = perMillion(info.cache_creation_input_token_cost_above_200k_tokens)
    if (over200kCacheRead !== undefined) cost.context_over_200k.cache_read = over200kCacheRead
    if (over200kCacheWrite !== undefined) cost.context_over_200k.cache_write = over200kCacheWrite
  }

  return cost
}

function normalizeModelConfig(modelID, model, info) {
  if (!model || typeof model !== "object") return
  const key = typeof info?.key === "string" && info.key.trim() !== "" ? info.key : undefined
  const apiID = typeof model.id === "string" && model.id.trim() !== "" ? model.id : key || modelID
  model.id = apiID
  if (!model.name) model.name = modelID
  if (!model.limit) model.limit = {}
  const context = finite(info?.max_input_tokens) ?? finite(info?.max_tokens)
  const output = finite(info?.max_output_tokens) ?? finite(info?.max_tokens)
  if (context !== undefined && model.limit.context === undefined) model.limit.context = context
  if (output !== undefined && model.limit.output === undefined) model.limit.output = output
  if (model.limit.context === undefined) model.limit.context = 128000
  if (model.limit.output === undefined) model.limit.output = 32000
  if (model.attachment === undefined) model.attachment = Boolean(info?.supports_vision || info?.supports_pdf_input)
  if (model.reasoning === undefined) model.reasoning = Boolean(info?.supports_reasoning)
  if (model.temperature === undefined) model.temperature = true
  if (model.tool_call === undefined) model.tool_call = info?.supports_function_calling !== false
}

function indexLiteLlmModelHub(payload) {
  // /public/model_hub returns a flat array; each entry carries its pricing/limits directly and is
  // keyed by `model_group` (the public alias clients call). Only public groups are included.
  const items = Array.isArray(payload) ? payload : Array.isArray(payload?.data) ? payload.data : []
  const result = new Map()
  for (const item of items) {
    if (!item || typeof item !== "object") continue
    const key = item.model_group
    if (typeof key === "string" && key.trim() !== "") result.set(key, item)
  }
  return result
}

function indexUpstreamCostMap(payload) {
  const result = new Map()
  if (!payload || typeof payload !== "object") return result
  for (const [key, value] of Object.entries(payload)) {
    if (!value || typeof value !== "object") continue
    if (key === "sample_spec") continue
    result.set(key, value)
    for (const alias of Array.isArray(value.aliases) ? value.aliases : []) {
      if (typeof alias === "string" && alias.trim() !== "") result.set(alias, value)
    }
  }
  return result
}

function candidateModelKeys(modelID, model) {
  const keys = new Set()
  for (const key of [modelID, model?.id, model?.api?.id, model?.provider?.id]) {
    if (typeof key === "string" && key.trim() !== "") keys.add(key)
  }
  for (const key of Array.from(keys)) {
    const slash = key.indexOf("/")
    if (slash > -1 && slash < key.length - 1) keys.add(key.slice(slash + 1))
  }
  return Array.from(keys)
}

function findCostInfo(modelID, model, proxyIndex, upstreamIndex) {
  const keys = candidateModelKeys(modelID, model)
  for (const key of keys) {
    const match = proxyIndex?.get(key)
    if (match) return match
  }
  for (const key of keys) {
    const match = upstreamIndex?.get(key)
    if (match) return match
  }
  return undefined
}

function isLiteLlmProvider(provider) {
  return provider?.npm === OPENAI_COMPATIBLE_PROVIDER && typeof provider?.options?.baseURL === "string"
}

function applyCosts(cfg, sources) {
  let updated = 0
  let missing = 0
  for (const [providerID, provider] of Object.entries(cfg.provider ?? {})) {
    if (!isLiteLlmProvider(provider)) continue
    const source = sources.get(providerID)
    if (!source) continue
    for (const [modelID, model] of Object.entries(provider.models ?? {})) {
      const info = findCostInfo(modelID, model, source.proxy, source.upstream)
      const cost = costFromLiteLlmInfo(info)
      if (!cost) {
        missing++
        continue
      }
      normalizeModelConfig(modelID, model, info)
      model.cost = cost
      updated++
    }
  }
  return { updated, missing }
}

async function fetchJson(url, init) {
  const response = await fetch(url, init)
  if (!response.ok) throw new Error(`${response.status} ${response.statusText}`)
  return response.json()
}

async function loadProviderCostSource(provider) {
  const proxy = new Map()
  const tls = tlsFetchOptions(provider)
  const modelHubUrl = buildLiteLlmModelHubUrl(provider?.options?.baseURL)
  if (modelHubUrl) {
    try {
      const payload = await fetchJson(modelHubUrl, {
        headers: buildRequestHeaders(provider),
        signal: AbortSignal.timeout(8_000),
        ...tls,
      })
      for (const [key, value] of indexLiteLlmModelHub(payload)) proxy.set(key, value)
    } catch (error) {
      console.error(`[litellm-cost-map] Failed to load ${modelHubUrl}: ${error.message}`)
    }
  }

  let upstream = new Map()
  try {
    upstream = indexUpstreamCostMap(
      await fetchJson(UPSTREAM_COST_MAP_URL, {
        signal: AbortSignal.timeout(8_000),
      }),
    )
  } catch (error) {
    console.error(`[litellm-cost-map] Failed to load upstream cost map: ${error.message}`)
  }
  return { proxy, upstream }
}

async function loadCostSources(cfg) {
  const sources = new Map()
  await Promise.all(
    Object.entries(cfg.provider ?? {}).map(async ([providerID, provider]) => {
      if (!isLiteLlmProvider(provider)) return
      sources.set(providerID, await loadProviderCostSource(provider))
    }),
  )
  return sources
}

export {
  applyCosts,
  buildLiteLlmModelHubUrl,
  buildRequestHeaders,
  candidateModelKeys,
  costFromLiteLlmInfo,
  findCostInfo,
  indexLiteLlmModelHub,
  indexUpstreamCostMap,
  loadCostSources,
  normalizeBaseUrl,
  normalizeModelConfig,
  resolveTemplate,
  tlsFetchOptions,
}
