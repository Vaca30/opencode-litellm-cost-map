# Helper agents

This folder contains the system prompts for the helper agents that were used to
take the `opencode-litellm-cost-map` plugin from a working prototype to a
production-ready, publishable package.

Each agent has a single, well-bounded responsibility. A lead orchestrator
dispatches each agent, validates its output against the acceptance criteria in
the prompt, and sends the work back for rework if it does not pass.

| Agent | Prompt | Responsibility |
|---|---|---|
| Research / Verifier | [`research-verifier.md`](./research-verifier.md) | Verify external facts online (OpenCode plugin loading, LiteLLM pricing units, reference syntax) and return cited findings. |
| Docs writer | [`docs-writer.md`](./docs-writer.md) | Produce the English, genericized `README.md` and `INSTALL.md`. |
| Install-script engineer | [`install-script-engineer.md`](./install-script-engineer.md) | Author the idempotent, non-destructive `install.ps1` and `install.sh`. |
| QA / Validator | [`qa-validator.md`](./qa-validator.md) | Run tests, scan for PII / hardcoded paths / secrets, and check docs-vs-code consistency. |

## Workflow

```
lead ──dispatch──▶ agent ──output──▶ lead validates ──▶ pass? ──▶ accept
                                          │
                                          └── fail ──▶ rework with feedback
```

The agents communicate in English. End-user facing summaries are written in the
language requested by the user.
