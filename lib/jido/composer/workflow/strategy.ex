defmodule Jido.Composer.Workflow.Strategy do
  @moduledoc """
  Jido.Agent.Strategy implementation for deterministic FSM-based workflows.

  Drives a `Jido.Composer.Workflow.Machine` through its states by emitting
  directives. Keeps `cmd/3` pure — no side effects.
  """

  use Jido.Agent.Strategy

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Context
  alias Jido.Composer.Directive.FanOutBranch
  alias Jido.Composer.Directive.SuspendForHuman
  alias Jido.Composer.HITL.{ApprovalRequest, ApprovalResponse}
  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.Node.AgentNode
  alias Jido.Composer.Node.FanOutNode
  alias Jido.Composer.Node.HumanNode
  alias Jido.Composer.Workflow.Machine

  # -- init/2 --

  @impl true
  def init(agent, ctx) do
    opts = ctx.strategy_opts
    nodes = build_nodes(opts[:nodes])

    machine =
      Machine.new(
        nodes: nodes,
        transitions: opts[:transitions],
        initial: opts[:initial],
        terminal_states: opts[:terminal_states] || [:done, :failed]
      )

    agent =
      StratState.put(agent, %{
        module: __MODULE__,
        status: :idle,
        machine: machine,
        pending_child: nil,
        child_request_id: nil,
        pending_approval: nil,
        pending_fan_out: nil,
        ambient_keys: opts[:ambient] || [],
        fork_fns: opts[:fork_fns] || %{}
      })

    {agent, []}
  end

  # -- cmd/3 --

  @impl true
  def cmd(agent, [%Jido.Instruction{action: :workflow_start} = instr | _rest], _ctx) do
    agent = StratState.set_status(agent, :running)
    strat = StratState.get(agent)
    params = instr.params || %{}

    # Build Context from params: extract ambient keys, remaining go to working
    context = build_start_context(strat.machine.context, params, strat)
    machine = %{strat.machine | context: context}
    agent = put_machine(agent, machine)

    dispatch_current_node(agent)
  end

  def cmd(agent, [%Jido.Instruction{action: :workflow_node_result} = instr | _rest], _ctx) do
    strat = StratState.get(agent)
    params = instr.params

    case params do
      %{status: :ok, result: result} ->
        outcome = Map.get(params, :outcome, :ok)
        machine = Machine.apply_result(strat.machine, result)

        case Machine.transition(machine, outcome) do
          {:ok, machine} ->
            agent = put_machine(agent, machine)
            handle_after_transition(agent)

          {:error, _reason} ->
            agent = put_machine(agent, machine)
            agent = StratState.set_status(agent, :failure)
            {agent, []}
        end

      %{status: :error} ->
        machine = strat.machine

        case Machine.transition(machine, :error) do
          {:ok, machine} ->
            agent = put_machine(agent, machine)
            handle_after_transition(agent)

          {:error, _reason} ->
            agent = StratState.set_status(agent, :failure)
            {agent, []}
        end
    end
  end

  def cmd(agent, [%Jido.Instruction{action: :workflow_child_started} | _rest], _ctx) do
    # Child agent has started — no action needed for sync mode.
    # The SpawnAgent directive already contains the context; the AgentServer
    # handles delivery to the child.
    {agent, []}
  end

  def cmd(agent, [%Jido.Instruction{action: :workflow_child_result} = instr | _rest], _ctx) do
    strat = StratState.get(agent)
    params = instr.params

    case params do
      %{result: {:ok, result}} ->
        machine = Machine.apply_result(strat.machine, result)

        case Machine.transition(machine, :ok) do
          {:ok, machine} ->
            agent = put_machine(agent, machine)
            handle_after_transition(agent)

          {:error, _reason} ->
            agent = put_machine(agent, machine)
            agent = StratState.set_status(agent, :failure)
            {agent, []}
        end

      %{result: {:error, _reason}} ->
        case Machine.transition(strat.machine, :error) do
          {:ok, machine} ->
            agent = put_machine(agent, machine)
            handle_after_transition(agent)

          {:error, _reason} ->
            agent = StratState.set_status(agent, :failure)
            {agent, []}
        end
    end
  end

  def cmd(agent, [%Jido.Instruction{action: :workflow_child_exit} | _rest], _ctx) do
    # Child agent has exited — cleanup if needed
    {agent, []}
  end

  def cmd(agent, [%Jido.Instruction{action: :fan_out_branch_result} = instr | _rest], _ctx) do
    strat = StratState.get(agent)
    params = instr.params
    branch_name = params[:branch_name]
    result = params[:result]
    fan_out = strat.pending_fan_out

    # If fan_out was already cancelled (fail_fast), ignore late results
    if is_nil(fan_out) do
      {agent, []}
    else
      handle_fan_out_branch_result(agent, fan_out, branch_name, result, strat)
    end
  end

  def cmd(agent, [%Jido.Instruction{action: :hitl_response} = instr | _rest], _ctx) do
    strat = StratState.get(agent)

    case strat.pending_approval do
      nil ->
        {agent, [%Directive.Error{error: %RuntimeError{message: "No pending HITL request"}}]}

      %ApprovalRequest{} = request ->
        response_data = instr.params

        {:ok, response} =
          ApprovalResponse.new(
            request_id: response_data.request_id,
            decision: response_data.decision,
            data: Map.get(response_data, :data),
            respondent: Map.get(response_data, :respondent),
            comment: Map.get(response_data, :comment),
            responded_at: Map.get(response_data, :responded_at, DateTime.utc_now())
          )

        case ApprovalResponse.validate(response, request) do
          :ok ->
            handle_hitl_decision(agent, response)

          {:error, reason} ->
            {agent,
             [
               %Directive.Error{
                 error: %RuntimeError{message: "HITL validation failed: #{reason}"}
               }
             ]}
        end
    end
  end

  def cmd(agent, [%Jido.Instruction{action: :hitl_timeout} = instr | _rest], _ctx) do
    strat = StratState.get(agent)
    request_id = instr.params[:request_id]

    case strat.pending_approval do
      %ApprovalRequest{id: ^request_id} = request ->
        timeout_outcome = request.timeout_outcome

        agent =
          StratState.update(agent, fn s -> %{s | status: :running, pending_approval: nil} end)

        strat = StratState.get(agent)
        machine = strat.machine

        case Machine.transition(machine, timeout_outcome) do
          {:ok, machine} ->
            agent = put_machine(agent, machine)
            handle_after_transition(agent)

          {:error, _reason} ->
            agent = StratState.set_status(agent, :failure)
            {agent, []}
        end

      _ ->
        # Already resolved or mismatched — ignore
        {agent, []}
    end
  end

  def cmd(agent, _instructions, _ctx) do
    {agent, []}
  end

  # -- signal_routes/1 --

  @impl true
  def signal_routes(_ctx) do
    [
      {"composer.workflow.start", {:strategy_cmd, :workflow_start}},
      {"composer.workflow.child.result", {:strategy_cmd, :workflow_child_result}},
      {"jido.agent.child.started", {:strategy_cmd, :workflow_child_started}},
      {"jido.agent.child.exit", {:strategy_cmd, :workflow_child_exit}},
      {"composer.fan_out.branch_result", {:strategy_cmd, :fan_out_branch_result}},
      {"composer.hitl.response", {:strategy_cmd, :hitl_response}},
      {"composer.hitl.timeout", {:strategy_cmd, :hitl_timeout}}
    ]
  end

  # -- snapshot/2 --

  @impl true
  def snapshot(agent, _ctx) do
    strat = StratState.get(agent, %{})
    status = Map.get(strat, :status, :idle)

    details = %{
      state: get_in(strat, [:machine, Access.key(:status)])
    }

    details =
      case Map.get(strat, :pending_approval) do
        %ApprovalRequest{} = request ->
          Map.merge(details, %{
            reason: :awaiting_approval,
            request_id: request.id,
            node_name: request.node_name
          })

        _ ->
          details
      end

    raw_context = get_in(strat, [:machine, Access.key(:context)])

    snapshot_result =
      case raw_context do
        %Context{} -> Context.to_flat_map(raw_context)
        other -> other
      end

    %Jido.Agent.Strategy.Snapshot{
      status: status,
      done?: status in [:success, :failure],
      result: snapshot_result,
      details: details
    }
  end

  # -- Private --

  defp handle_after_transition(agent) do
    strat = StratState.get(agent)

    if Machine.terminal?(strat.machine) do
      status = if strat.machine.status == :done, do: :success, else: :failure
      agent = StratState.set_status(agent, status)
      {agent, []}
    else
      dispatch_current_node(agent)
    end
  end

  defp dispatch_current_node(agent) do
    strat = StratState.get(agent)
    node = Machine.current_node(strat.machine)

    case node do
      %ActionNode{action_module: action_module} ->
        instruction = %Jido.Instruction{
          action: action_module,
          params: Context.to_flat_map(strat.machine.context)
        }

        directive = %Directive.RunInstruction{
          instruction: instruction,
          result_action: :workflow_node_result
        }

        {agent, [directive]}

      %AgentNode{agent_module: agent_module, opts: opts} ->
        child_context = Context.fork_for_child(strat.machine.context)
        child_flat = Context.to_flat_map(child_context)

        directive = %Directive.SpawnAgent{
          tag: strat.machine.status,
          agent: agent_module,
          opts: Map.new(opts) |> Map.put(:context, child_flat)
        }

        {agent, [directive]}

      %HumanNode{} = human_node ->
        flat_context = Context.to_flat_map(strat.machine.context)
        {:ok, updated_context, :suspend} = HumanNode.run(human_node, flat_context)

        # Extract and enrich the ApprovalRequest
        request = updated_context.__approval_request__

        request = %{
          request
          | agent_id: Map.get(strat, :agent_id),
            agent_module: Map.get(strat, :agent_module),
            workflow_state: strat.machine.status,
            node_name: HumanNode.name(human_node)
        }

        # Store pending approval, set status to :waiting
        agent =
          StratState.update(agent, fn s ->
            %{s | status: :waiting, pending_approval: request}
          end)

        {:ok, directive} = SuspendForHuman.new(approval_request: request)
        {agent, [directive]}

      %FanOutNode{} = fan_out_node ->
        dispatch_fan_out(agent, fan_out_node, strat)

      nil ->
        {agent, []}
    end
  end

  defp handle_hitl_decision(agent, %ApprovalResponse{} = response) do
    # Merge response data into machine context working layer
    strat = StratState.get(agent)

    hitl_data = %{
      hitl_response: %{
        decision: response.decision,
        data: response.data,
        respondent: response.respondent,
        comment: response.comment,
        responded_at: response.responded_at
      }
    }

    current_ctx = strat.machine.context
    merged_working = DeepMerge.deep_merge(current_ctx.working, hitl_data)
    machine = %{strat.machine | context: %{current_ctx | working: merged_working}}

    # Use decision as transition outcome
    case Machine.transition(machine, response.decision) do
      {:ok, machine} ->
        agent = put_machine(agent, machine)

        agent =
          StratState.update(agent, fn s ->
            %{s | status: :running, pending_approval: nil}
          end)

        handle_after_transition(agent)

      {:error, _reason} ->
        agent = put_machine(agent, machine)
        agent = StratState.set_status(agent, :failure)

        agent =
          StratState.update(agent, fn s -> %{s | pending_approval: nil} end)

        {agent, []}
    end
  end

  defp build_start_context(%Context{} = current_ctx, params, strat) do
    ambient_keys = Map.get(strat, :ambient_keys, [])
    fork_fns = Map.get(strat, :fork_fns, %{})

    if ambient_keys == [] and fork_fns == %{} do
      # No ambient/fork config — just merge params into working
      %{current_ctx | working: Map.merge(current_ctx.working, params)}
    else
      # Extract ambient keys from params
      {ambient_vals, working_vals} = Map.split(params, ambient_keys)
      ambient = Map.merge(current_ctx.ambient, ambient_vals)
      working = Map.merge(current_ctx.working, working_vals)

      %Context{
        ambient: ambient,
        working: working,
        fork_fns: Map.merge(current_ctx.fork_fns, fork_fns)
      }
    end
  end

  defp put_machine(agent, machine) do
    StratState.update(agent, fn strat -> %{strat | machine: machine} end)
  end

  # -- FanOut helpers --

  defp handle_fan_out_branch_result(agent, fan_out, branch_name, result, strat) do
    case result do
      {:ok, branch_result} ->
        completed = Map.put(fan_out.completed_results, branch_name, branch_result)

        pending =
          fan_out.pending_branches
          |> MapSet.delete(branch_name)

        fan_out = %{fan_out | completed_results: completed, pending_branches: pending}

        # Dispatch queued branches if slots are available
        {fan_out, new_directives} = dispatch_queued_branches(fan_out, strat)

        agent =
          StratState.update(agent, fn s -> %{s | pending_fan_out: fan_out} end)

        maybe_complete_fan_out(agent, new_directives)

      {:error, reason} ->
        case fan_out.on_error do
          :fail_fast ->
            cancel_and_fail(agent, fan_out, reason)

          :collect_partial ->
            completed = Map.put(fan_out.completed_results, branch_name, {:error, reason})

            pending =
              fan_out.pending_branches
              |> MapSet.delete(branch_name)

            fan_out = %{fan_out | completed_results: completed, pending_branches: pending}

            {fan_out, new_directives} = dispatch_queued_branches(fan_out, strat)

            agent =
              StratState.update(agent, fn s -> %{s | pending_fan_out: fan_out} end)

            maybe_complete_fan_out(agent, new_directives)
        end
    end
  end

  defp dispatch_fan_out(agent, %FanOutNode{} = fan_out_node, strat) do
    fan_out_id = generate_fan_out_id()
    flat_context = Context.to_flat_map(strat.machine.context)

    all_branches =
      Enum.map(fan_out_node.branches, fn {branch_name, branch_node} ->
        {branch_name,
         build_fan_out_directive(fan_out_id, branch_name, branch_node, flat_context, strat)}
      end)

    max_concurrency = fan_out_node.max_concurrency || length(all_branches)
    {to_dispatch, to_queue} = Enum.split(all_branches, max_concurrency)

    dispatched_names = Enum.map(to_dispatch, fn {name, _} -> name end) |> MapSet.new()

    fan_out_state = %{
      id: fan_out_id,
      node: fan_out_node,
      pending_branches: dispatched_names,
      completed_results: %{},
      queued_branches: to_queue,
      merge: fan_out_node.merge,
      on_error: fan_out_node.on_error
    }

    agent =
      StratState.update(agent, fn s -> %{s | pending_fan_out: fan_out_state} end)

    directives = Enum.map(to_dispatch, fn {_name, directive} -> directive end)
    {agent, directives}
  end

  defp build_fan_out_directive(fan_out_id, branch_name, branch_node, flat_context, strat) do
    case branch_node do
      %ActionNode{action_module: action_module} ->
        %FanOutBranch{
          fan_out_id: fan_out_id,
          branch_name: branch_name,
          instruction: %Jido.Instruction{
            action: action_module,
            params: flat_context
          },
          result_action: :fan_out_branch_result
        }

      %AgentNode{agent_module: agent_module, opts: opts} ->
        child_context = Context.fork_for_child(strat.machine.context)
        child_flat = Context.to_flat_map(child_context)

        %FanOutBranch{
          fan_out_id: fan_out_id,
          branch_name: branch_name,
          spawn_agent: %{
            agent: agent_module,
            opts: Map.new(opts) |> Map.put(:context, child_flat)
          },
          result_action: :fan_out_branch_result
        }

      fun when is_function(fun, 1) ->
        %FanOutBranch{
          fan_out_id: fan_out_id,
          branch_name: branch_name,
          instruction: {:function, fun, flat_context},
          result_action: :fan_out_branch_result
        }
    end
  end

  defp dispatch_queued_branches(fan_out, _strat) when fan_out.queued_branches == [],
    do: {fan_out, []}

  defp dispatch_queued_branches(fan_out, _strat) do
    max =
      (fan_out.node.max_concurrency || length(fan_out.node.branches)) -
        MapSet.size(fan_out.pending_branches)

    if max <= 0 do
      {fan_out, []}
    else
      {to_dispatch, remaining} = Enum.split(fan_out.queued_branches, max)
      new_pending_names = Enum.map(to_dispatch, fn {name, _} -> name end)
      pending = Enum.reduce(new_pending_names, fan_out.pending_branches, &MapSet.put(&2, &1))
      directives = Enum.map(to_dispatch, fn {_name, directive} -> directive end)
      fan_out = %{fan_out | pending_branches: pending, queued_branches: remaining}
      {fan_out, directives}
    end
  end

  defp maybe_complete_fan_out(agent, extra_directives) do
    strat = StratState.get(agent)
    fan_out = strat.pending_fan_out

    if MapSet.size(fan_out.pending_branches) == 0 and fan_out.queued_branches == [] do
      # All branches done — merge results and transition
      merged = FanOutNode.merge_results(fan_out.completed_results, fan_out.merge)
      machine = Machine.apply_result(strat.machine, merged)

      agent = StratState.update(agent, fn s -> %{s | pending_fan_out: nil} end)

      case Machine.transition(machine, :ok) do
        {:ok, machine} ->
          agent = put_machine(agent, machine)
          handle_after_transition(agent)

        {:error, _reason} ->
          agent = put_machine(agent, machine)
          agent = StratState.set_status(agent, :failure)
          {agent, []}
      end
    else
      {agent, extra_directives}
    end
  end

  defp cancel_and_fail(agent, fan_out, _reason) do
    # Emit StopChild directives for pending agent branches
    stop_directives =
      fan_out.pending_branches
      |> MapSet.to_list()
      |> Enum.map(fn branch_name ->
        Directive.stop_child({:fan_out, fan_out.id, branch_name})
      end)

    agent = StratState.update(agent, fn s -> %{s | pending_fan_out: nil} end)
    strat = StratState.get(agent)

    case Machine.transition(strat.machine, :error) do
      {:ok, machine} ->
        agent = put_machine(agent, machine)
        handle_after_transition_with_directives(agent, stop_directives)

      {:error, _reason} ->
        agent = StratState.set_status(agent, :failure)
        {agent, stop_directives}
    end
  end

  defp handle_after_transition_with_directives(agent, extra_directives) do
    strat = StratState.get(agent)

    if Machine.terminal?(strat.machine) do
      status = if strat.machine.status == :done, do: :success, else: :failure
      agent = StratState.set_status(agent, status)
      {agent, extra_directives}
    else
      {agent, node_directives} = dispatch_current_node(agent)
      {agent, extra_directives ++ node_directives}
    end
  end

  defp generate_fan_out_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp build_nodes(node_specs) when is_map(node_specs) do
    Map.new(node_specs, fn
      {state_name, {:action, action_module}} ->
        {:ok, node} = ActionNode.new(action_module)
        {state_name, node}

      {state_name, {:agent, agent_module, opts}} ->
        {:ok, node} = AgentNode.new(agent_module, opts: opts)
        {state_name, node}

      {state_name, %ActionNode{} = node} ->
        {state_name, node}

      {state_name, %AgentNode{} = node} ->
        {state_name, node}

      {state_name, node} when is_struct(node) ->
        {state_name, node}
    end)
  end
end
