defmodule Jido.Composer.Directive.SuspendForHuman do
  @moduledoc """
  Convenience wrapper that builds a generalized `Suspend` directive
  with `reason: :human_input` and an embedded `ApprovalRequest`.

  Existing code calling `SuspendForHuman.new(approval_request: req)`
  gets back a `%Suspend{}` directive. The struct is retained for
  backward-compatible pattern matching in directive execution.
  """

  alias Jido.Composer.Directive.Suspend
  alias Jido.Composer.HITL.ApprovalRequest
  alias Jido.Composer.Suspension

  @doc """
  Creates a `%Suspend{}` directive wrapping a `Suspension` with
  `reason: :human_input` and the given `ApprovalRequest`.
  """
  @spec new(keyword()) :: {:ok, Suspend.t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs) do
    attrs_map = Map.new(attrs)

    with :ok <- validate_approval_request(attrs_map[:approval_request]) do
      {:ok, suspension} = Suspension.from_approval_request(attrs_map.approval_request)

      {:ok,
       %Suspend{
         suspension: suspension,
         notification: Map.get(attrs_map, :notification),
         hibernate: Map.get(attrs_map, :hibernate, false)
       }}
    end
  end

  defp validate_approval_request(%ApprovalRequest{}), do: :ok
  defp validate_approval_request(nil), do: {:error, "approval_request is required"}

  defp validate_approval_request(_),
    do: {:error, "approval_request must be an ApprovalRequest struct"}
end
