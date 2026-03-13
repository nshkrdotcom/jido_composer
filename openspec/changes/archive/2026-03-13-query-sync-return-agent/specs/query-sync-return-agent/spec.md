## ADDED Requirements

### Requirement: query_sync returns agent on completion

`query_sync/3` SHALL return a 3-tuple `{:ok, agent, result}` when the orchestrator completes successfully, where `agent` is the post-execution `Jido.Agent.t()` struct with updated strategy state.

#### Scenario: Final answer with text result

- **WHEN** the LLM produces a final text answer
- **THEN** `query_sync` returns `{:ok, agent, answer}` where `answer` is a string and `agent` contains the updated conversation history

#### Scenario: Final answer with structured result via termination tool

- **WHEN** the LLM calls a termination tool to produce structured output
- **THEN** `query_sync` returns `{:ok, agent, result}` where `result` is the map returned by the termination tool action

#### Scenario: Agent conversation state is current

- **WHEN** `query_sync` returns `{:ok, agent, result}`
- **THEN** `agent.state.__strategy__.conversation` contains all messages from the execution, including the final assistant response

### Requirement: query_sync returns agent on suspension

`query_sync/3` SHALL return `{:suspended, agent, suspension}` when the orchestrator suspends, where `agent` is the post-execution `Jido.Agent.t()` struct and `suspension` is a `Jido.Composer.Suspension.t()`.

#### Scenario: Gated tool triggers suspension

- **WHEN** the LLM calls a tool marked with `requires_approval: true`
- **THEN** `query_sync` returns `{:suspended, agent, suspension}` where `suspension.reason` is `:human_input`

#### Scenario: Action returns suspend

- **WHEN** an action executed by the orchestrator returns `{:ok, result, :suspend}`
- **THEN** `query_sync` returns `{:suspended, agent, suspension}` with the corresponding `Jido.Composer.Suspension` struct

#### Scenario: Agent conversation includes tool_use on suspension

- **WHEN** `query_sync` returns `{:suspended, agent, suspension}` after an LLM tool_use message
- **THEN** `agent.state.__strategy__.conversation` contains the assistant's `tool_use` message, enabling correct resume with a matching `tool_result`

### Requirement: query_sync error path unchanged

The `{:error, reason}` return path SHALL remain unchanged — no agent struct is returned on error.

#### Scenario: LLM failure

- **WHEN** the LLM call fails (e.g., API error)
- **THEN** `query_sync` returns `{:error, reason}` (2-tuple, no agent)

### Requirement: Suspension is not modeled as error

Suspension outcomes SHALL NOT be wrapped in `{:error, ...}` tuples. The `:suspended` atom at position 0 distinguishes suspension from both success and error.

#### Scenario: Suspension uses distinct tuple tag

- **WHEN** the orchestrator suspends for any reason
- **THEN** the return value starts with the atom `:suspended`, not `:error`

### Requirement: Internal callers handle new return type

`AgentNode.run/3` and `Node.execute_child_sync/2` SHALL pattern-match on `{:ok, _agent, result}` when calling `query_sync`, discarding the child agent struct.

#### Scenario: AgentNode wraps orchestrator result

- **WHEN** `AgentNode.run/3` calls `query_sync` on an orchestrator child
- **THEN** it matches `{:ok, _agent, result}` and returns `{:ok, %{result: result}}`

#### Scenario: execute_child_sync wraps orchestrator result

- **WHEN** `Node.execute_child_sync/2` calls `query_sync` on an orchestrator child
- **THEN** it matches `{:ok, _agent, result}` and returns `{:ok, result}`
