# Composer vs Jido AI

Jido Composer and [Jido AI](https://github.com/agentjido/jido_ai) are
complementary libraries in the Jido ecosystem. This guide helps you understand
what each one does best, when to reach for which, and how they work together.

## At a Glance

|                        | **Jido Composer**                    | **Jido AI**                                 |
| ---------------------- | ------------------------------------ | ------------------------------------------- |
| **Purpose**            | Composable agent flows               | AI agent runtime                            |
| **Core pattern**       | FSM workflows + LLM orchestrators    | Reasoning strategies (ReAct, CoT, ToT, ...) |
| **Composition unit**   | Node (`context → context`)           | Agent process (`ask/await`)                 |
| **Flow control**       | Explicit transitions you define      | LLM decides next step                       |
| **Parallel execution** | FanOut with backpressure             | Manual coordination                         |
| **Human-in-the-loop**  | HumanNode — first-class, declarative | Not built in                                |
| **Persistence**        | Checkpoint/thaw/resume               | Not built in                                |

## What Composer Adds

### Visible, Deterministic Control Flow

Jido AI agents are iterative reasoners — the LLM decides what happens next on
every turn. This is powerful for open-ended tasks, but makes it hard to
guarantee a specific sequence of steps, enforce approval gates, or reason about
what path the system will take.

Composer gives you explicit FSM transitions:

```elixir
transitions: %{
  {:extract, :ok}   => :transform,
  {:transform, :ok} => :load,
  {:load, :ok}      => :done,
  {:_, :error}      => :failed
}
```

You can read the transition table and know exactly what paths are possible. The
DSL validates at compile time that all states are reachable and all transitions
target valid states.

### Parallel Execution

FanOutNode runs branches concurrently with backpressure control, configurable
error handling (fail-fast or collect-partial), and merge strategies:

```elixir
FanOutNode.new(
  name: "parallel_analysis",
  branches: [
    sentiment:  SentimentAction,
    entities:   EntityAction,
    summarize:  {SummaryWorkflow, mode: :sync}
  ],
  max_concurrency: 2,
  on_error: :collect_partial
)
```

Jido AI agents don't have a built-in parallel execution primitive — you'd need
to coordinate concurrent tasks manually.

### Human-in-the-Loop as a First-Class Concept

HumanNode suspends a workflow for human input. Approval gates pause orchestrator
tool calls that need sign-off. Both integrate with checkpoint/resume so
suspended flows survive process restarts:

```elixir
nodes: %{
  process: ProcessAction,
  approval: %HumanNode{
    prompt: "Deploy to production?",
    allowed_responses: [:approved, :rejected]
  },
  deploy: DeployAction
},
transitions: %{
  {:process, :ok}       => :approval,
  {:approval, :approved} => :deploy,
  {:approval, :rejected} => :cancelled,
}
```

### Persistence Across Restarts

Composer's checkpoint system serializes the full agent state — FSM position,
context, suspension metadata — so workflows can be persisted to any storage
backend and resumed later, even in a different process or node.

### Arbitrary Nesting

Any agent (Composer workflow, Composer orchestrator, or Jido AI agent) can be a
node inside a workflow or a tool inside an orchestrator. Nesting is unlimited:

```elixir
nodes: %{
  research:  {ResearchOrchestrator, mode: :sync},
  validate:  ValidateAction,
  summarize: {SummaryWorkflow, mode: :sync},
}
```

## When Jido AI Shines on Its Own

Jido AI is the right choice when you need capabilities that are inherently about
_how an individual agent reasons_, not about composing multiple steps:

- **Strategy variety** — 8 reasoning families (ReAct, CoT, CoD, AoT, ToT, GoT,
  TRM, Adaptive) for different problem shapes. Composer's orchestrator covers
  ReAct; for specialized reasoning like tree search or graph-based synthesis,
  Jido AI provides purpose-built strategies.

- **One-shot LLM facade** — `Jido.AI.ask("Summarize this", model: :fast)` for
  quick single-call generation without defining modules.

- **Request handles** — `ask/await` pattern for concurrent, correlated requests
  to a long-lived agent process.

- **Plugin system** — Quota management, model routing, retrieval, and other
  runtime capabilities that mount on agent processes.

- **Skills** — Reusable instruction + tool bundles that can be loaded at compile
  time or runtime.

## Using Them Together

The most capable systems use both. Composer orchestrates _where_ and _when_
agents run; Jido AI handles _how_ each agent reasons.

**Example: Multi-agent pipeline with different reasoning strategies**

```elixir
defmodule ResearchAgent do
  use Jido.AI.Agent,
    name: "researcher",
    model: :capable,
    tools: [SearchAction, FetchAction],
    system_prompt: "You are a research specialist."
end

defmodule AnalysisWorkflow do
  use Jido.Composer.Workflow,
    name: "analysis_pipeline",
    nodes: %{
      research:  {ResearchAgent, mode: :sync},
      parallel:  FanOutNode.new(
        name: "analysis",
        branches: [
          sentiment: SentimentAction,
          entities:  EntityAction
        ]
      ),
      review:    %HumanNode{prompt: "Approve analysis?"},
      publish:   PublishAction
    },
    transitions: %{
      {:research, :ok}      => :parallel,
      {:parallel, :ok}      => :review,
      {:review, :approved}  => :publish,
      {:review, :rejected}  => :failed,
      {:publish, :ok}       => :done,
      {:_, :error}          => :failed
    },
    initial: :research
end
```

Here the Jido AI agent handles the open-ended research (ReAct with tools), while
Composer handles the deterministic pipeline around it — parallel analysis, human
approval, and error routing.

## Reasoning Strategies: Coverage

Composer's two patterns cover most strategy needs directly:

| Strategy            | How Composer handles it                                                                                         |
| ------------------- | --------------------------------------------------------------------------------------------------------------- |
| **ReAct**           | Native — the Orchestrator _is_ a ReAct loop                                                                     |
| **CoT / CoD / AoT** | Single-call prompt strategies — one ActionNode or Orchestrator with `max_iterations: 1`                         |
| **TRM**             | Natural fit — reason/supervise/improve maps cleanly to workflow states with cycles                              |
| **Adaptive**        | Workflow with a classify node routing to different orchestrators via custom outcomes                            |
| **ToT / GoT**       | Wrap a Jido AI ToT/GoT agent as an AgentNode — the tree/graph traversal is best handled by a dedicated strategy |

For tree search and graph-based reasoning (ToT, GoT), the core algorithm is
inherently a single-concern stateful computation. Rather than forcing it into
FSM transitions, wrap the specialized Jido AI agent as a node and let Composer
handle the surrounding flow.

## Decision Guide

```
What are you building?
│
├─ Multi-step pipeline with known stages?
│  └─ Composer Workflow
│
├─ LLM picks tools dynamically?
│  ├─ Simple tool use (ReAct)? → Composer Orchestrator
│  └─ Need CoT/ToT/GoT? → Jido AI agent, optionally inside a Composer workflow
│
├─ Need parallel branches?
│  └─ Composer FanOutNode
│
├─ Need human approval gates?
│  └─ Composer HumanNode + ApprovalGate
│
├─ Need checkpoint/resume across restarts?
│  └─ Composer Checkpoint
│
├─ Quick one-shot LLM call?
│  └─ Jido.AI.ask/2
│
└─ Long-lived agent with concurrent requests?
   └─ Jido AI agent process
```

## Shared Foundation

Both libraries build on the same Jido core:

- **Jido Actions** — The universal tool/task unit (`use Jido.Action`)
- **Jido Signals** — Typed events for observability
- **req_llm** — Provider abstraction (Anthropic, OpenAI, Google)
- **Telemetry** — Observable spans and metrics

Actions defined for one library work in the other without changes. An action
used as a Jido AI tool is the same module used as a Composer node.
