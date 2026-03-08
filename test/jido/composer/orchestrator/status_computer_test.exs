defmodule Jido.Composer.Orchestrator.StatusComputerTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.ApprovalGate
  alias Jido.Composer.Orchestrator.StatusComputer
  alias Jido.Composer.ToolConcurrency

  defp tc(opts \\ []), do: ToolConcurrency.new(opts)
  defp ag(opts \\ []), do: ApprovalGate.new(opts)

  describe "compute/3" do
    test "awaiting_llm when all clear" do
      assert StatusComputer.compute(tc(), ag(), %{}) == :awaiting_llm
    end

    test "awaiting_tools when tools pending, no gated, no suspended" do
      tc = ToolConcurrency.dispatch(tc(), ["a"], [])
      assert StatusComputer.compute(tc, ag(), %{}) == :awaiting_tools
    end

    test "awaiting_tools when tools queued, no gated, no suspended" do
      tc = ToolConcurrency.dispatch(tc(max_concurrency: 1), ["a"], [%{id: "b"}])
      assert StatusComputer.compute(tc, ag(), %{}) == :awaiting_tools
    end

    test "awaiting_approval when gated, no pending, no suspended" do
      ag = ApprovalGate.gate_calls(ag(), %{"req1" => %{request: :r, call: :c}})
      assert StatusComputer.compute(tc(), ag, %{}) == :awaiting_approval
    end

    test "awaiting_suspension when suspended, no pending, no gated" do
      assert StatusComputer.compute(tc(), ag(), %{"s1" => %{}}) == :awaiting_suspension
    end

    test "awaiting_tools_and_approval when both pending and gated" do
      tc = ToolConcurrency.dispatch(tc(), ["a"], [])
      ag = ApprovalGate.gate_calls(ag(), %{"req1" => %{request: :r, call: :c}})
      assert StatusComputer.compute(tc, ag, %{}) == :awaiting_tools_and_approval
    end

    test "awaiting_tools_and_suspension when both pending and suspended" do
      tc = ToolConcurrency.dispatch(tc(), ["a"], [])
      assert StatusComputer.compute(tc, ag(), %{"s1" => %{}}) == :awaiting_tools_and_suspension
    end
  end
end
