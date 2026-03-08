defmodule Jido.Composer.ApprovalGate do
  @moduledoc """
  Typed sub-state for tracking approval gates in the Orchestrator.

  Replaces flat `gated_node_names`, `approval_policy`, `rejection_policy`,
  and `gated_calls` fields in Orchestrator Strategy.
  """

  alias Jido.Composer.Context
  alias Jido.Composer.HITL.ApprovalRequest

  @derive {Jason.Encoder, except: [:approval_policy]}

  defstruct gated_node_names: MapSet.new(),
            approval_policy: nil,
            rejection_policy: :continue_siblings,
            gated_calls: %{}

  @type t :: %__MODULE__{
          gated_node_names: MapSet.t(),
          approval_policy: (map(), map() -> :require_approval | term()) | nil,
          rejection_policy: :abort_iteration | :cancel_siblings | :continue_siblings,
          gated_calls: %{String.t() => %{request: ApprovalRequest.t(), call: map()}}
        }

  @doc "Creates a new ApprovalGate from options."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      gated_node_names: MapSet.new(Keyword.get(opts, :gated_nodes, [])),
      approval_policy: Keyword.get(opts, :approval_policy),
      rejection_policy: Keyword.get(opts, :rejection_policy, :continue_siblings),
      gated_calls: %{}
    }
  end

  @doc """
  Checks whether a tool call requires approval based on static gating
  and the dynamic approval policy.
  """
  @spec requires_approval?(t(), map(), Context.t()) :: boolean()
  def requires_approval?(%__MODULE__{} = gate, call, context) do
    if MapSet.member?(gate.gated_node_names, call.name) do
      true
    else
      case gate.approval_policy do
        nil ->
          false

        policy when is_function(policy, 2) ->
          policy.(call, Context.to_flat_map(context)) == :require_approval
      end
    end
  end

  @doc """
  Partitions tool calls into ungated (ready to dispatch) and gated (need approval).

  Returns `{ungated_calls, gated_entries_map}` where gated_entries_map is
  `%{request_id => %{request: ApprovalRequest, call: call}}`.
  """
  @spec partition_calls(t(), [map()], Context.t()) ::
          {:ok, [map()], %{String.t() => map()}} | {:error, term()}
  def partition_calls(%__MODULE__{} = gate, calls, context) do
    {ungated, gated} =
      Enum.split_with(calls, fn call ->
        not requires_approval?(gate, call, context)
      end)

    gated_results =
      Enum.reduce_while(gated, {:ok, %{}}, fn call, {:ok, acc} ->
        case ApprovalRequest.new(
               prompt: "Approve tool call: #{call.name}(#{inspect(call.arguments)})",
               allowed_responses: [:approved, :rejected],
               visible_context: call.arguments,
               metadata: %{tool_call_id: call.id, tool_name: call.name}
             ) do
          {:ok, request} ->
            {:cont, {:ok, Map.put(acc, request.id, %{request: request, call: call})}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case gated_results do
      {:ok, gated_entries} -> {:ok, ungated, gated_entries}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stores gated call entries in the gate state."
  @spec gate_calls(t(), map()) :: t()
  def gate_calls(%__MODULE__{} = gate, gated_entries) do
    %{gate | gated_calls: gated_entries}
  end

  @doc "Retrieves a gated call entry by request_id."
  @spec get(t(), String.t()) :: map() | nil
  def get(%__MODULE__{} = gate, request_id) do
    Map.get(gate.gated_calls, request_id)
  end

  @doc "Removes a gated call by request_id. Returns updated gate."
  @spec remove(t(), String.t()) :: t()
  def remove(%__MODULE__{} = gate, request_id) do
    %{gate | gated_calls: Map.delete(gate.gated_calls, request_id)}
  end

  @doc "Returns true when there are pending gated calls."
  @spec has_pending?(t()) :: boolean()
  def has_pending?(%__MODULE__{gated_calls: calls}) when calls == %{}, do: false
  def has_pending?(%__MODULE__{}), do: true
end
