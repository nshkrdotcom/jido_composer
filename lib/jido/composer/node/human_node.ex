defmodule Jido.Composer.Node.HumanNode do
  @moduledoc """
  A Node representing a point where a human must provide input.

  When `run/2` is called, a HumanNode evaluates its prompt, filters
  the context, constructs an `ApprovalRequest`, places it in context
  under `__approval_request__`, and returns `{:ok, context, :suspend}`.

  The HumanNode never blocks or waits. The strategy layer interprets
  the `:suspend` outcome to pause the flow and emit a SuspendForHuman
  directive.
  """

  @behaviour Jido.Composer.Node

  alias Jido.Composer.HITL.ApprovalRequest

  @enforce_keys [:name, :description, :prompt]
  defstruct [
    :name,
    :description,
    :prompt,
    :response_schema,
    :context_keys,
    allowed_responses: [:approved, :rejected],
    timeout: :infinity,
    timeout_outcome: :timeout,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          prompt: String.t() | (map() -> String.t()),
          allowed_responses: [atom()],
          response_schema: keyword() | nil,
          timeout: pos_integer() | :infinity,
          timeout_outcome: atom(),
          context_keys: [atom()] | nil,
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs) do
    attrs_map = Map.new(attrs)

    with :ok <- validate_required(attrs_map, :name, "name is required"),
         :ok <- validate_required(attrs_map, :description, "description is required"),
         :ok <- validate_required(attrs_map, :prompt, "prompt is required") do
      {:ok,
       %__MODULE__{
         name: attrs_map.name,
         description: attrs_map.description,
         prompt: attrs_map.prompt,
         allowed_responses: Map.get(attrs_map, :allowed_responses, [:approved, :rejected]),
         response_schema: Map.get(attrs_map, :response_schema),
         timeout: Map.get(attrs_map, :timeout, :infinity),
         timeout_outcome: Map.get(attrs_map, :timeout_outcome, :timeout),
         context_keys: Map.get(attrs_map, :context_keys),
         metadata: Map.get(attrs_map, :metadata, %{})
       }}
    end
  end

  @impl true
  @spec run(t(), map(), keyword()) :: {:ok, map(), :suspend}
  def run(%__MODULE__{} = node, context, _opts \\ []) do
    prompt = evaluate_prompt(node.prompt, context)
    visible_context = filter_context(context, node.context_keys)

    {:ok, request} =
      ApprovalRequest.new(
        prompt: prompt,
        allowed_responses: node.allowed_responses,
        visible_context: visible_context,
        response_schema: node.response_schema,
        timeout: node.timeout,
        timeout_outcome: node.timeout_outcome,
        metadata: node.metadata
      )

    updated_context = Map.put(context, :__approval_request__, request)
    {:ok, updated_context, :suspend}
  end

  @impl true
  @spec name(t()) :: String.t()
  def name(%__MODULE__{name: name}), do: name

  @impl true
  @spec description(t()) :: String.t()
  def description(%__MODULE__{description: desc}), do: desc

  @impl true
  @spec schema(t()) :: keyword() | nil
  def schema(%__MODULE__{response_schema: schema}), do: schema

  @impl true
  @spec to_directive(t(), map(), keyword()) :: Jido.Composer.Node.directive_result()
  def to_directive(%__MODULE__{} = node, flat_context, opts) do
    {:ok, updated_context, :suspend} = run(node, flat_context)

    request = updated_context.__approval_request__

    # Enrich with strategy-provided metadata
    request_fields = Keyword.get(opts, :request_fields, %{})
    request = struct(request, request_fields)

    {:ok, suspension} = Jido.Composer.Suspension.from_approval_request(request)

    case Jido.Composer.Directive.SuspendForHuman.new(approval_request: request) do
      {:ok, directive} ->
        {:ok, [directive], pending_suspension: suspension, status: :waiting}

      {:error, reason} ->
        {:ok,
         [
           %Jido.Agent.Directive.Error{
             error: %RuntimeError{message: "Failed to create HITL directive: #{reason}"}
           }
         ]}
    end
  end

  @impl true
  @spec to_tool_spec(t()) :: nil
  def to_tool_spec(%__MODULE__{}), do: nil

  defp evaluate_prompt(prompt, _context) when is_binary(prompt), do: prompt
  defp evaluate_prompt(prompt, context) when is_function(prompt, 1), do: prompt.(context)

  defp filter_context(context, nil), do: context
  defp filter_context(context, keys), do: Map.take(context, keys)

  defp validate_required(attrs, key, message) do
    if Map.has_key?(attrs, key), do: :ok, else: {:error, message}
  end
end
