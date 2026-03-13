## Why

`query_sync` discards the post-execution agent struct, returning only `{:ok, result} | {:error, reason}`. This makes conversation persistence impossible for HITL resume flows — the updated conversation (including the assistant's `tool_use` message) lives in the agent's strategy state and is lost. On resume, the `tool_result` arrives without its matching `tool_use`, causing an Anthropic API 400 error. Additionally, modeling suspension as `{:error, {:suspended, ...}}` contradicts the HITL design's explicit principle that suspension is a positive outcome, not an error.

## What Changes

- **BREAKING**: `query_sync/3` return type changes from `{:ok, result} | {:error, reason}` to `{:ok, agent, result} | {:suspended, agent, suspension} | {:error, reason}`
- Suspension becomes a first-class return variant (`:suspended` atom) instead of an error-wrapped tuple
- `run_orch_directives/3` threads the agent struct through completion and suspension paths
- Internal callers (`AgentNode.run/3`, `Node.execute_child_sync/2`) updated to match new 3-tuple
- All tests, livebooks, guides, design docs, and README examples updated for new pattern

## Capabilities

### New Capabilities

- `query-sync-return-agent`: Return the post-execution agent struct from `query_sync` in completion and suspension outcomes, making suspension a first-class return variant

### Modified Capabilities

## Impact

- **API**: Breaking change to `query_sync/3` return type — all callers must update pattern matches
- **Code**: `dsl.ex` (loop + base case), `agent_node.ex` (line 93), `node.ex` (line 89), `configure.ex` (docstring), `orchestrator.ex` (docstring), `jido_composer.ex` (docstring)
- **Tests**: `dsl_test.exs` (~6), `configure_test.exs` (~5), `review_issues_test.exs` (~2)
- **Docs**: `interface.md`, `orchestrator/README.md`, `guides/orchestrators.md`, `guides/getting-started.md`, `guides/testing.md`, `README.md`
- **Livebooks**: `04_llm_orchestrator.livemd` (~3), `06_observability.livemd` (~1)
- **No change**: Strategy internals, node execution, observability, `run_orch_directives` recursive clauses, workflow `run_sync`
