// Runtime entrypoint for the opencode plugin.
//
// IMPORTANT — two deliberate constraints, both enforced by opencode's plugin loader:
//
// 1. This file MUST be `.js` (or `.ts`), NOT `.mjs`. opencode auto-discovers plugins with the glob
//    `{plugin,plugins}/*.{ts,js}` (see packages/opencode/src/config/plugin.ts). A `.mjs` file dropped
//    into the plugin directory is NOT picked up. opencode treats plugin `.js` files as ES modules.
//
// 2. This module MUST export ONLY `default`. opencode's legacy loader (getLegacyPlugins in
//    packages/opencode/src/plugin/index.ts) calls EVERY export of a plugin module as a plugin factory.
//    Any extra export would be invoked as a plugin and crash. All testable logic therefore lives in
//    `litellm-cost-map-lib.mjs`, which is `.mjs` precisely so the auto-discovery glob ignores it while
//    this entry can still `import` from it.
import { applyCosts, loadCostSources } from "./litellm-cost-map-lib.mjs"

export default async function liteLlmCostMapPlugin() {
  return {
    async config(cfg) {
      const sources = await loadCostSources(cfg)
      const { updated, missing } = applyCosts(cfg, sources)
      if (updated > 0 || missing > 0) {
        console.log(
          `[litellm-cost-map] Updated ${updated} model costs from LiteLLM; ${missing} kept existing cost fallback`,
        )
      }
    },
  }
}
