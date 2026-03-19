# Testing Strategy

Jido Composer uses TDD across unit, integration, and end-to-end layers.
LLM-facing paths are validated with recorded HTTP traffic via
[ReqCassette](https://hexdocs.pm/req_cassette), while deterministic strategy
loops are often driven with `LLMStub`.

## Cassettes Over Mocks

Guiding principle: use cassettes for network/protocol realism, and use stubs
for deterministic strategy-loop control.

| Approach      | When to Use                                                                                |
| ------------- | ------------------------------------------------------------------------------------------ |
| **Cassette**  | HTTP/Req/req_llm boundaries, provider response shape, replayable E2E and integration paths |
| **LLMStub**   | Deterministic strategy tests and directive-loop tests (direct or Req.Test plug mode)       |
| **No double** | Pure data structures (Machine transitions, context merge, AgentTool conversion)            |

Cassettes preserve full response shape (headers/status/body), which catches
provider format drift earlier than hand-written fixtures.

## Test Layers

```mermaid
graph TB
    subgraph "End-to-End Tests"
        E2E["Full orchestration flows<br/>with recorded LLM cassettes"]
    end

    subgraph "Integration Tests"
        INT["Composition, nesting,<br/>cassette-driven LLM interactions"]
    end

    subgraph "Unit Tests"
        UNIT["Machine, Node, AgentTool<br/>+ cassette-driven response parsing"]
    end

    E2E --> INT --> UNIT

    style UNIT fill:#e8f5e9,stroke:#4caf50
    style INT fill:#fff3e0,stroke:#ff9800
    style E2E fill:#e3f2fd,stroke:#2196f3
```

| Layer           | Scope                                | LLM Data Source         | Speed |
| --------------- | ------------------------------------ | ----------------------- | ----- |
| **Unit**        | Single module in isolation           | None or LLMStub         | Fast  |
| **Integration** | Multi-module composition             | LLMStub and/or cassette | Fast  |
| **End-to-end**  | Full stack orchestration             | Cassette                | Fast  |
| **Recording**   | Capture new cassettes from real APIs | Real network            | Slow  |

### Unit Tests

Representative unit coverage:

| Module                  | Test Focus                                                           | Data Source |
| ----------------------- | -------------------------------------------------------------------- | ----------- |
| `Machine`               | Transition lookup, wildcard fallbacks, terminal detection            | None (pure) |
| `ActionNode`            | Context accumulation via deep merge                                  | None (pure) |
| `AgentNode`             | Struct construction, mode validation                                 | None (pure) |
| `AgentTool`             | Node-to-ReqLLM.Tool conversion, argument mapping, result formatting  | None (pure) |
| `Orchestrator.Strategy` | Directive emission for LLM/tool results, concurrency, gating, replay | LLMStub     |
| `Workflow.Strategy`     | FSM execution, directive emission                                    | None (pure) |
| `Error`                 | Error class construction, message formatting                         | None (pure) |

### Integration Tests

Integration tests verify multi-module composition with both deterministic stubs
and recorded LLM responses, depending on scenario.

| Scenario                       | Components Under Test                             |
| ------------------------------ | ------------------------------------------------- |
| Linear workflow                | Machine + Strategy + ActionNodes in sequence      |
| Branching workflow             | Machine + Strategy + outcome-driven transitions   |
| Error handling workflow        | Machine + Strategy + wildcard error transitions   |
| Nested workflow                | Workflow containing another Workflow as AgentNode |
| Orchestrator single tool call  | Strategy + LLM (cassette) + ActionNode            |
| Orchestrator multi-turn        | Strategy + LLM (cassette) + multiple tool rounds  |
| Orchestrator with agent tools  | Strategy + LLM (cassette) + AgentNode             |
| Orchestrator invoking workflow | Strategy + LLM (cassette) + Workflow as tool      |

### End-to-End Tests

Full-stack orchestration with real recorded LLM interactions:

| Scenario                     | What It Validates                                             |
| ---------------------------- | ------------------------------------------------------------- |
| Orchestrator with real LLM   | Full ReAct loop against recorded Claude/OpenAI responses      |
| Tool calling round-trip      | LLM tool call format parsing and result message construction  |
| Multi-turn conversation      | Context accumulation across multiple LLM interactions         |
| Nested orchestrator with LLM | Cross-boundary LLM calls with cassette recording              |
| Error responses              | Handling of real API errors (rate limits, malformed requests) |

## ReqCassette Integration

[ReqCassette](https://hexdocs.pm/req_cassette) records HTTP interactions to
JSON cassette files and replays them in subsequent test runs. It integrates
with the [Req](https://hexdocs.pm/req) HTTP client via the `plug:` option.
Since req_llm is built on Req, cassettes intercept all LLM API calls
transparently.

### How It Works

```mermaid
sequenceDiagram
    participant Test
    participant Cassette as ReqCassette
    participant LLMAction as LLMAction
    participant ReqLLM as req_llm
    participant Req as Req HTTP
    participant API as LLM API

    Test->>Cassette: with_cassette("test_name", fn plug -> ... end)

    alt First run (recording)
        Test->>LLMAction: run(params with req_options: [plug: plug])
        LLMAction->>ReqLLM: generate_text(model, context, req_http_options: [plug: plug])
        ReqLLM->>Req: request(plug: plug, ...)
        Req->>Cassette: intercepted by plug
        Cassette->>API: forward to real API
        API-->>Cassette: real response
        Cassette->>Cassette: save to cassette file
        Cassette-->>Req: return response
        Req-->>ReqLLM: parsed response
    else Subsequent runs (replay)
        Test->>LLMAction: run(params with req_options: [plug: plug])
        LLMAction->>ReqLLM: generate_text(model, context, req_http_options: [plug: plug])
        ReqLLM->>Req: request(plug: plug, ...)
        Req->>Cassette: intercepted by plug
        Cassette->>Cassette: match request in cassette
        Cassette-->>Req: return saved response
        Req-->>ReqLLM: parsed response
    end
```

### Cassette Modes

| Mode      | Purpose                                                        |
| --------- | -------------------------------------------------------------- |
| `:record` | Record if cassette missing, replay if present. For development |
| `:replay` | Replay only, error if missing. For CI                          |
| `:bypass` | Ignore cassettes, always hit network. For debugging            |

### Sensitive Data Filtering

Cassettes must never contain API keys, authentication tokens, or other secrets.
All cassette-based tests apply filtering:

| Filter                    | What It Removes                           |
| ------------------------- | ----------------------------------------- |
| `filter_request_headers`  | `authorization`, `x-api-key`, `cookie`    |
| `filter_response_headers` | `set-cookie`                              |
| `filter_sensitive_data`   | Regex patterns for inline tokens and keys |

Concrete patterns applied to all LLM cassettes:

| Pattern                        | Replacement              | Catches                 |
| ------------------------------ | ------------------------ | ----------------------- |
| `~r/sk-ant-[a-zA-Z0-9_-]+/`    | `<ANTHROPIC_KEY>`        | Anthropic API keys      |
| `~r/sk-[a-zA-Z0-9]{20,}/`      | `<OPENAI_KEY>`           | OpenAI API keys         |
| `~r/"api_key"\s*:\s*"[^"]+"/`  | `"api_key":"<REDACTED>"` | JSON-embedded API keys  |
| `~r/Bearer\s+[a-zA-Z0-9._-]+/` | `Bearer <TOKEN>`         | Bearer tokens in bodies |

These filters are centralized in a shared test helper (`test/support/cassette_helper.ex`)
so every cassette-based test applies them consistently.

## Req Options Propagation

For cassette testing to work, the `plug:` option must reach the actual Req HTTP
call inside req_llm. LLMAction maps the strategy's `:req_options` to req_llm's
`:req_http_options` key, which passes options through to the underlying Req
calls.

### The Propagation Path

```mermaid
flowchart LR
    Test["Test<br/>(with_cassette)"]
    Strategy["Orchestrator<br/>Strategy"]
    LLMAction["LLMAction<br/>(run/2)"]
    ReqLLM["req_llm<br/>(generate_text/3)"]
    Req["Req HTTP<br/>(plug: ...)"]

    Test -->|"req_options in context<br/>or opts"| Strategy
    Strategy -->|"params[:req_options]"| LLMAction
    LLMAction -->|"req_http_options:"| ReqLLM
    ReqLLM -->|"plug: ..."| Req
```

[LLMAction](orchestrator/llm-integration.md) accepts `req_options` as part of
its instruction params and maps it to `req_http_options` for req_llm. This
keeps the transport concern entirely within LLMAction and the test setup.

### What Propagates

| Option | Purpose                               | Default |
| ------ | ------------------------------------- | ------- |
| `plug` | ReqCassette plug for recording/replay | `nil`   |

### Design Constraints

- **LLMAction owns the HTTP calls.** The Orchestrator Strategy never makes
  HTTP requests directly -- it delegates to LLMAction via RunInstruction
  directives.
- **req_options are opaque to the strategy.** The strategy passes them through
  to LLMAction without inspecting or modifying them.
- **The test controls the transport.** By providing `plug:` through
  `req_options`, the test intercepts all HTTP traffic without the strategy or
  LLMAction needing special test-mode logic.

## LLMStub Patterns

Jido.Composer.TestSupport.LLMStub (`test/support/llm_stub.ex`) provides
predetermined LLM responses for tests that do not need real HTTP interactions.
It operates in two modes:

| Mode        | Entry Point                     | Typical Use                                                       |
| ----------- | ------------------------------- | ----------------------------------------------------------------- |
| Direct mode | `LLMStub.setup/1` + `execute/1` | Strategy tests that manually drive `RunInstruction`/`cmd` loops   |
| Plug mode   | `LLMStub.setup_req_stub/2`      | DSL `query_sync` and integration tests that still run through Req |

Supported stub responses: `{:tool_calls, calls}`, `{:final_answer, text}`, and
`{:error, reason}`.

## Directory Structure

```
test/
├── cassettes/                      # ReqCassette cassette files
│   ├── e2e_orchestrator_*.json
│   ├── orchestrator_*.json
│   └── ...
├── support/
│   ├── test_actions.ex             # Stub action modules
│   ├── test_agents.ex              # Stub agent modules
│   ├── llm_stub.ex                 # LLMStub: direct mode + Req plug mode
│   └── cassette_helper.ex          # Shared cassette setup and filtering
├── jido/composer/
│   ├── node_test.exs               # Unit: Node behaviour
│   ├── node/
│   │   ├── action_node_test.exs    # Unit: ActionNode
│   │   └── agent_node_test.exs     # Unit: AgentNode
│   ├── workflow/
│   │   ├── machine_test.exs        # Unit: Machine
│   │   ├── strategy_test.exs       # Unit: Workflow Strategy
│   │   └── dsl_test.exs            # Unit: Workflow DSL
│   └── orchestrator/
│       ├── agent_tool_test.exs     # Unit: AgentTool adapter
│       ├── strategy_test.exs       # Unit: Orchestrator Strategy (LLMStub-driven)
│       └── dsl_test.exs            # Unit: Orchestrator DSL
├── integration/
│   ├── workflow_test.exs           # Integration: workflow compositions
│   ├── orchestrator_test.exs       # Integration: orchestrator compositions (cassette)
│   └── composition_test.exs        # Integration: nesting scenarios (cassette)
└── e2e/
    └── e2e_test.exs                # E2E: full workflow + orchestrator scenarios
```

## TDD Workflow

For each implementation step:

1. **Write the test first.** Define the expected behaviour through test cases.
   For modules that process LLM responses, record a cassette first and write
   the test against it.

2. **Verify the test fails.** The test must fail (or not compile) before
   implementation begins.

3. **Implement the minimum code** to make the test pass.

4. **Refactor** while keeping tests green.

### Test-First Implementation Order

Each implementation step follows this pattern:

| Phase | Action                                    | Outcome                        |
| ----- | ----------------------------------------- | ------------------------------ |
| 1     | Write test for the module's contract      | Red (fails or doesn't compile) |
| 2     | Implement the module                      | Green (tests pass)             |
| 3     | Write integration test with cassette data | Red                            |
| 4     | Wire modules together                     | Green                          |
| 5     | Run `mix precommit`                       | Clean quality gate             |

For the Orchestrator track, cassettes are recorded early — before strategy
implementation — so that tests drive development against real LLM response
structures from the start.
