defmodule Jido.Composer.ResumeTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Checkpoint
  alias Jido.Composer.Node.HumanNode
  alias Jido.Composer.Resume

  alias Jido.Composer.TestActions.{
    NoopAction,
    AccumulatorAction
  }

  # -- Test workflow that suspends --

  defmodule ResumeWorkflow do
    use Jido.Composer.Workflow,
      name: "resume_workflow",
      description: "Workflow for resume tests",
      nodes: %{
        process: AccumulatorAction,
        approval: %HumanNode{
          name: "approval",
          description: "Approve",
          prompt: "Approve?",
          allowed_responses: [:approved, :rejected],
          timeout: 30_000
        },
        finish: NoopAction
      },
      transitions: %{
        {:process, :ok} => :approval,
        {:approval, :approved} => :finish,
        {:approval, :rejected} => :failed,
        {:approval, :timeout} => :failed,
        {:finish, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :process
  end

  # -- Helpers --

  defp run_to_suspend(agent) do
    {agent, directives} = ResumeWorkflow.run(agent, %{tag: "test"})
    execute_until_suspend(ResumeWorkflow, agent, directives)
  end

  defp execute_until_suspend(_mod, agent, []), do: {agent, []}

  defp execute_until_suspend(mod, agent, [directive | rest]) do
    case directive do
      %Jido.Agent.Directive.RunInstruction{instruction: instr, result_action: result_action} ->
        payload = execute_instruction(instr)
        {agent, new_directives} = mod.cmd(agent, {result_action, payload})
        execute_until_suspend(mod, agent, new_directives ++ rest)

      %Jido.Composer.Directive.Suspend{} = suspend ->
        {agent, [suspend | rest]}

      _other ->
        execute_until_suspend(mod, agent, rest)
    end
  end

  defp execute_instruction(%Jido.Instruction{action: action_module, params: params}) do
    case Jido.Exec.run(action_module, params) do
      {:ok, result} ->
        %{
          status: :ok,
          result: result,
          instruction: %Jido.Instruction{action: action_module, params: params},
          effects: [],
          meta: %{}
        }

      {:error, reason} ->
        %{
          status: :error,
          reason: reason,
          instruction: %Jido.Instruction{action: action_module, params: params},
          effects: [],
          meta: %{}
        }
    end
  end

  # -- Tests --

  describe "resume/5 delivers signal to live agent" do
    test "delivers resume signal via callback to live agent" do
      agent = ResumeWorkflow.new()
      {suspended_agent, _directives} = run_to_suspend(agent)

      strat = StratState.get(suspended_agent)
      suspension = strat.pending_suspension

      # The deliver_fn simulates what AgentServer would do
      deliver_fn = fn agent_to_resume, signal ->
        ResumeWorkflow.cmd(agent_to_resume, signal)
      end

      result =
        Resume.resume(
          suspended_agent,
          suspension.id,
          %{
            decision: :approved,
            request_id: suspension.approval_request.id
          },
          deliver_fn: deliver_fn
        )

      assert {:ok, resumed_agent, _directives} = result
      resumed_strat = StratState.get(resumed_agent)
      assert resumed_strat.pending_suspension == nil
    end
  end

  describe "resume/5 thaws from checkpoint" do
    test "thaws from checkpoint when not live" do
      agent = ResumeWorkflow.new()
      {suspended_agent, _directives} = run_to_suspend(agent)

      strat = StratState.get(suspended_agent)
      suspension = strat.pending_suspension

      # Checkpoint the agent
      checkpoint_data = Checkpoint.prepare_for_checkpoint(strat)
      binary = :erlang.term_to_binary(checkpoint_data, [:compressed])

      # Simulate thaw_fn that restores from binary
      thaw_fn = fn _agent_id ->
        restored_strat = :erlang.binary_to_term(binary)
        fresh_agent = ResumeWorkflow.new()
        {:ok, StratState.put(fresh_agent, restored_strat)}
      end

      deliver_fn = fn agent_to_resume, signal ->
        ResumeWorkflow.cmd(agent_to_resume, signal)
      end

      result =
        Resume.resume(
          nil,
          suspension.id,
          %{
            decision: :approved,
            request_id: suspension.approval_request.id
          },
          thaw_fn: thaw_fn,
          deliver_fn: deliver_fn,
          agent_id: agent.id
        )

      assert {:ok, resumed_agent, _directives} = result
      resumed_strat = StratState.get(resumed_agent)
      assert resumed_strat.pending_suspension == nil
    end
  end

  describe "resume/5 idempotency" do
    test "rejects already-resumed checkpoint" do
      agent = ResumeWorkflow.new()
      {suspended_agent, _directives} = run_to_suspend(agent)

      strat = StratState.get(suspended_agent)
      suspension = strat.pending_suspension

      deliver_fn = fn agent_to_resume, signal ->
        ResumeWorkflow.cmd(agent_to_resume, signal)
      end

      # First resume succeeds
      {:ok, resumed_agent, _} =
        Resume.resume(
          suspended_agent,
          suspension.id,
          %{decision: :approved, request_id: suspension.approval_request.id},
          deliver_fn: deliver_fn
        )

      # Second resume on the already-resumed agent should fail
      result =
        Resume.resume(
          resumed_agent,
          suspension.id,
          %{decision: :approved, request_id: suspension.approval_request.id},
          deliver_fn: deliver_fn
        )

      assert {:error, :no_matching_suspension} = result
    end
  end

  describe "resume/5 error cases" do
    test "returns error for unknown agent (nil agent, no thaw_fn)" do
      result =
        Resume.resume(
          nil,
          "unknown-id",
          %{},
          deliver_fn: fn _a, _s -> {%{}, []} end
        )

      assert {:error, :agent_not_available} = result
    end
  end
end
