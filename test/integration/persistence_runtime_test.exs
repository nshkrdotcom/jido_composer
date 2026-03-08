defmodule Jido.Composer.Integration.PersistenceRuntimeTest do
  @moduledoc """
  End-to-end tests that exercise persistence (checkpoint/thaw/resume) through
  real AgentServer processes, validating the full runtime path that strategy-
  level tests cannot cover.

  Uses ReqCassette for recorded API responses. To re-record:
    RECORD_CASSETTES=true mix test test/integration/persistence_runtime_test.exs
  """
  use ExUnit.Case, async: false

  import ReqCassette

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.CassetteHelper

  alias Jido.Composer.TestActions.{
    EchoAction,
    RateLimitAction,
    TimedSuspendAction
  }

  # ── Test Agents ─────────────────────────────────────────────

  defmodule RuntimeTestOrchestrator do
    @moduledoc false
    use Jido.Composer.Orchestrator,
      name: "runtime_test_orch",
      description: "Orchestrator for runtime persistence tests",
      model: "anthropic:claude-sonnet-4-20250514",
      nodes: [EchoAction],
      system_prompt:
        "You are a test assistant. When asked to echo something, use the echo tool with the exact message requested. Do not add any commentary."
  end

  defmodule GatedRuntimeOrchestrator do
    @moduledoc false
    use Jido.Composer.Orchestrator,
      name: "gated_runtime_orch",
      description: "Orchestrator with gated echo node",
      model: "anthropic:claude-sonnet-4-20250514",
      nodes: [{EchoAction, requires_approval: true}],
      system_prompt:
        "You are a test assistant. When asked to echo something, use the echo tool with the exact message requested."
  end

  defmodule SuspendableOrchestrator do
    @moduledoc false
    use Jido.Composer.Orchestrator,
      name: "suspendable_orch",
      description: "Orchestrator with suspendable rate_limit node",
      model: "anthropic:claude-sonnet-4-20250514",
      nodes: [RateLimitAction, EchoAction],
      system_prompt:
        "You are a test assistant. When asked to check rate limits, call rate_limit_action with the tokens value specified. When asked to echo, use the echo tool."
  end

  defmodule TimedSuspendOrchestrator do
    @moduledoc false
    use Jido.Composer.Orchestrator,
      name: "timed_suspend_orch",
      description: "Orchestrator with finite-timeout suspend for CheckpointAndStop tests",
      model: "anthropic:claude-sonnet-4-20250514",
      nodes: [TimedSuspendAction, EchoAction],
      system_prompt:
        "You are a test assistant. When asked to suspend with a timeout, call timed_suspend_action with the timeout_ms value specified."
  end

  defmodule ParentRecorderStrategy do
    @moduledoc "Simple strategy that records received signals in strategy state."
    use Jido.Agent.Strategy

    alias Jido.Agent.Strategy.State, as: StratState

    @impl true
    def init(agent, _ctx) do
      agent =
        StratState.put(agent, %{
          module: __MODULE__,
          status: :idle,
          received_signals: []
        })

      {agent, []}
    end

    @impl true
    def cmd(agent, [%Jido.Instruction{action: action} = instr | _], _ctx) do
      agent =
        StratState.update(agent, fn s ->
          %{s | received_signals: s.received_signals ++ [{action, instr.params}]}
        end)

      {agent, []}
    end

    @impl true
    def signal_routes(_ctx) do
      [
        {"composer.child.hibernated", {:strategy_cmd, :child_hibernated}},
        {"jido.agent.child.started", {:strategy_cmd, :child_started}},
        {"jido.agent.child.exit", {:strategy_cmd, :child_exit}}
      ]
    end

    @impl true
    def snapshot(agent, _ctx) do
      strat = StratState.get(agent, %{})

      %Jido.Agent.Strategy.Snapshot{
        status: Map.get(strat, :status, :idle),
        done?: false,
        result: nil,
        details: %{received: length(Map.get(strat, :received_signals, []))}
      }
    end
  end

  defmodule ParentTestAgent do
    @moduledoc false
    use Jido.Agent,
      name: "parent_test_agent",
      description: "Parent agent that records child signals",
      schema: [],
      strategy: {ParentRecorderStrategy, []},
      signal_routes: [
        {"composer.child.hibernated", {:strategy_cmd, :child_hibernated}},
        {"jido.agent.child.started", {:strategy_cmd, :child_started}},
        {"jido.agent.child.exit", {:strategy_cmd, :child_exit}}
      ]
  end

  # ── Infrastructure ──────────────────────────────────────────

  setup_all do
    start_if_not_running(Registry, keys: :unique, name: Jido.Registry)
    start_if_not_running(DynamicSupervisor, name: Jido.AgentSupervisor, strategy: :one_for_one)
    start_if_not_running(Task.Supervisor, name: Jido.TaskSupervisor)
    :ok
  end

  setup context do
    Req.Test.set_req_test_to_shared(context)

    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    table = :"test_storage_#{System.unique_integer([:positive])}"
    storage = {Jido.Storage.ETS, table: table}

    # Pre-create ETS tables so they survive process death (owned by test process).
    # Without this, tables created by AgentServer would be deleted when it stops.
    for suffix <- [:checkpoints, :threads, :thread_meta] do
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      tab_name = :"#{table}_#{suffix}"
      type = if suffix == :threads, do: :ordered_set, else: :set
      :ets.new(tab_name, [:named_table, :public, {:read_concurrency, true}, type])
    end

    %{storage: storage, table: table}
  end

  # ── Helpers ─────────────────────────────────────────────────

  defp start_if_not_running(module, opts) do
    name = Keyword.get(opts, :name)

    case Process.whereis(name) do
      nil -> {:ok, _} = apply(module, :start_link, [opts])
      _pid -> :already_running
    end
  end

  defp cassette_opts do
    CassetteHelper.default_cassette_opts() |> Keyword.put(:shared, true)
  end

  defp build_signal(type, data) do
    Jido.Signal.new!(type, data, source: "/test")
  end

  defp get_strat(pid) do
    {:ok, state} = Jido.AgentServer.state(pid)
    StratState.get(state.agent)
  end

  defp await_status(pid, target_status, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    poll_fn = fn poll_fn ->
      strat = get_strat(pid)

      if strat.status == target_status do
        strat
      else
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          flunk(
            "Timed out waiting for status #{inspect(target_status)}, " <>
              "current: #{inspect(strat.status)}"
          )
        else
          Process.sleep(50)
          poll_fn.(poll_fn)
        end
      end
    end

    poll_fn.(poll_fn)
  end

  defp start_orchestrator(module, plug) do
    agent = module.new()

    {:ok, pid} =
      Jido.AgentServer.start_link(
        agent: agent,
        agent_module: module,
        register_global: false
      )

    inject_req_options(pid, plug)
    {pid, agent}
  end

  defp inject_req_options(pid, plug) do
    :sys.replace_state(pid, fn gs_state ->
      agent = gs_state.agent
      strat = StratState.get(agent, %{})
      updated_strat = Map.put(strat, :req_options, plug: plug)
      updated_agent = StratState.put(agent, updated_strat)
      %{gs_state | agent: updated_agent}
    end)
  end

  defp inject_hibernate_after(pid, value) do
    :sys.replace_state(pid, fn gs_state ->
      agent = gs_state.agent
      strat = StratState.get(agent, %{})
      updated_strat = Map.put(strat, :hibernate_after, value)
      updated_agent = StratState.put(agent, updated_strat)
      %{gs_state | agent: updated_agent}
    end)
  end

  defp inject_storage(pid, storage) do
    :sys.replace_state(pid, fn gs_state ->
      lifecycle = Map.get(gs_state, :lifecycle, %{})
      updated_lifecycle = Map.put(lifecycle, :storage, storage)
      %{gs_state | lifecycle: updated_lifecycle}
    end)
  end

  # ══════════════════════════════════════════════════════════════
  # Scenario 1: Happy Path — Query to Completion (cassette)
  # ══════════════════════════════════════════════════════════════

  describe "happy path through AgentServer" do
    test "orchestrator processes query to completion via real runtime" do
      with_cassette("runtime_happy_path", cassette_opts(), fn plug ->
        {pid, _agent} = start_orchestrator(RuntimeTestOrchestrator, plug)

        signal =
          build_signal("composer.orchestrator.query", %{
            query: "Use the echo tool to echo 'hello'"
          })

        {:ok, _} = Jido.AgentServer.call(pid, signal, 10_000)

        strat = await_status(pid, :completed, 10_000)
        assert strat.result != nil
        assert strat.iteration >= 1

        GenServer.stop(pid)
      end)
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Scenario 2: Gated Tool -> Checkpoint -> Thaw -> Resume
  # ══════════════════════════════════════════════════════════════

  describe "gated tool checkpoint/thaw/resume lifecycle" do
    test "full hibernate/thaw/resume through real process boundaries", %{storage: storage} do
      with_cassette("runtime_gated_checkpoint_resume", cassette_opts(), fn plug ->
        # Phase 1: LLM calls the gated echo tool
        {pid, agent} = start_orchestrator(GatedRuntimeOrchestrator, plug)

        signal = build_signal("composer.orchestrator.query", %{query: "Echo 'gated test'"})
        {:ok, _} = Jido.AgentServer.call(pid, signal, 10_000)

        strat = await_status(pid, :awaiting_approval)
        assert map_size(strat.approval_gate.gated_calls) == 1

        # Hibernate to storage
        {:ok, live_state} = Jido.AgentServer.state(pid)
        :ok = Jido.Persist.hibernate(storage, live_state.agent)
        GenServer.stop(pid)

        # Thaw from storage
        {:ok, restored_agent} =
          Jido.Persist.thaw(storage, GatedRuntimeOrchestrator, agent.id)

        # Start new AgentServer with restored agent (Prerequisite 1)
        {:ok, pid2} =
          Jido.AgentServer.start_link(
            agent: restored_agent,
            agent_module: GatedRuntimeOrchestrator,
            register_global: false
          )

        # Phase 2: same cassette plug continues serving the next interaction
        inject_req_options(pid2, plug)

        # Verify restored state preserved by init
        restored_strat = get_strat(pid2)
        assert restored_strat.status == :awaiting_approval
        assert map_size(restored_strat.approval_gate.gated_calls) == 1

        # Send approval
        [{request_id, _}] = Map.to_list(restored_strat.approval_gate.gated_calls)

        approval_signal =
          build_signal("composer.suspend.resume", %{
            suspension_id: request_id,
            response_data: %{
              request_id: request_id,
              decision: :approved
            }
          })

        {:ok, _} = Jido.AgentServer.call(pid2, approval_signal, 10_000)

        strat = await_status(pid2, :completed, 10_000)
        assert strat.result != nil

        GenServer.stop(pid2)
      end)
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Scenario 3a: Tool Suspension -> Manual Hibernate -> Thaw -> Resume
  # Validates Prerequisite 2 (effects-based suspend detection) and
  # the full thaw/resume cycle through real process boundaries.
  # ══════════════════════════════════════════════════════════════

  describe "tool suspension with manual checkpoint" do
    test "tool suspend via effects detection, manual hibernate, thaw and resume", %{
      storage: storage
    } do
      with_cassette("runtime_tool_suspension_resume", cassette_opts(), fn plug ->
        # Phase 1: LLM calls rate_limit_action with tokens=0 -> {:ok, result, :suspend}
        {pid, agent} = start_orchestrator(SuspendableOrchestrator, plug)

        signal =
          build_signal("composer.orchestrator.query", %{
            query:
              "Check rate limits with 0 tokens remaining. Call rate_limit_action with tokens set to 0."
          })

        {:ok, _} = Jido.AgentServer.call(pid, signal, 10_000)

        # Verify tool suspension was detected via effects (Prerequisite 2)
        strat = await_status(pid, :awaiting_suspension)
        assert map_size(strat.suspended_calls) == 1

        # Manual hibernate/stop (RateLimitAction produces timeout: :infinity,
        # so CheckpointAndStop auto-trigger doesn't fire)
        {:ok, live_state} = Jido.AgentServer.state(pid)
        :ok = Jido.Persist.hibernate(storage, live_state.agent)
        GenServer.stop(pid)

        # Thaw from storage
        {:ok, restored_agent} =
          Jido.Persist.thaw(storage, SuspendableOrchestrator, agent.id)

        restored_strat = StratState.get(restored_agent)
        assert restored_strat.status == :awaiting_suspension
        assert map_size(restored_strat.suspended_calls) == 1

        # Phase 2: Start new AgentServer, same cassette plug for next interaction
        {:ok, pid2} =
          Jido.AgentServer.start_link(
            agent: restored_agent,
            agent_module: SuspendableOrchestrator,
            register_global: false
          )

        inject_req_options(pid2, plug)

        # Resume with data
        restored_strat2 = get_strat(pid2)
        [{suspension_id, _entry}] = Map.to_list(restored_strat2.suspended_calls)

        resume_signal =
          build_signal("composer.suspend.resume", %{
            suspension_id: suspension_id,
            outcome: :ok,
            data: %{tokens_refilled: true}
          })

        {:ok, _} = Jido.AgentServer.call(pid2, resume_signal, 10_000)

        strat = await_status(pid2, :completed, 10_000)
        assert strat.result != nil

        GenServer.stop(pid2)
      end)
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Scenario 3b: Tool Suspension -> CheckpointAndStop Auto-Trigger
  # Validates that CheckpointAndStop fires automatically when
  # hibernate_after threshold is met and the Suspension has a
  # finite timeout. Uses TimedSuspendAction which embeds a
  # Suspension with timeout: 30_000ms in its result.
  # ══════════════════════════════════════════════════════════════

  describe "CheckpointAndStop auto-trigger via tool suspension" do
    test "tool with finite-timeout suspension triggers automatic CheckpointAndStop", %{
      storage: storage
    } do
      # Trap exits so CheckpointAndStop's {:shutdown, :hibernated} doesn't kill the test
      Process.flag(:trap_exit, true)

      with_cassette("runtime_checkpoint_and_stop_auto", cassette_opts(), fn plug ->
        {pid, agent} = start_orchestrator(TimedSuspendOrchestrator, plug)
        # hibernate_after: 1ms — Suspension timeout(30000) >= 1 triggers CheckpointAndStop
        inject_hibernate_after(pid, 1)
        inject_storage(pid, storage)

        ref = Process.monitor(pid)

        signal =
          build_signal("composer.orchestrator.query", %{
            query: "Call the timed_suspend_action tool with timeout_ms set to 30000."
          })

        {:ok, _} = Jido.AgentServer.call(pid, signal, 10_000)

        receive do
          {:DOWN, ^ref, :process, ^pid, {:shutdown, :hibernated}} ->
            :ok

          {:DOWN, ^ref, :process, ^pid, reason} ->
            flunk("Process stopped with unexpected reason: #{inspect(reason)}")
        after
          10_000 ->
            if Process.alive?(pid) do
              strat = get_strat(pid)

              flunk(
                "CheckpointAndStop did not fire. Status: #{inspect(strat.status)}, " <>
                  "suspended_calls: #{map_size(strat.suspended_calls)}"
              )
            else
              flunk("Process died but not with :hibernated reason")
            end
        end

        # Verify checkpoint exists in storage
        {:ok, restored_agent} =
          Jido.Persist.thaw(storage, TimedSuspendOrchestrator, agent.id)

        restored_strat = StratState.get(restored_agent)
        assert restored_strat.status == :awaiting_suspension
        assert map_size(restored_strat.suspended_calls) == 1
      end)
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Scenario 4: Parent-Child Notification via CheckpointAndStop
  # Validates that CheckpointAndStop's directive executor sends
  # "composer.child.hibernated" to the parent through real
  # GenServer casts (not manually constructed signals).
  # ══════════════════════════════════════════════════════════════

  describe "parent-child hibernation notification via CheckpointAndStop" do
    test "CheckpointAndStop notifies parent automatically", %{storage: storage} do
      # Trap exits so CheckpointAndStop's {:shutdown, :hibernated} doesn't kill the test
      Process.flag(:trap_exit, true)

      with_cassette("runtime_parent_child_notification", cassette_opts(), fn plug ->
        {:ok, parent_pid} =
          Jido.AgentServer.start_link(agent: ParentTestAgent, register_global: false)

        {:ok, parent_state} = Jido.AgentServer.state(parent_pid)
        parent_id = parent_state.id

        child_agent = TimedSuspendOrchestrator.new()

        {:ok, child_pid} =
          Jido.AgentServer.start_link(
            agent: child_agent,
            agent_module: TimedSuspendOrchestrator,
            register_global: false,
            parent: %{pid: parent_pid, id: parent_id, tag: :orch_child, meta: %{}}
          )

        inject_req_options(child_pid, plug)
        # Enable auto-checkpoint: Suspension timeout(30000) >= hibernate_after(1)
        inject_hibernate_after(child_pid, 1)
        inject_storage(child_pid, storage)

        child_ref = Process.monitor(child_pid)

        signal =
          build_signal("composer.orchestrator.query", %{
            query: "Call the timed_suspend_action tool with timeout_ms set to 30000."
          })

        {:ok, _} = Jido.AgentServer.call(child_pid, signal, 10_000)

        receive do
          {:DOWN, ^child_ref, :process, ^child_pid, {:shutdown, :hibernated}} ->
            :ok

          {:DOWN, ^child_ref, :process, ^child_pid, reason} ->
            flunk("Child stopped with unexpected reason: #{inspect(reason)}")
        after
          10_000 ->
            if Process.alive?(child_pid) do
              strat = get_strat(child_pid)

              flunk("CheckpointAndStop did not fire on child. Status: #{inspect(strat.status)}")
            else
              flunk("Child died but not with :hibernated reason")
            end
        end

        # Give the parent time to process the cast
        Process.sleep(200)

        parent_strat = get_strat(parent_pid)

        child_hibernated_signals =
          Enum.filter(parent_strat.received_signals, fn {action, _params} ->
            action == :child_hibernated
          end)

        assert length(child_hibernated_signals) == 1
        [{:child_hibernated, params}] = child_hibernated_signals
        assert params.tag == :orch_child
        assert params.checkpoint_key == {TimedSuspendOrchestrator, child_agent.id}

        GenServer.stop(parent_pid)
      end)
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Scenario 5: Strategy Init Preserves Restored State
  # ══════════════════════════════════════════════════════════════

  describe "strategy init preserves restored state" do
    test "starting AgentServer with thawed agent does not obliterate checkpoint state", %{
      storage: storage
    } do
      with_cassette("runtime_init_preserves_state", cassette_opts(), fn plug ->
        {pid, agent} = start_orchestrator(GatedRuntimeOrchestrator, plug)

        signal =
          build_signal("composer.orchestrator.query", %{
            query: "Echo 'checkpoint init test'"
          })

        {:ok, _} = Jido.AgentServer.call(pid, signal, 10_000)

        strat = await_status(pid, :awaiting_approval)
        original_iteration = strat.iteration
        original_query = strat.query

        {:ok, live_state} = Jido.AgentServer.state(pid)
        :ok = Jido.Persist.hibernate(storage, live_state.agent)
        GenServer.stop(pid)

        {:ok, restored_agent} =
          Jido.Persist.thaw(storage, GatedRuntimeOrchestrator, agent.id)

        {:ok, pid2} =
          Jido.AgentServer.start_link(
            agent: restored_agent,
            agent_module: GatedRuntimeOrchestrator,
            register_global: false
          )

        # Verify state was NOT obliterated by strategy init
        restored_strat = get_strat(pid2)
        assert restored_strat.status == :awaiting_approval
        assert restored_strat.iteration == original_iteration
        assert restored_strat.query == original_query
        assert map_size(restored_strat.approval_gate.gated_calls) == 1
        assert restored_strat.conversation != nil

        # Verify runtime fields were rebuilt
        assert map_size(restored_strat.nodes) > 0
        assert restored_strat.tools != []
        assert map_size(restored_strat.name_atoms) > 0

        GenServer.stop(pid2)
      end)
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Scenario 6: Resume.resume/4 Through AgentServer
  # Tests the Resume module's full integration path — thaw from
  # storage, start a new AgentServer, deliver resume signal via
  # AgentServer.call, and drive to completion.
  # ══════════════════════════════════════════════════════════════

  describe "Resume.resume/4 integration with AgentServer" do
    test "Resume.resume delivers signal to live AgentServer and completes", %{
      storage: storage
    } do
      alias Jido.Composer.Resume

      with_cassette("runtime_resume_integration", cassette_opts(), fn plug ->
        # Phase 1: Drive to awaiting_suspension via tool suspend
        {pid, agent} = start_orchestrator(SuspendableOrchestrator, plug)

        signal =
          build_signal("composer.orchestrator.query", %{
            query:
              "Check rate limits with 0 tokens remaining. Call rate_limit_action with tokens set to 0."
          })

        {:ok, _} = Jido.AgentServer.call(pid, signal, 10_000)

        strat = await_status(pid, :awaiting_suspension)
        assert map_size(strat.suspended_calls) == 1

        # Checkpoint to storage and stop
        {:ok, live_state} = Jido.AgentServer.state(pid)
        :ok = Jido.Persist.hibernate(storage, live_state.agent)
        GenServer.stop(pid)

        # Thaw from storage
        {:ok, restored_agent} =
          Jido.Persist.thaw(storage, SuspendableOrchestrator, agent.id)

        # Phase 2: Start new AgentServer with restored agent
        {:ok, pid2} =
          Jido.AgentServer.start_link(
            agent: restored_agent,
            agent_module: SuspendableOrchestrator,
            register_global: false
          )

        inject_req_options(pid2, plug)

        # Get the suspension_id from restored state
        restored_strat = get_strat(pid2)
        [{suspension_id, _entry}] = Map.to_list(restored_strat.suspended_calls)

        # Build deliver_fn that sends signals via AgentServer.call
        deliver_fn = fn agent_to_resume, {_action, resume_data} ->
          resume_signal =
            build_signal("composer.suspend.resume", resume_data)

          {:ok, _} = Jido.AgentServer.call(pid2, resume_signal, 10_000)
          # Return the agent and empty directives — AgentServer handles execution
          {agent_to_resume, []}
        end

        # Call Resume.resume/4
        {:ok, _resumed_agent, _directives} =
          Resume.resume(
            restored_agent,
            suspension_id,
            %{outcome: :ok, data: %{tokens_refilled: true}},
            deliver_fn: deliver_fn
          )

        # The AgentServer should now drive to completion
        strat = await_status(pid2, :completed, 10_000)
        assert strat.result != nil

        GenServer.stop(pid2)
      end)
    end
  end
end
