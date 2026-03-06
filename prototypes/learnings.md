# jido_composer Design Validation Report

**Date:** 2026-03-05
**Approach:** Read all design docs, explored Jido dependency source code, wrote and ran 7 prototype scripts against real Jido primitives and real Claude API.

---

## Prototype Scripts & Results

### Round 1

| Script                      | Tests | Result                                                                                                                             |
| --------------------------- | ----- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `test_jido_strategy.exs`    | 7     | **ALL PASS** — Strategy.State, directives, cmd/3, DirectiveExec protocol, Persist, deep merge, emit_to_parent                      |
| `test_hitl_assumptions.exs` | 8     | **ALL PASS** — Suspend/resume, rejection, timeout, idempotency, serialization, approval gate, ParentRef, ChildRef                  |
| `test_fsm_deep_merge.exs`   | 7     | **ALL PASS** — Linear pipeline, branching, wildcards, deep merge edge cases, context growth, associativity, performance            |
| `test_llm_tool_calling.exs` | 5     | **ALL PASS** — API request with tools, tool_use parsing, tool_result round-trip, conversation serialization, LLM Behaviour pattern |

### Round 2

| Script                           | Tests | Result                                                                                                                  |
| -------------------------------- | ----- | ----------------------------------------------------------------------------------------------------------------------- |
| `test_dsl_agent_wiring.exs`      | 5     | **ALL PASS** — Strategy opts flow, module type detection, atom actions in cmd/3, RunInstruction result routing, to_tool |
| `test_agent_server_children.exs` | 6     | **ALL PASS** — SpawnAgent exec, signal delivery, emit_to_parent, on_parent_death, DOWN monitoring, tag-based lookup     |
| `test_fan_out_execution.exs`     | 6+2   | **ALL PASS** — Concurrent branches, fail-fast, timeout, scoped merge, Node wrappers, 10x parallel speedup               |

---

## Assumptions Confirmed

All critical assumptions about Jido's Strategy system, directive model,
parent-child communication, persistence, LLM integration, DSL wiring,
AgentServer child lifecycle, and concurrent execution have been validated
against real code and real API calls. See prototype scripts for details.

---

## Design Findings

Findings that affect architecture. Design docs have been updated to reflect
these — see referenced sections.

### Signal Routing — No Default Fallback

AgentServer has no default fallback for unknown signal types. Unmatched signals
produce `RoutingError`. The only built-in route is `jido.agent.stop`.

**Impact:** Every Composer strategy must declare explicit `signal_routes/1` for
all handled signal types. The DSL must auto-generate routes from declared nodes
and transitions. Route pattern:
`{"signal.type", {:strategy_cmd, :atom_action}}`.

**Design doc updated:** [Overview — Signal Integration](../docs/design/overview.md#signal-integration),
[Glossary — Signal Route](../docs/design/glossary.md#signal-route).

### Schema Conversion — Already Solved

`Jido.Action.Tool.to_tool/1` and `Jido.Action.Schema.to_json_schema/2` exist
in `jido_action`. Schema conversion is not a risk — the AgentTool adapter
delegates directly to these functions.

**Impact:** Removes schema conversion from the risk list. No custom conversion
code needed.

### SpawnAgent Lifecycle — Confirms AgentNode Design

SpawnAgent lifecycle confirmed via DirectiveExec protocol:
spawn → monitor → `child_started` signal → `emit_to_parent` → `child_exit`
signal on DOWN.

**Impact:** Matches the AgentNode sync mode design exactly. No design changes
needed.

### on_parent_death Behavior

Confirmed from source: `:stop` terminates child, `:continue` keeps alive,
`:emit_orphan` emits `jido.agent.orphaned` signal and continues.

**Impact:** SpawnAgent directives should default to `:stop` for deterministic
cleanup.

### FanOutNode — Pure Node Implementation

`Task.async_stream` works correctly for parallel branch execution within
`run/2`. No special strategy support needed — concurrency is fully encapsulated.

**Impact:** Confirms the FanOutNode design in
[Nodes — FanOutNode](../docs/design/nodes/README.md#fanoutnode).

### Deep Merge Lists Overwrite

`deep_merge(%{items: [1,2]}, %{items: [3,4]})` yields `%{items: [3,4]}`.

**Impact:** Already documented in
[Context Flow — Non-Map Values](../docs/design/nodes/context-flow.md#non-map-values).
Scoping prevents cross-node issues.

---

## Implementation Notes

Details useful during coding that do not affect architecture.

### DSL Strategy Opts Wiring

`use Jido.Agent, strategy: {Mod, opts}` works as designed:

- `strategy/0` returns the module, `strategy_opts/0` returns the opts keyword
- `new/1` calls `strategy().init(agent, %{strategy_opts: strategy_opts()})`
- `cmd/2` passes `%{strategy_opts: strategy_opts()}` to `strategy.cmd/3`
- The ctx map is `%{agent_module: __MODULE__, strategy_opts: keyword()}`

### Module Type Detection

To detect whether a module is an Action vs Agent at compile/runtime:

- **Recommended**: `function_exported?(mod, :run, 2)` → Action; `function_exported?(mod, :cmd, 2)` → Agent
- **Also works**: `Jido.Action in mod.__info__(:attributes)[:behaviour]`
- Actions have `run/2`, `name/0`, `description/0`, `schema/0`
- Agents have `cmd/2`, `strategy/0`, `strategy_opts/0`, `new/0`

### Instruction `action` Field Accepts Atoms

Strategy-internal actions (`:workflow_start`, `:step_result`, etc.) use bare
atoms as the `action` field in `Instruction` structs. This works — the system
does not require `action` to be a module. These atoms bypass `action_spec/1`
validation, which is fine as long as the strategy handles unknown actions
gracefully.

### DirectiveExec Return Types

`SuspendForHuman` must return `{:ok, state}` from its `DirectiveExec.exec/3`
implementation. Using `{:stop, ...}` would hard-stop the agent, drop pending
directives, and orphan async work. The `{:ok, state}` return allows the agent
to remain alive in `:waiting` status.

### `run_sync/2` Needs a Mini Event Loop

The DSL generates `run_sync/2` that "blocks until terminal state." This
requires: starting an AgentServer, sending the start signal, collecting
directives, executing them, routing results back, repeating until terminal.
This is essentially reimplementing the AgentServer event loop in miniature.
Defer `run_sync` to after the async `run/2` path is working. For testing, use
the AgentServer directly or mock the runtime loop.

---

## Performance Numbers

| Metric                             | Value     | Requirement         | Status            |
| ---------------------------------- | --------- | ------------------- | ----------------- |
| FSM transitions/sec                | ~617,000  | >1,000              | **617x headroom** |
| Strategy state serialization       | 422 bytes | Reasonable          | **Good**          |
| 10-node context serialization      | 36 KB     | Reasonable          | **Good**          |
| LLM API round-trip (Claude Sonnet) | ~1-2s     | N/A (network-bound) | **Expected**      |
| FanOut 10×100ms branches           | ~101ms    | <500ms              | **9.9x speedup**  |

The directive loop indirection adds negligible overhead compared to LLM API latency. A 10-iteration ReAct loop at ~1s per LLM call = ~10s total. The ~20 directive round-trips within that loop add microseconds.

---

## Verdict

**The design is implementable as-is.** Start with the Workflow Track (PLAN.md steps 1-7) — zero external dependencies, all primitives confirmed, pure deterministic tests.

### Issues Resolved in Design Docs

| Issue                                    | Resolution                                                                            |
| ---------------------------------------- | ------------------------------------------------------------------------------------- |
| `__parent__.pid` not stripped by Persist | Documented in `docs/design/hitl/persistence.md` (ParentRef PID Handling section)      |
| No parallel execution in Workflow FSM    | Added FanOutNode to design (`docs/design/nodes/README.md`, use-cases, glossary, etc.) |
| Schedule vs Cron confusion               | Design already uses Schedule correctly for HITL timeouts                              |
| Signal route priority                    | Already documented in `docs/design/overview.md`                                       |

### Issues Resolved in Round 2

| Issue                        | Resolution                                                                        |
| ---------------------------- | --------------------------------------------------------------------------------- |
| Schema conversion risk       | **Already solved** by `Jido.Action.Tool.to_tool/1` and `Schema.to_json_schema/2`  |
| Strategy opts wiring unknown | Confirmed: `{Mod, opts}` flows through to `init/2` and `cmd/3` via `ctx`          |
| Module type detection        | `function_exported?` on `run/2` vs `cmd/2` distinguishes Action from Agent        |
| Signal routing fallback      | No fallback — explicit `signal_routes/1` required for all handled signal types    |
| SpawnAgent full lifecycle    | Confirmed: spawn → monitor → child_started → signal → emit_to_parent → child_exit |
| FanOutNode feasibility       | Confirmed: `Task.async_stream` delivers ~10x speedup with proper error handling   |

### Round 3 — Native Agent Composition Prototypes

| Script                            | Tests | Result                                                                                                                           |
| --------------------------------- | ----- | -------------------------------------------------------------------------------------------------------------------------------- |
| `test_agent_node_run.exs`         | 7     | **ALL PASS** — run_sync delegation, SpawnAgent DSL handler, FanOut with agent branches, result shape analysis                    |
| `test_node_io_envelope.exs`       | 7     | **ALL PASS** — Typed envelope, resolve_result, heterogeneous FanOut merge, tool result unwrapping, monoid preservation           |
| `test_context_layering.exs`       | 8     | **ALL PASS** — Ambient/working separation, fork functions, backward compat, scoping safety, Machine integration, 3-level nesting |
| `test_integrated_composition.exs` | 7     | **ALL PASS** — Full pipeline with nested agent, mixed FanOut, generalized suspension, suspend/resume, FanOut partial completion  |

---

## Round 3 — Native Agent Composition Findings

All six proposals from `native-agent-composition.md` were prototyped.
Everything worked as designed. **No design updates required.**

### Design Updates Required

None. The design doc is accurate as written.

### Implementation Notes

Details that don't change the design but are useful when coding.

1. **`run_sync/2` returns full machine context, not just last step.**
   `AgentNode.run/3` delegating to `run_sync/2` gets back the entire context
   (e.g. `%{value: 5, step1: %{value: 6}, step2: %{value: 10}}`), not a
   single step's output. The parent scopes this naturally under its state name.
   The design doc's code is correct — just be aware of the shape.

2. **Workflow exports `run_sync/2`, Orchestrator exports `query_sync/3`.**
   Neither exports both. The `cond` chain in the design doc's `AgentNode.run/3`
   handles this correctly — confirming the branching is necessary.

3. **DSL `run_directives/3` silently drops SpawnAgent directives today.**
   Falls through to the `_other ->` clause. The SpawnAgent handler proposed in
   the design doc is necessary and works as described — same pattern as
   RunInstruction but calls `run_sync` instead of `Jido.Exec.run`.

4. **`@derive Jason.Encoder` needed on NodeIO struct.** `term_to_binary` works
   natively, but Jason encoding requires the explicit derive. Cannot be added
   at runtime.

5. **Context `to_flat_map` puts ambient under `__ambient__` key.** Follows
   existing reserved-key conventions (`__strategy__`, `__parent__`,
   `__approval_request__`). No collision risk due to scoping.

6. **Actions read top-level keys, not scoped keys.** `DoubleAction` with
   context `%{value: 5, step1: %{value: 6}}` reads `:value` (initial `5`),
   not `step1.value`. Pre-existing behavior, not introduced by these changes.
   Worth documenting for users.

### Performance (Round 3)

| Metric                     | Value        | Notes                      |
| -------------------------- | ------------ | -------------------------- |
| Context.apply_result/sec   | ~1,000,000   | Negligible overhead        |
| Context.fork_for_child/sec | ~1,500,000   | Even with 3 fork functions |
| Context.to_flat_map/sec    | ~6,600,000   | Trivial map merge          |
| Context serialize+restore  | ~180,000/sec | Including term_to_binary   |
| Context serialized size    | ~1.1 KB      | 20-step context + ambient  |

All context operations are sub-microsecond. Zero performance concern.
