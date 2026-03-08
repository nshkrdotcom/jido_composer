defmodule Jido.Composer.Orchestrator.StatusComputer do
  @moduledoc """
  Computes orchestrator status from sub-state modules.

  Replaces scattered status `cond` blocks in the Orchestrator Strategy.
  """

  alias Jido.Composer.ApprovalGate
  alias Jido.Composer.ToolConcurrency

  @type status ::
          :awaiting_llm
          | :awaiting_tools
          | :awaiting_approval
          | :awaiting_suspension
          | :awaiting_tools_and_approval
          | :awaiting_tools_and_suspension

  @doc """
  Computes the orchestrator status based on tool concurrency, approval gate,
  and suspended calls state.

  Returns `:awaiting_llm` when all sub-systems are clear, otherwise returns
  a status reflecting what the orchestrator is waiting on.
  """
  @spec compute(ToolConcurrency.t(), ApprovalGate.t(), map()) :: status()
  def compute(%ToolConcurrency{} = tc, %ApprovalGate{} = ag, suspended_calls) do
    tc_clear = ToolConcurrency.all_clear?(tc)
    has_gated = ApprovalGate.has_pending?(ag)
    has_suspended = suspended_calls != %{}

    if tc_clear and not has_gated and not has_suspended do
      :awaiting_llm
    else
      has_pending = ToolConcurrency.has_pending?(tc)

      cond do
        has_suspended and not has_pending and not has_gated ->
          :awaiting_suspension

        not has_gated and not has_suspended ->
          :awaiting_tools

        not has_pending and not has_suspended ->
          :awaiting_approval

        has_suspended and has_pending ->
          :awaiting_tools_and_suspension

        true ->
          :awaiting_tools_and_approval
      end
    end
  end
end
