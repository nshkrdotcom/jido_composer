defmodule Jido.Composer.Orchestrator.LLM do
  @moduledoc """
  Abstract LLM behaviour for orchestrator decision-making.

  Any module implementing this behaviour can serve as the decision engine for an
  Orchestrator. This keeps Jido Composer decoupled from any specific LLM provider.

  ## Contract

  The behaviour defines a single callback `generate/4`:

      generate(conversation, tool_results, tools, opts)

  ### Parameters

  - `conversation` — Opaque conversation state owned by the LLM module.
    Pass `nil` on the first call; the strategy stores and passes it back unchanged.
  - `tool_results` — Normalized results from previous tool executions (empty list on first call).
  - `tools` — Available tool descriptions in neutral format (name, description, parameters).
  - `opts` — LLM-specific options. The reserved key `:req_options` is merged into HTTP calls.

  ### Response Types

  The callback returns `{:ok, response, conversation}` or `{:error, reason}`.

  Response variants:

  - `{:final_answer, text}` — The LLM has enough information to respond.
  - `{:tool_calls, calls}` — The LLM wants to invoke one or more tools.
  - `{:tool_calls, calls, reasoning}` — Tool calls with accompanying reasoning text.
  - `{:error, reason}` — Generation failed.
  """

  @type tool :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @type tool_call :: %{
          id: String.t(),
          name: String.t(),
          arguments: map()
        }

  @type tool_result :: %{
          id: String.t(),
          name: String.t(),
          result: map()
        }

  @type conversation :: term()

  @type response ::
          {:final_answer, String.t()}
          | {:tool_calls, [tool_call()]}
          | {:tool_calls, [tool_call()], String.t()}
          | {:error, term()}

  @callback generate(
              conversation :: conversation() | nil,
              tool_results :: [tool_result()],
              tools :: [tool()],
              opts :: keyword()
            ) :: {:ok, response(), conversation()} | {:error, term()}
end
