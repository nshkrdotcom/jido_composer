defmodule Jido.Composer do
  @moduledoc """
  Composable agent flows via FSM for the Jido ecosystem.

  Jido Composer provides two composition patterns for Jido agents:

  1. **Workflow** — Deterministic FSM-based pipeline. Each state binds to an
     action or sub-agent. No LLM decisions; transitions are fully determined by
     outcomes.

  2. **Orchestrator** — An agent that uses an LLM (or other decision function)
     to freely compose available sub-agents and actions at runtime.

  Both patterns share a `Jido.Composer.Node` abstraction (uniform
  `context → context` interface) and support arbitrary nesting.
  """
end
