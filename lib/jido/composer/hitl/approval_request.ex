defmodule Jido.Composer.HITL.ApprovalRequest do
  @moduledoc """
  A serializable struct representing a pending human decision.

  Constructed by the HumanNode and enriched by the strategy with flow
  identification. Contains no PIDs, closures, or process references — it
  can be persisted, sent over the wire, or displayed in any UI.

  ## Required Fields

  - `prompt` — Human-readable question
  - `allowed_responses` — Outcome atoms the human can choose from

  ## Strategy-Set Fields

  The following fields are typically set by the strategy layer after the
  HumanNode constructs the initial request:

  - `agent_id`, `agent_module` — identity of the suspended agent
  - `workflow_state` — current FSM state (Workflow only)
  - `tool_call` — triggering tool call (Orchestrator only)
  - `node_name` — name of the HumanNode or gated node
  """

  @derive Jason.Encoder

  @enforce_keys [:id, :prompt, :allowed_responses, :created_at]
  defstruct [
    :id,
    :prompt,
    :allowed_responses,
    :created_at,
    :response_schema,
    :agent_id,
    :agent_module,
    :workflow_state,
    :tool_call,
    :node_name,
    visible_context: %{},
    timeout: :infinity,
    timeout_outcome: :timeout,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          prompt: String.t(),
          allowed_responses: [atom()],
          created_at: DateTime.t(),
          visible_context: map(),
          response_schema: keyword() | nil,
          timeout: pos_integer() | :infinity,
          timeout_outcome: atom(),
          metadata: map(),
          agent_id: String.t() | nil,
          agent_module: module() | nil,
          workflow_state: atom() | nil,
          tool_call: map() | nil,
          node_name: String.t() | nil
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs) do
    attrs = Map.new(attrs)

    with :ok <- validate_required(attrs, :prompt, "prompt is required"),
         :ok <- validate_required(attrs, :allowed_responses, "allowed_responses is required"),
         :ok <- validate_non_empty_list(attrs[:allowed_responses]) do
      {:ok,
       %__MODULE__{
         id: Map.get(attrs, :id, generate_id()),
         prompt: attrs.prompt,
         allowed_responses: attrs.allowed_responses,
         created_at: Map.get(attrs, :created_at, DateTime.utc_now()),
         visible_context: Map.get(attrs, :visible_context, %{}),
         response_schema: Map.get(attrs, :response_schema),
         timeout: Map.get(attrs, :timeout, :infinity),
         timeout_outcome: Map.get(attrs, :timeout_outcome, :timeout),
         metadata: Map.get(attrs, :metadata, %{}),
         agent_id: Map.get(attrs, :agent_id),
         agent_module: Map.get(attrs, :agent_module),
         workflow_state: Map.get(attrs, :workflow_state),
         tool_call: Map.get(attrs, :tool_call),
         node_name: Map.get(attrs, :node_name)
       }}
    end
  end

  defp validate_required(attrs, key, message) do
    if Map.has_key?(attrs, key), do: :ok, else: {:error, message}
  end

  defp validate_non_empty_list([_ | _]), do: :ok
  defp validate_non_empty_list(_), do: {:error, "allowed_responses must be a non-empty list"}

  defp generate_id do
    "hitl-req-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end
end
