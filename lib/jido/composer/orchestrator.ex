defmodule Jido.Composer.Orchestrator do
  @moduledoc """
  LLM-driven orchestrator DSL.

  `use Jido.Composer.Orchestrator` generates a `Jido.Agent` module that uses
  an LLM to dynamically invoke available tools via a ReAct loop. The LLM
  decides which tools to call, receives results, and continues reasoning
  until it provides a final answer.

  ## Example

      defmodule MathAssistant do
        use Jido.Composer.Orchestrator,
          name: "math_assistant",
          model: "anthropic:claude-sonnet-4-20250514",
          nodes: [AddAction, MultiplyAction],
          system_prompt: "You are a math assistant. Use the available tools.",
          max_iterations: 5
      end

      agent = MathAssistant.new()
      {:ok, _agent, answer} = MathAssistant.query_sync(agent, "What is (5 + 3) * 2?")

  ## Generated Functions

  - `new/0` — Create a new agent instance
  - `query/3` — Start the ReAct loop, returns `{agent, directives}`
  - `query_sync/3` — Run to completion, returns `{:ok, agent, result}`, `{:suspended, agent, suspension}`, or `{:error, reason}`

  See the [Orchestrators Guide](orchestrators.md) for all DSL options,
  LLM config, tool approval gates, generation modes, and backpressure.

  See `Jido.Composer.Orchestrator.DSL` for implementation details.
  """

  defmacro __using__(opts) do
    quote do
      use Jido.Composer.Orchestrator.DSL, unquote(opts)
    end
  end
end
