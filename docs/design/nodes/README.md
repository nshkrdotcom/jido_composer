# Nodes

The Node behaviour is the foundational abstraction in Jido Composer. Every
participant in a composition — actions, agents, nested workflows — implements
the same uniform interface.

## Contract

A Node is a function from [context](../glossary.md#context) to context with an
optional [outcome](../glossary.md#outcome):

| Input                              | Output                                                                  |
| ---------------------------------- | ----------------------------------------------------------------------- |
| `context` (map) + `opts` (keyword) | `{:ok, context}` — success with default outcome `:ok`                   |
|                                    | `{:ok, context, outcome}` — success with explicit outcome for branching |
|                                    | `{:error, reason}` — failure with implicit outcome `:error`             |

This mirrors the `Jido.Action.run/2` signature but adds explicit outcome support
for driving [Workflow](../workflow/README.md) transitions.

## Callbacks

| Callback        | Returns            | Purpose                                            |
| --------------- | ------------------ | -------------------------------------------------- |
| `run/3`         | result (see above) | Execute the node's logic (struct, context, opts)   |
| `name/1`        | `String.t()`       | Human-readable identifier (receives struct)        |
| `description/1` | `String.t()`       | What this node does (receives struct)              |
| `schema/1`      | keyword \| nil     | Input parameter schema (receives struct, optional) |

All callbacks receive the node struct as first argument, enabling per-instance
configuration (e.g., different options for the same action module in different
workflow states).

## Node Types

```mermaid
classDiagram
    class Node {
        <<behaviour>>
        +run(node, context, opts) result
        +name(node) String
        +description(node) String
        +schema(node) keyword | nil
    }

    class ActionNode {
        action_module : module
        opts : keyword
        +new(action_module, opts)
    }

    class AgentNode {
        agent_module : module
        mode : :sync | :async | :streaming
        opts : keyword
        signal_type : String | nil
        on_state : list(atom) | nil
        +new(agent_module, opts)
    }

    class HumanNode {
        name : String
        prompt : String | function
        allowed_responses : list(atom)
        response_schema : keyword | nil
        timeout : integer | :infinity
        context_keys : list(atom) | nil
        +new(opts)
    }

    class FanOutNode {
        name : String
        branches : list(Node)
        merge : function | :deep_merge
        timeout : integer | :infinity
        +new(opts)
    }

    Node <|.. ActionNode
    Node <|.. AgentNode
    Node <|.. HumanNode
    Node <|.. FanOutNode
```

### ActionNode

A thin adapter that wraps any `Jido.Action` module as a Node. Since actions
already conform to a `(params, context) -> {:ok, map()}` contract, the adapter
primarily handles [context accumulation](context-flow.md) via deep merge.

The adapter delegates metadata to the wrapped action:

| Node Callback   | Delegates To                  |
| --------------- | ----------------------------- |
| `name/0`        | `action_module.name()`        |
| `description/0` | `action_module.description()` |
| `schema/0`      | `action_module.schema()`      |

When the Workflow strategy encounters an ActionNode, it emits a
[RunInstruction](../glossary.md#directive) directive containing the action
module and current context. The runtime executes the action and routes the result
back to the strategy.

### AgentNode

Wraps any `Jido.Agent` module as a Node. The AgentNode struct carries
per-instance configuration:

| Field          | Type                                | Purpose                                                                    |
| -------------- | ----------------------------------- | -------------------------------------------------------------------------- |
| `agent_module` | module                              | The Jido.Agent module to spawn                                             |
| `mode`         | `:sync` \| `:async` \| `:streaming` | Communication mode (default: `:sync`)                                      |
| `opts`         | keyword                             | Options passed to the agent (e.g., `timeout: 30_000`)                      |
| `signal_type`  | `String.t()` \| nil                 | Signal type to send when delivering context (defaults to agent convention) |
| `on_state`     | `[atom()]` \| nil                   | FSM states that emit events upstream (streaming mode only)                 |

AgentNode supports three communication modes for different use cases:

| Mode              | Behaviour                                            | Outcome                                           |
| ----------------- | ---------------------------------------------------- | ------------------------------------------------- |
| `:sync` (default) | Spawns agent, sends context as signal, awaits result | `{:ok, merged_context}`                           |
| `:async`          | Spawns agent, returns immediately                    | `{:ok, context, :pending}` with handle in context |
| `:streaming`      | Spawns agent, subscribes to state transitions        | Events emitted at specified FSM states            |

The `signal_type` field controls which signal type the parent sends when
delivering context to the child. When nil, the parent uses the child agent's
conventional signal type. This is useful when a single agent module handles
multiple signal types for different purposes.

The `on_state` field is only relevant in streaming mode. It specifies which of
the child agent's FSM states should trigger an event emission to the parent.
This allows the parent to observe intermediate progress without waiting for full
completion.

**Sync mode** is the primary mode for [Workflow](../workflow/README.md)
composition:

1. The strategy emits a SpawnAgent directive for the agent module
2. On `child_started`, the strategy sends context as a signal to the child
3. The child runs its own strategy and produces a result
4. The child sends the result back to the parent via `emit_to_parent`
5. The parent receives the result, applies deep merge, and continues

**All three modes** are relevant for
[Orchestrator](../orchestrator/README.md) composition, where the LLM may choose
to fire-and-forget or to stream intermediate results.

### HumanNode

A Node whose computation is performed by a human. When `run/2` is called, a
HumanNode constructs an
[ApprovalRequest](../hitl/approval-lifecycle.md#approvalrequest) from the
flowing context and returns `{:ok, context, :suspend}`. It never blocks — the
strategy layer handles the actual suspension and resumption.

The `:suspend` outcome is reserved: the strategy does not look up a transition
for it. Instead, the strategy pauses the [Machine](../workflow/state-machine.md)
and waits for a resume signal carrying the human's decision. The decision atom
(e.g., `:approved`, `:rejected`) is then used as the transition outcome.

HumanNode carries per-instance configuration:

| Field               | Type                               | Purpose                                             |
| ------------------- | ---------------------------------- | --------------------------------------------------- |
| `name`              | `String.t()`                       | Node identifier                                     |
| `prompt`            | `String.t()` or `(context -> str)` | The question presented to the human                 |
| `allowed_responses` | `[atom()]`                         | Outcome atoms the human can choose from             |
| `response_schema`   | keyword \| nil                     | Schema for structured input beyond the outcome atom |
| `timeout`           | `pos_integer()` \| `:infinity`     | Maximum wait time in ms                             |
| `context_keys`      | `[atom()]` \| nil                  | Which context keys to include in the request        |
| `metadata`          | `map()`                            | Arbitrary metadata for the notification system      |

See [Human-in-the-Loop](../hitl/README.md) for the full design of HITL
support, including strategy integration, persistence, and nested propagation.

### FanOutNode

A Node that executes multiple child nodes concurrently and merges their results.
The Workflow [Machine](../workflow/state-machine.md) has a single `status` field,
so two nodes cannot execute simultaneously within the FSM. FanOutNode solves this
by encapsulating parallel execution behind the standard Node interface — it
appears as a single state to the FSM but internally spawns multiple branches.

FanOutNode carries per-instance configuration:

| Field      | Type                                  | Purpose                                                        |
| ---------- | ------------------------------------- | -------------------------------------------------------------- |
| `name`     | `String.t()`                          | Node identifier                                                |
| `branches` | `[Node.t()]`                          | Child nodes to execute concurrently                            |
| `merge`    | `(results -> map())` \| `:deep_merge` | Strategy for combining branch results (default: `:deep_merge`) |
| `timeout`  | `pos_integer()` \| `:infinity`        | Maximum wait time for all branches (default: 30_000)           |

When `run/2` is called:

1. The FanOutNode spawns all branches concurrently (via `Task.async_stream` or
   equivalent)
2. Each branch receives the same input context
3. Branch results are collected and merged using the configured merge strategy
4. The merged result is returned as the node's output

The default merge strategy (`:deep_merge`) scopes each branch result under the
branch node's name, then deep-merges them into a single map:

```elixir
# Three branches: financial_review, legal_review, background_check
# Result:
%{
  financial_review: %{score: 85, risk: :low},
  legal_review: %{status: :clear, notes: "..."},
  background_check: %{passed: true}
}
```

Custom merge functions receive the list of `{branch_name, result}` tuples and
return a single map, enabling domain-specific aggregation (e.g., voting,
scoring, consensus).

**Error handling**: If any branch fails, the FanOutNode can be configured to
either fail fast (return `{:error, reason}` immediately) or collect partial
results. The default is fail-fast.

**Relationship to arrow combinators**: FanOutNode is the concrete implementation
of the fan-out (`&&&`) combinator described in
[Foundations](../foundations.md#arrow-combinators-parallel-and-fan-out). It makes
the theoretical combinator available as a first-class Node type.

**When to use FanOutNode vs. an Orchestrator**: Use FanOutNode when the set of
parallel branches is known at definition time and results need deterministic
merging. Use an Orchestrator when the LLM should dynamically decide which tools
to invoke concurrently.

## Design Decisions

**Why a separate Node behaviour instead of using Jido.Action directly?**

Actions return `{:ok, result_map}` — a raw result. Nodes return
`{:ok, context, outcome}` — an accumulated context with a transition-driving
outcome. The Node layer adds the semantics needed for FSM-based composition
(outcomes) and agent-based composition (spawn/signal lifecycle) while keeping
the underlying action and agent interfaces unchanged.

**Why structs instead of just modules?**

ActionNode and AgentNode carry instance-level configuration (options, mode,
signal type) that varies per usage site. A workflow might use the same action
module in two different states with different options. Structs capture this
per-instance configuration.
