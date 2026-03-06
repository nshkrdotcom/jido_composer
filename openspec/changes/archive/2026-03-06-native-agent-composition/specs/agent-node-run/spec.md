## Reference Documents

- **Design**: `native-agent-composition.md` §2 — AgentNode.run/3 restore, dual-path principle, DSL sync loop updates
- **Design**: `docs/design/nodes/README.md` — AgentNode modes (sync/async/streaming), Node contract
- **Prototype**: `prototypes/test_agent_node_run.exs` — 7 passing tests validating sync delegation
- **Learnings**: `prototypes/learnings.md` — "run_sync/2 returns full machine context", "DSL run_directives/3 silently drops SpawnAgent"
- **PLAN**: `IMPLEMENTATION_PLAN.md` Phase 1

## MODIFIED Requirements

### Requirement: AgentNode.run/3 delegates to sync entry point

`AgentNode.run/3` SHALL delegate to the agent module's `run_sync/2` or `query_sync/3` for `:sync` mode instead of returning `{:error, :not_directly_runnable}`.

#### Scenario: Workflow agent with run_sync/2

- **WHEN** `AgentNode.run/3` is called with a node whose `agent_module` exports `run_sync/2`
- **THEN** it SHALL call `agent_module.run_sync(agent_module.new(), context)` and return `{:ok, result}` where result is the workflow's accumulated context map

#### Scenario: Orchestrator agent with query_sync/3

- **WHEN** `AgentNode.run/3` is called with a node whose `agent_module` exports `query_sync/3` but not `run_sync/2`
- **THEN** it SHALL call `agent_module.query_sync(agent_module.new(), query, context)` where query is extracted from `context.query` or `context["query"]`
- **AND** return `{:ok, %{result: result}}`

#### Scenario: Async mode still returns not_directly_runnable

- **WHEN** `AgentNode.run/3` is called with `mode: :async`
- **THEN** it SHALL return `{:error, {:not_directly_runnable, :async}}`

#### Scenario: Streaming mode still returns not_directly_runnable

- **WHEN** `AgentNode.run/3` is called with `mode: :streaming`
- **THEN** it SHALL return `{:error, {:not_directly_runnable, :streaming}}`

#### Scenario: Agent without sync entry point

- **WHEN** `AgentNode.run/3` is called with an agent that exports neither `run_sync/2` nor `query_sync/3`
- **THEN** it SHALL return `{:error, :agent_not_sync_runnable}`

## ADDED Requirements

### Requirement: Workflow DSL run_directives handles SpawnAgent

The `run_directives/3` function in `Jido.Composer.Workflow.DSL` SHALL handle `SpawnAgent` directives by calling the child agent's sync entry point and routing results back through `cmd/3`.

#### Scenario: SpawnAgent for workflow child in run_sync

- **WHEN** `run_directives/3` encounters a `SpawnAgent` directive for an agent with `run_sync/2`
- **THEN** it SHALL call `child_module.run_sync(child_module.new(), context)` and feed the result back as `{:workflow_child_result, %{tag: tag, result: result}}`

#### Scenario: SpawnAgent for orchestrator child in run_sync

- **WHEN** `run_directives/3` encounters a `SpawnAgent` directive for an agent with `query_sync/3`
- **THEN** it SHALL call `child_module.query_sync(child_module.new(), query, context)` and feed the result back as `{:workflow_child_result, %{tag: tag, result: result}}`
- **AND** the raw `query_sync` result (which may be a bare string after `unwrap_result`) SHALL be passed through — `Machine.apply_result`'s `resolve_result/1` handles type adaptation

### Requirement: execute_child_sync passes raw results

`Node.execute_child_sync/2` SHALL pass the raw `run_sync/2` or `query_sync/3` return value through without wrapping. This differs from `AgentNode.run/3` which wraps `query_sync` results in `%{result: result}`.

#### Scenario: Orchestrator child returns bare string via execute_child_sync

- **WHEN** `execute_child_sync(orchestrator_module, opts)` is called
- **AND** the orchestrator's `query_sync/3` returns `{:ok, "answer text"}`
- **THEN** `execute_child_sync` SHALL return `{:ok, "answer text"}` (not `{:ok, %{result: "answer text"}}`)
- **AND** the workflow strategy's `Machine.apply_result` SHALL resolve the bare string via `resolve_result/1` to `%{text: "answer text"}`

### Requirement: Orchestrator DSL run_orch_directives handles SpawnAgent

The `run_orch_directives/3` function in `Jido.Composer.Orchestrator.DSL` SHALL handle `SpawnAgent` directives following the same pattern as the Workflow DSL.

#### Scenario: SpawnAgent in orchestrator query_sync loop

- **WHEN** `run_orch_directives/3` encounters a `SpawnAgent` directive
- **THEN** it SHALL execute the child synchronously and route results back through `cmd/3`
