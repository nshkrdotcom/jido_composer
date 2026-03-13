## Context

`query_sync/3` is a synchronous convenience wrapper around the orchestrator's `query/3` + directive execution loop. Currently it returns `{:ok, result} | {:error, reason}`, discarding the post-execution agent struct. The agent carries updated strategy state including conversation history, token usage, iteration counts, and pending suspension data.

The `query/3` function already returns `{agent, directives}` — the agent is always available in the async path. `query_sync` is the only API that strips it.

Internally, `run_orch_directives/3` already threads the agent through all recursive clauses. The agent is only discarded at the final return sites: `__query_sync_loop__/3` and the base case of `run_orch_directives/3` (empty directives list).

## Goals / Non-Goals

**Goals:**

- Return the post-execution agent struct from `query_sync` in completion and suspension outcomes
- Model suspension as a first-class return variant (`{:suspended, agent, suspension}`), not an error
- Maintain API consistency with `query/3` which already returns the agent
- Enable conversation persistence for HITL resume flows
- Enable post-execution inspection of token usage, iteration counts, and observability data

**Non-Goals:**

- Changing `run_orch_directives` recursive clause internals (already correct)
- Changing strategy internals or directive emission
- Changing the `{:error, reason}` path (no meaningful agent state on failure)
- Changing workflow `run_sync` return type (separate concern for a future change)
- Adding new functionality — this is purely a return type adjustment

## Decisions

### 1. Three-variant return type over nested tuple

**Decision**: `{:ok, agent, result} | {:suspended, agent, suspension} | {:error, reason}`

**Alternative considered**: `{:ok, {agent, result}} | {:error, reason}` — wrapping agent+result in an inner tuple. Rejected because it doesn't fix the suspension-as-error problem, and nested tuples are less idiomatic in Elixir.

**Alternative considered**: `{:ok, agent, result} | {:error, agent, reason}` — returning agent on error too. Rejected because on error the agent state may be inconsistent or partially updated, and the error path already works for callers today.

**Rationale**: 3-tuples are idiomatic Elixir for "success with metadata". A distinct `:suspended` atom makes suspension impossible to confuse with errors, aligning with the HITL design principle that suspension is a positive outcome.

### 2. Internal callers discard the agent

**Decision**: `AgentNode.run/3` and `Node.execute_child_sync/2` pattern-match `{:ok, _agent, result}` — discarding the child agent.

**Rationale**: These are composition boundaries. The parent doesn't need (or want) the child's agent struct — it only needs the result to feed back into its own context. The child agent is ephemeral (created by `mod.new()` within the call). If a future need arises to propagate child agents, it can be addressed separately.

### 3. Fix only in `__query_sync_loop__` and `run_orch_directives` base case

**Decision**: The implementation touches exactly two functions in `dsl.ex`. All other changes are pattern-match updates in callers, tests, and docs.

**Rationale**: `run_orch_directives/3` recursive clauses already thread the agent correctly. The `{:suspend, agent, suspend}` return from the `%Suspend{}` directive clause already carries the agent. The fix is surgical: thread the agent through the two return sites that currently discard it.

## Risks / Trade-offs

**[Breaking change]** → All callers of `query_sync` must update pattern matches. Mitigated by: this is a library with a small public API surface, all known callers are in the same repo (tests, livebooks, guides), and the compiler will catch missed pattern matches.

**[Suspension semantics change]** → Code matching `{:error, {:suspended, ...}}` will silently stop matching. Mitigated by: there are exactly 2 test sites with this pattern, both in the same repo. No external callers are known to depend on the error-wrapped suspension form.

**[Agent struct size in return]** → Returning the full agent struct adds the agent to the caller's scope. This is negligible — the agent was already in scope before the `query_sync` call and is the same struct, just updated.
