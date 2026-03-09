defmodule Jido.Composer.Integration.ObservabilityIntegrationTest do
  @moduledoc """
  Integration tests verifying OTel span hierarchy through the full runtime path,
  including nested agent spawning via AgentNode.
  """
  use ExUnit.Case, async: false

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.OtelTestHelper, as: OTH
  alias Jido.Composer.TestSupport.LLMStub

  @moduletag :capture_log

  # -- Agent Definitions --

  # Simple 1-step workflow agent used as a tool inside the orchestrator
  defmodule NestedWorkflowAgent do
    use Jido.Composer.Workflow,
      name: "nested_workflow",
      description: "Simple workflow used as a nested agent tool",
      nodes: %{
        step1: {:action, Jido.Composer.TestActions.EchoAction}
      },
      transitions: %{
        {:step1, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :step1
  end

  # Orchestrator that has both an action tool and an agent tool
  defmodule ObsOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "obs_orchestrator",
      description: "Orchestrator for observability integration tests",
      model: "stub:test-model",
      nodes: [
        Jido.Composer.TestActions.AddAction,
        {NestedWorkflowAgent, []}
      ],
      system_prompt: "You have math and nested workflow tools."
  end

  # -- Setup --

  setup do
    handler_state = OTH.setup_otel_capture(self())
    on_exit(fn -> OTH.teardown_otel(handler_state) end)
    :ok
  end

  # -- Directive loop helpers --

  defp execute_orchestrator(agent_module, agent, directives) do
    run_directive_loop(agent_module, agent, directives)
  end

  defp run_directive_loop(_agent_module, agent, []), do: agent

  defp run_directive_loop(agent_module, agent, [directive | rest]) do
    case directive do
      %Directive.RunInstruction{instruction: instr, result_action: result_action, meta: meta} ->
        payload = execute_instruction(instr, meta)
        {agent, new_directives} = agent_module.cmd(agent, {result_action, payload})
        run_directive_loop(agent_module, agent, new_directives ++ rest)

      %Directive.SpawnAgent{agent: child_agent_module, tag: tag, opts: spawn_opts, meta: meta} ->
        # Simulate the SpawnAgent lifecycle in-process:
        # 1. Notify parent that child started
        {agent, _started_directives} =
          agent_module.cmd(agent, {:orchestrator_child_started, %{tag: tag, child_pid: self()}})

        # 2. Save/restore OTel context from directive meta — mirrors the DSL fix (Gap 7)
        saved_ctx =
          if Code.ensure_loaded?(OpenTelemetry.Ctx), do: OpenTelemetry.Ctx.get_current()

        if otel_ctx = (meta || %{})[:otel_parent_ctx] do
          if Code.ensure_loaded?(OpenTelemetry.Ctx), do: OpenTelemetry.Ctx.attach(otel_ctx)
        end

        child_result = run_child_agent(child_agent_module, spawn_opts)
        if saved_ctx, do: OpenTelemetry.Ctx.attach(saved_ctx)

        # 3. Feed child result back to parent
        {agent, result_directives} =
          agent_module.cmd(agent, {:orchestrator_child_result, %{tag: tag, result: child_result}})

        run_directive_loop(agent_module, agent, result_directives ++ rest)

      _other ->
        run_directive_loop(agent_module, agent, rest)
    end
  end

  defp execute_instruction(
         %Jido.Instruction{action: Jido.Composer.Orchestrator.LLMAction} = instr,
         _meta
       ) do
    case LLMStub.execute(instr.params) do
      {:ok, %{response: response, conversation: conversation}} ->
        %{status: :ok, result: %{response: response, conversation: conversation}, meta: %{}}

      {:error, reason} ->
        %{status: :error, result: %{error: reason}, meta: %{}}
    end
  end

  defp execute_instruction(%Jido.Instruction{action: action_module, params: params}, meta) do
    case Jido.Exec.run(action_module, params) do
      {:ok, result} ->
        %{status: :ok, result: result, meta: meta || %{}}

      {:error, reason} ->
        %{status: :error, result: reason, meta: meta || %{}}
    end
  end

  # Runs a child workflow agent synchronously in the current process.
  # OTel context is already set by the caller (from directive.meta.otel_parent_ctx).
  defp run_child_agent(child_agent_module, spawn_opts) do
    context = Map.get(spawn_opts, :context, %{})
    child_agent = child_agent_module.new()

    case child_agent_module.run_sync(child_agent, context) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Tests --

  describe "orchestrator with action tool" do
    test "full round-trip: AGENT > CHAIN > {LLM, TOOL} hierarchy" do
      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}}

      LLMStub.setup([
        {:tool_calls, [tool_call]},
        {:final_answer, "5 + 3 = 8.0"}
      ])

      agent = ObsOrchestrator.new()
      {agent, directives} = ObsOrchestrator.query(agent, "What is 5 + 3?")
      agent = execute_orchestrator(ObsOrchestrator, agent, directives)

      strat = StratState.get(agent)
      assert strat.status == :completed
      assert strat.result.value == "5 + 3 = 8.0"

      spans = OTH.collect_spans()

      agent_span = OTH.find_span(spans, "obs_orchestrator")
      chain_span = OTH.find_span_containing(spans, "iteration")
      llm_span = OTH.find_span_containing(spans, "stub:test-model")
      tool_span = OTH.find_span(spans, "add")

      assert agent_span != nil,
             "Expected AGENT span, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      assert chain_span != nil, "Expected CHAIN span"
      assert llm_span != nil, "Expected LLM span"
      assert tool_span != nil, "Expected TOOL span for 'add'"

      # Verify hierarchy: AGENT > CHAIN > {LLM, TOOL}
      OTH.assert_parent_child(agent_span, chain_span)
      OTH.assert_parent_child(chain_span, tool_span)
      OTH.assert_same_trace([agent_span, chain_span, llm_span, tool_span])
    end
  end

  describe "orchestrator with nested agent tool (Gap 7)" do
    test "nested workflow agent span parents under orchestrator TOOL span" do
      # LLM calls the nested_workflow agent tool
      agent_call = %{
        id: "call_agent",
        name: "nested_workflow",
        arguments: %{"message" => "hello from orchestrator"}
      }

      LLMStub.setup([
        {:tool_calls, [agent_call]},
        {:final_answer, "The nested workflow echoed the message."}
      ])

      agent = ObsOrchestrator.new()
      {agent, directives} = ObsOrchestrator.query(agent, "Run the nested workflow")
      agent = execute_orchestrator(ObsOrchestrator, agent, directives)

      strat = StratState.get(agent)
      assert strat.status == :completed

      spans = OTH.collect_spans()

      orchestrator_agent_span = OTH.find_span(spans, "obs_orchestrator")
      chain_span = OTH.find_span_containing(spans, "iteration")

      assert orchestrator_agent_span != nil,
             "Expected orchestrator AGENT span, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      assert chain_span != nil, "Expected CHAIN span"

      # Find all spans named "nested_workflow" — there may be two:
      # 1. TOOL span from orchestrator (openinference.span.kind = TOOL)
      # 2. AGENT span from child workflow (openinference.span.kind = AGENT)
      nested_spans = OTH.find_spans(spans, "nested_workflow")

      assert nested_spans != [],
             "Expected nested_workflow span(s), got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      # Classify by span kind attribute
      {tool_spans, agent_spans} =
        Enum.split_with(nested_spans, fn s ->
          attrs = OTH.span_attributes(s)
          attrs["openinference.span.kind"] == "TOOL"
        end)

      # The orchestrator should create at least a TOOL span
      assert [tool_span | _] = tool_spans, "Expected TOOL span for nested_workflow"

      # Verify orchestrator hierarchy: AGENT > CHAIN > TOOL
      OTH.assert_parent_child(orchestrator_agent_span, chain_span)
      OTH.assert_parent_child(chain_span, tool_span)

      # Gap 7: The child workflow MUST create an AGENT span parented under
      # the orchestrator's TOOL span.
      assert [child_agent_span | _] = agent_spans,
             "Expected child AGENT span for nested_workflow, got none. " <>
               "All spans: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      OTH.assert_parent_child(tool_span, child_agent_span)
    end
  end
end
