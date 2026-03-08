defmodule Jido.Composer.Integration.WorkflowHITLTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Directive.Suspend
  alias Jido.Composer.HITL.{ApprovalRequest, ApprovalResponse}
  alias Jido.Composer.Node.HumanNode

  alias Jido.Composer.Suspension

  alias Jido.Composer.TestActions.{
    NoopAction,
    AccumulatorAction,
    RateLimitAction
  }

  # -- Workflow definitions --

  defmodule ApprovalWorkflow do
    use Jido.Composer.Workflow,
      name: "approval_workflow",
      description: "Process -> Approve -> Execute pipeline",
      nodes: %{
        process: AccumulatorAction,
        approval: %HumanNode{
          name: "deploy_approval",
          description: "Approve deployment",
          prompt: "Approve deployment to production?",
          allowed_responses: [:approved, :rejected]
        },
        execute: NoopAction
      },
      transitions: %{
        {:process, :ok} => :approval,
        {:approval, :approved} => :execute,
        {:approval, :rejected} => :failed,
        {:approval, :timeout} => :failed,
        {:execute, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :process
  end

  defmodule TimeoutWorkflow do
    use Jido.Composer.Workflow,
      name: "timeout_workflow",
      description: "Workflow with HITL timeout transition",
      nodes: %{
        check: NoopAction,
        approval: %HumanNode{
          name: "timeout_approval",
          description: "Approve with timeout",
          prompt: "Approve?",
          allowed_responses: [:approved, :rejected],
          timeout: 30_000,
          timeout_outcome: :timeout
        },
        fallback: NoopAction
      },
      transitions: %{
        {:check, :ok} => :approval,
        {:approval, :approved} => :done,
        {:approval, :rejected} => :failed,
        {:approval, :timeout} => :fallback,
        {:fallback, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :check
  end

  # -- Helpers --

  defp execute_workflow(agent_module, agent, directives) do
    run_directive_loop(agent_module, agent, directives)
  end

  defp run_directive_loop(_agent_module, agent, []), do: {agent, []}

  defp run_directive_loop(agent_module, agent, [directive | rest]) do
    case directive do
      %Directive.RunInstruction{instruction: instr, result_action: result_action} ->
        payload = execute_instruction(instr)
        {agent, new_directives} = agent_module.cmd(agent, {result_action, payload})
        run_directive_loop(agent_module, agent, new_directives ++ rest)

      %Suspend{} = suspend ->
        {agent, [suspend | rest]}

      _other ->
        run_directive_loop(agent_module, agent, rest)
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

      {:ok, result, outcome} ->
        %{
          status: :ok,
          result: result,
          outcome: outcome,
          instruction: %Jido.Instruction{action: action_module, params: params},
          effects: [],
          meta: %{}
        }

      {:error, reason} ->
        %{
          status: :error,
          result: %{error: reason},
          instruction: %Jido.Instruction{action: action_module, params: params},
          effects: [],
          meta: %{}
        }
    end
  end

  # -- Tests --

  describe "suspend/resume cycle" do
    test "workflow suspends at HumanNode and emits Suspend directive" do
      agent = ApprovalWorkflow.new()
      {agent, directives} = ApprovalWorkflow.run(agent, %{tag: "deploy-v1"})

      {agent, remaining} = execute_workflow(ApprovalWorkflow, agent, directives)

      assert [%Suspend{} = suspend | _] = remaining
      assert %{approval_request: %ApprovalRequest{} = request} = suspend.suspension
      assert request.prompt == "Approve deployment to production?"
      assert request.allowed_responses == [:approved, :rejected]
      assert request.node_name == "deploy_approval"
      assert request.workflow_state == :approval

      strat = StratState.get(agent)
      assert strat.status == :waiting
      assert strat.pending_suspension != nil
      assert strat.machine.status == :approval
    end

    test "workflow resumes on approved decision and completes" do
      agent = ApprovalWorkflow.new()
      {agent, directives} = ApprovalWorkflow.run(agent, %{tag: "deploy-v1"})
      {agent, _remaining} = execute_workflow(ApprovalWorkflow, agent, directives)

      strat = StratState.get(agent)

      {:ok, response} =
        ApprovalResponse.new(
          request_id: strat.pending_suspension.approval_request.id,
          decision: :approved,
          respondent: "admin@co.com",
          comment: "Ship it!"
        )

      suspension_id = strat.pending_suspension.id

      {agent, directives} =
        ApprovalWorkflow.cmd(
          agent,
          {:suspend_resume,
           %{suspension_id: suspension_id, response_data: Map.from_struct(response)}}
        )

      {agent, _} = execute_workflow(ApprovalWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert StratState.status(agent) == :success

      assert strat.machine.context.working[:hitl_response][:decision] == :approved
      assert strat.machine.context.working[:hitl_response][:respondent] == "admin@co.com"
    end

    test "workflow resumes on rejected decision and transitions to failed" do
      agent = ApprovalWorkflow.new()
      {agent, directives} = ApprovalWorkflow.run(agent, %{tag: "deploy-v1"})
      {agent, _remaining} = execute_workflow(ApprovalWorkflow, agent, directives)

      strat = StratState.get(agent)

      {:ok, response} =
        ApprovalResponse.new(
          request_id: strat.pending_suspension.approval_request.id,
          decision: :rejected,
          respondent: "reviewer@co.com",
          comment: "Too risky"
        )

      suspension_id = strat.pending_suspension.id

      {agent, _directives} =
        ApprovalWorkflow.cmd(
          agent,
          {:suspend_resume,
           %{suspension_id: suspension_id, response_data: Map.from_struct(response)}}
        )

      strat = StratState.get(agent)
      assert strat.machine.status == :failed
      assert StratState.status(agent) == :failure
    end

    test "rejects response with mismatched request_id" do
      agent = ApprovalWorkflow.new()
      {agent, directives} = ApprovalWorkflow.run(agent, %{tag: "deploy-v1"})
      {agent, _remaining} = execute_workflow(ApprovalWorkflow, agent, directives)

      {:ok, response} =
        ApprovalResponse.new(
          request_id: "wrong-id",
          decision: :approved
        )

      strat = StratState.get(agent)
      suspension_id = strat.pending_suspension.id

      {agent, directives} =
        ApprovalWorkflow.cmd(
          agent,
          {:suspend_resume,
           %{suspension_id: suspension_id, response_data: Map.from_struct(response)}}
        )

      assert [%Directive.Error{}] = directives

      strat = StratState.get(agent)
      assert strat.status == :waiting
    end

    test "rejects response with invalid decision" do
      agent = ApprovalWorkflow.new()
      {agent, directives} = ApprovalWorkflow.run(agent, %{tag: "deploy-v1"})
      {agent, _remaining} = execute_workflow(ApprovalWorkflow, agent, directives)

      strat = StratState.get(agent)

      {:ok, response} =
        ApprovalResponse.new(
          request_id: strat.pending_suspension.approval_request.id,
          decision: :maybe
        )

      suspension_id = strat.pending_suspension.id

      {agent, directives} =
        ApprovalWorkflow.cmd(
          agent,
          {:suspend_resume,
           %{suspension_id: suspension_id, response_data: Map.from_struct(response)}}
        )

      assert [%Directive.Error{}] = directives
      strat = StratState.get(agent)
      assert strat.status == :waiting
    end

    test "context from process step is available in ApprovalRequest" do
      agent = ApprovalWorkflow.new()
      {agent, directives} = ApprovalWorkflow.run(agent, %{tag: "deploy-v1"})
      {_agent, remaining} = execute_workflow(ApprovalWorkflow, agent, directives)

      [%Suspend{suspension: suspension} | _] = remaining

      assert suspension.approval_request.visible_context[:tag] == "deploy-v1"
    end
  end

  describe "snapshot during HITL pause" do
    test "snapshot includes HITL-specific details when waiting for approval" do
      agent = ApprovalWorkflow.new()
      {agent, directives} = ApprovalWorkflow.run(agent, %{tag: "deploy-v1"})
      {agent, _remaining} = execute_workflow(ApprovalWorkflow, agent, directives)

      ctx = %{agent_module: ApprovalWorkflow, strategy_opts: ApprovalWorkflow.strategy_opts()}
      snap = Jido.Composer.Workflow.Strategy.snapshot(agent, ctx)

      assert snap.status == :waiting
      refute snap.done?
      assert snap.details.reason == :awaiting_approval
      assert is_binary(snap.details.request_id)
      assert snap.details.node_name == "deploy_approval"
    end
  end

  describe "timeout outcome transition" do
    test "timeout transitions to fallback state" do
      agent = TimeoutWorkflow.new()
      {agent, directives} = TimeoutWorkflow.run(agent, %{})
      {agent, _remaining} = execute_workflow(TimeoutWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.status == :waiting

      suspension_id = strat.pending_suspension.id

      {agent, directives} =
        TimeoutWorkflow.cmd(
          agent,
          {:suspend_timeout, %{suspension_id: suspension_id}}
        )

      {agent, _} = execute_workflow(TimeoutWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert StratState.status(agent) == :success
    end

    test "timeout is ignored if already resolved" do
      agent = TimeoutWorkflow.new()
      {agent, directives} = TimeoutWorkflow.run(agent, %{})
      {agent, _remaining} = execute_workflow(TimeoutWorkflow, agent, directives)

      strat = StratState.get(agent)
      suspension_id = strat.pending_suspension.id

      {:ok, response} =
        ApprovalResponse.new(
          request_id: strat.pending_suspension.approval_request.id,
          decision: :approved
        )

      {agent, directives} =
        TimeoutWorkflow.cmd(
          agent,
          {:suspend_resume,
           %{suspension_id: suspension_id, response_data: Map.from_struct(response)}}
        )

      {agent, _} = execute_workflow(TimeoutWorkflow, agent, directives)

      {agent, directives} =
        TimeoutWorkflow.cmd(agent, {:suspend_timeout, %{suspension_id: suspension_id}})

      assert directives == []
      strat = StratState.get(agent)
      assert strat.machine.status == :done
    end
  end

  # -- Generalized suspension workflows --

  defmodule RateLimitWorkflow do
    use Jido.Composer.Workflow,
      name: "rate_limit_workflow",
      description: "Workflow with rate-limited step that suspends",
      nodes: %{
        prepare: AccumulatorAction,
        api_call: RateLimitAction,
        finish: NoopAction
      },
      transitions: %{
        {:prepare, :ok} => :api_call,
        {:api_call, :ok} => :finish,
        {:api_call, :timeout} => :failed,
        {:finish, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :prepare
  end

  describe "generalized suspension with rate_limit reason" do
    test "rate-limited node suspends workflow with Suspension struct" do
      agent = RateLimitWorkflow.new()
      {agent, directives} = RateLimitWorkflow.run(agent, %{tag: "api-v1", tokens: 0})
      {agent, remaining} = execute_workflow(RateLimitWorkflow, agent, directives)

      assert [%Suspend{} = suspend | _] = remaining
      assert %Suspension{reason: :rate_limit} = suspend.suspension
      assert suspend.suspension.metadata == %{retry_after_ms: 5000}

      strat = StratState.get(agent)
      assert strat.status == :waiting
      assert strat.pending_suspension.reason == :rate_limit
    end

    test "resume after rate-limit suspension continues workflow" do
      agent = RateLimitWorkflow.new()
      {agent, directives} = RateLimitWorkflow.run(agent, %{tag: "api-v1", tokens: 0})
      {agent, _remaining} = execute_workflow(RateLimitWorkflow, agent, directives)

      strat = StratState.get(agent)
      suspension_id = strat.pending_suspension.id

      # Resume with outcome :ok
      {agent, directives} =
        RateLimitWorkflow.cmd(
          agent,
          {:suspend_resume,
           %{suspension_id: suspension_id, outcome: :ok, data: %{processed: true}}}
        )

      {agent, _} = execute_workflow(RateLimitWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert StratState.status(agent) == :success
    end

    test "suspension timeout fires timeout_outcome transition" do
      agent = RateLimitWorkflow.new()
      {agent, directives} = RateLimitWorkflow.run(agent, %{tag: "api-v1", tokens: 0})
      {agent, _remaining} = execute_workflow(RateLimitWorkflow, agent, directives)

      strat = StratState.get(agent)
      suspension_id = strat.pending_suspension.id

      {agent, _directives} =
        RateLimitWorkflow.cmd(agent, {:suspend_timeout, %{suspension_id: suspension_id}})

      strat = StratState.get(agent)
      assert strat.machine.status == :failed
      assert StratState.status(agent) == :failure
    end

    test "resume with mismatched suspension_id errors" do
      agent = RateLimitWorkflow.new()
      {agent, directives} = RateLimitWorkflow.run(agent, %{tag: "api-v1", tokens: 0})
      {agent, _remaining} = execute_workflow(RateLimitWorkflow, agent, directives)

      {agent, directives} =
        RateLimitWorkflow.cmd(
          agent,
          {:suspend_resume, %{suspension_id: "wrong-id", outcome: :ok}}
        )

      assert [%Directive.Error{}] = directives
      strat = StratState.get(agent)
      assert strat.status == :waiting
    end
  end
end
