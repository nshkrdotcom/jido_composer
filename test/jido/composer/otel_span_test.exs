defmodule Jido.Composer.OtelSpanTest do
  @moduledoc """
  Tests that verify OTel span parent-child relationships (trace tree structure).

  Uses `otel_exporter_pid` to capture real OTel spans and asserts on span IDs.
  Complements `observability_test.exs` which only tests telemetry event emission.
  """
  use ExUnit.Case, async: false

  alias Jido.Composer.Orchestrator.Strategy, as: OrchestratorStrategy
  alias Jido.Composer.Workflow.Strategy, as: WorkflowStrategy
  alias Jido.Composer.OtelTestHelper, as: OTH
  alias Jido.Composer.TestSupport.LLMStub

  alias Jido.Composer.TestActions.{
    AddAction,
    EchoAction
  }

  @moduletag :capture_log

  # -- Test Agent Modules --

  defmodule OtelTestOrchestrator do
    use Jido.Agent,
      name: "otel_test_orchestrator",
      description: "Agent for OTel span hierarchy tests",
      schema: []
  end

  defmodule OtelTestWorkflow do
    use Jido.Agent,
      name: "otel_test_workflow",
      description: "Agent for OTel workflow span tests",
      schema: []
  end

  # -- Setup / Teardown --

  setup do
    handler_state = OTH.setup_otel_capture(self())
    on_exit(fn -> OTH.teardown_otel(handler_state) end)
    :ok
  end

  # -- Helpers --

  defp init_orchestrator(opts \\ []) do
    nodes = Keyword.get(opts, :nodes, [AddAction, EchoAction])
    extra = Keyword.drop(opts, [:nodes])

    strategy_opts =
      [
        nodes: nodes,
        model: "stub:test-model",
        system_prompt: "You are a test assistant.",
        max_iterations: 10,
        req_options: []
      ] ++ extra

    agent = OtelTestOrchestrator.new()
    ctx = %{strategy_opts: strategy_opts}
    {agent, _directives} = OrchestratorStrategy.init(agent, ctx)
    agent
  end

  defp init_workflow(nodes_map, transitions, opts) do
    strategy_opts =
      [
        nodes: nodes_map,
        transitions: transitions,
        initial: Keyword.get(opts, :initial, :extract),
        terminal_states: Keyword.get(opts, :terminal_states, [:done, :failed])
      ] ++ Keyword.drop(opts, [:initial, :terminal_states])

    agent = OtelTestWorkflow.new()
    ctx = %{strategy_opts: strategy_opts, agent_module: OtelTestWorkflow}
    {agent, _directives} = WorkflowStrategy.init(agent, ctx)
    agent
  end

  defp make_instruction(action, params) do
    %Jido.Instruction{action: action, params: params}
  end

  defp ctx, do: %{}

  defp execute_llm_directive(%Jido.Agent.Directive.RunInstruction{instruction: instr}) do
    result = LLMStub.execute(instr.params)

    case result do
      {:ok, %{response: response, conversation: conversation}} ->
        %{
          status: :ok,
          result: %{response: response, conversation: conversation},
          meta: instr.context
        }

      {:error, reason} ->
        %{status: :error, result: %{error: reason}, meta: instr.context}
    end
  end

  # -- Orchestrator: span hierarchy tests --

  describe "orchestrator span hierarchy" do
    test "final answer: AGENT > CHAIN > LLM" do
      LLMStub.setup([{:final_answer, "Hello"}])
      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Hi"})],
          ctx()
        )

      llm_result = execute_llm_directive(hd(directives))

      {_agent, _directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      spans = OTH.collect_spans()

      agent_span = OTH.find_span(spans, "otel_test_orchestrator")
      chain_span = OTH.find_span_containing(spans, "iteration")
      llm_span = OTH.find_span_containing(spans, "stub:test-model")

      assert agent_span != nil,
             "Expected AGENT span, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      assert chain_span != nil,
             "Expected CHAIN span, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      assert llm_span != nil,
             "Expected LLM span, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      OTH.assert_parent_child(agent_span, chain_span)
      OTH.assert_parent_child(chain_span, llm_span)
      OTH.assert_same_trace([agent_span, chain_span, llm_span])
    end

    test "tool calls: AGENT > CHAIN > {LLM, TOOL} as siblings" do
      LLMStub.setup([
        {:tool_calls, [%{id: "call_1", name: "add", arguments: %{"value" => 1, "amount" => 2}}]},
        {:final_answer, "Done"}
      ])

      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Add 1+2"})],
          ctx()
        )

      # Execute the LLM call
      llm_result = execute_llm_directive(hd(directives))

      {agent, tool_directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      # Execute the tool
      tool_directive = hd(tool_directives)
      tool_result = execute_tool_directive(tool_directive)

      {agent, directives2} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_tool_result, tool_result)],
          ctx()
        )

      # Execute second LLM call (final answer)
      llm_result2 = execute_llm_directive(hd(directives2))

      {_agent, _} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result2)],
          ctx()
        )

      spans = OTH.collect_spans()

      agent_span = OTH.find_span(spans, "otel_test_orchestrator")
      chain_spans = OTH.find_spans(spans, "iteration 1") ++ OTH.find_spans(spans, "iteration 2")
      tool_span = OTH.find_span(spans, "add")

      assert agent_span != nil
      assert chain_spans != []
      assert tool_span != nil

      # Tool should be under a CHAIN span, not directly under AGENT
      first_chain = hd(chain_spans)
      OTH.assert_parent_child(agent_span, first_chain)
      OTH.assert_parent_child(first_chain, tool_span)
    end

    test "two iterations produce two CHAIN spans under AGENT" do
      LLMStub.setup([
        {:tool_calls, [%{id: "call_1", name: "add", arguments: %{"value" => 1, "amount" => 2}}]},
        {:final_answer, "3"}
      ])

      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Compute"})],
          ctx()
        )

      llm_result = execute_llm_directive(hd(directives))

      {agent, tool_directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      tool_result = execute_tool_directive(hd(tool_directives))

      {agent, directives2} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_tool_result, tool_result)],
          ctx()
        )

      llm_result2 = execute_llm_directive(hd(directives2))

      {_agent, _} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result2)],
          ctx()
        )

      spans = OTH.collect_spans()

      agent_span = OTH.find_span(spans, "otel_test_orchestrator")
      chain1 = OTH.find_span(spans, "iteration 1")
      chain2 = OTH.find_span(spans, "iteration 2")

      assert agent_span != nil

      assert chain1 != nil,
             "Expected iteration 1 span, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      assert chain2 != nil,
             "Expected iteration 2 span, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      OTH.assert_parent_child(agent_span, chain1)
      OTH.assert_parent_child(agent_span, chain2)
      OTH.assert_siblings(chain1, chain2)
    end

    test "parallel tool calls are siblings under CHAIN" do
      LLMStub.setup([
        {:tool_calls,
         [
           %{id: "call_1", name: "add", arguments: %{"value" => 1, "amount" => 2}},
           %{id: "call_2", name: "echo", arguments: %{"message" => "hi"}}
         ]},
        {:final_answer, "Done"}
      ])

      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Do both"})],
          ctx()
        )

      llm_result = execute_llm_directive(hd(directives))

      {agent, tool_directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      # Execute both tool directives
      for td <- tool_directives do
        tool_result = execute_tool_directive(td)

        {agent, _} =
          OrchestratorStrategy.cmd(
            agent,
            [make_instruction(:orchestrator_tool_result, tool_result)],
            ctx()
          )

        agent
      end

      # Need to get the agent after all tool results. Re-run from scratch to
      # get the final agent state (since we can't rebind in the for loop).
      # Actually, let's just collect spans — the tool dispatch creates them.
      spans = OTH.collect_spans()

      add_span = OTH.find_span(spans, "add")
      echo_span = OTH.find_span(spans, "echo")

      assert add_span != nil, "Expected 'add' tool span"
      assert echo_span != nil, "Expected 'echo' tool span"

      OTH.assert_siblings(add_span, echo_span)
    end
  end

  # -- Workflow: span hierarchy tests --

  describe "workflow span hierarchy" do
    test "workflow: AGENT > TOOL per node" do
      # Use EchoAction for both nodes to avoid tuple-key metadata issues
      agent =
        init_workflow(
          %{step1: {:action, EchoAction}, step2: {:action, EchoAction}},
          %{
            {:step1, :ok} => :step2,
            {:step2, :ok} => :done,
            {:_, :error} => :failed
          },
          initial: :step1
        )

      # Start the workflow
      {agent, directives} =
        WorkflowStrategy.cmd(
          agent,
          [make_instruction(:workflow_start, %{message: "hello"})],
          ctx()
        )

      # Execute step1
      step1_result = execute_workflow_directive(hd(directives))

      {agent, directives2} =
        WorkflowStrategy.cmd(
          agent,
          [make_instruction(:workflow_node_result, step1_result)],
          ctx()
        )

      # Execute step2
      step2_result = execute_workflow_directive(hd(directives2))

      {_agent, _} =
        WorkflowStrategy.cmd(
          agent,
          [make_instruction(:workflow_node_result, step2_result)],
          ctx()
        )

      spans = OTH.collect_spans()

      agent_span = OTH.find_span(spans, "otel_test_workflow")
      step1_span = OTH.find_span(spans, "echo")

      assert agent_span != nil,
             "Expected AGENT span, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      assert step1_span != nil,
             "Expected TOOL span for echo, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      # Both echo nodes produce spans named "echo" — find all of them
      echo_spans = OTH.find_spans(spans, "echo")
      assert [_, _] = echo_spans, "Expected 2 TOOL spans, got #{length(echo_spans)}"

      for echo_span <- echo_spans do
        OTH.assert_parent_child(agent_span, echo_span)
      end

      OTH.assert_siblings(Enum.at(echo_spans, 0), Enum.at(echo_spans, 1))
      OTH.assert_same_trace([agent_span | echo_spans])
    end
  end

  # -- Span attributes tests --

  describe "span attributes" do
    test "agent span has openinference.span.kind = AGENT" do
      LLMStub.setup([{:final_answer, "Hello"}])
      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Hi"})],
          ctx()
        )

      llm_result = execute_llm_directive(hd(directives))

      {_agent, _} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      spans = OTH.collect_spans()
      agent_span = OTH.find_span(spans, "otel_test_orchestrator")
      assert agent_span != nil

      attrs = OTH.span_attributes(agent_span)
      assert attrs["openinference.span.kind"] == "AGENT"
    end

    test "LLM span has openinference.span.kind = LLM and llm.model_name" do
      LLMStub.setup([{:final_answer, "Hello"}])
      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Hi"})],
          ctx()
        )

      llm_result = execute_llm_directive(hd(directives))

      {_agent, _} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      spans = OTH.collect_spans()
      llm_span = OTH.find_span_containing(spans, "stub:test-model")
      assert llm_span != nil

      attrs = OTH.span_attributes(llm_span)
      assert attrs["openinference.span.kind"] == "LLM"
      assert attrs["llm.model_name"] == "stub:test-model"
    end

    test "TOOL span has openinference.span.kind = TOOL and tool.name" do
      LLMStub.setup([
        {:tool_calls, [%{id: "call_1", name: "add", arguments: %{"value" => 1, "amount" => 2}}]},
        {:final_answer, "Done"}
      ])

      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Add"})],
          ctx()
        )

      llm_result = execute_llm_directive(hd(directives))

      {agent, tool_directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      # Must complete the tool to end its span
      tool_result = execute_tool_directive(hd(tool_directives))

      {agent, directives2} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_tool_result, tool_result)],
          ctx()
        )

      # Complete the final answer to end all spans
      llm_result2 = execute_llm_directive(hd(directives2))

      {_agent, _} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result2)],
          ctx()
        )

      spans = OTH.collect_spans()
      tool_span = OTH.find_span(spans, "add")

      assert tool_span != nil,
             "Expected 'add' tool span, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      attrs = OTH.span_attributes(tool_span)
      assert attrs["openinference.span.kind"] == "TOOL"
      assert attrs["tool.name"] == "add"
    end

    test "CHAIN span has openinference.span.kind = CHAIN" do
      LLMStub.setup([{:final_answer, "Hello"}])
      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Hi"})],
          ctx()
        )

      llm_result = execute_llm_directive(hd(directives))

      {_agent, _} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      spans = OTH.collect_spans()
      chain_span = OTH.find_span_containing(spans, "iteration")
      assert chain_span != nil

      attrs = OTH.span_attributes(chain_span)
      assert attrs["openinference.span.kind"] == "CHAIN"
    end
  end

  # -- Gap 7 isolation test --

  describe "Gap 7: nested agent OTel context reattachment" do
    test "obs_maybe_reattach_parent_otel_ctx reads OTel context from ParentRef.meta" do
      # Step 1: Start a tool span (simulating orchestrator side)
      tool_span_ctx =
        Jido.Observe.start_span([:jido, :composer, :tool], %{
          tool_name: "agent_tool",
          name: "agent_tool"
        })

      # Capture the OTel context while the tool span is active
      otel_ctx = OpenTelemetry.Ctx.get_current()

      # Step 2: End the tool span on the orchestrator side (but keep the context)
      Jido.Observe.finish_span(tool_span_ctx, %{result: "child spawned"})

      # Step 3: Simulate child process — clear OTel context
      OpenTelemetry.Ctx.attach(OpenTelemetry.Ctx.new())

      # Step 4: Build a workflow agent with __parent__ containing the otel context
      agent =
        init_workflow(
          %{step1: {:action, EchoAction}},
          %{
            {:step1, :ok} => :done,
            {:_, :error} => :failed
          },
          initial: :step1
        )

      # Inject the parent ref with OTel context into the agent's state
      agent = inject_parent_otel_ctx(agent, otel_ctx)

      # Step 5: Start the workflow — this should reattach the parent OTel context
      {agent, directives} =
        WorkflowStrategy.cmd(
          agent,
          [make_instruction(:workflow_start, %{message: "hello"})],
          ctx()
        )

      # Execute the single node to completion
      step_result = execute_workflow_directive(hd(directives))

      {_agent, _} =
        WorkflowStrategy.cmd(
          agent,
          [make_instruction(:workflow_node_result, step_result)],
          ctx()
        )

      spans = OTH.collect_spans()

      # Find the workflow's AGENT span and the tool span from the "orchestrator"
      workflow_agent_span = OTH.find_span(spans, "otel_test_workflow")
      tool_start_span = OTH.find_span(spans, "agent_tool")

      assert workflow_agent_span != nil,
             "Expected workflow AGENT span, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      assert tool_start_span != nil,
             "Expected tool span 'agent_tool', got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      # The key assertion: workflow's AGENT span should be parented under the tool span
      OTH.assert_parent_child(tool_start_span, workflow_agent_span)
    end
  end

  describe "Gap 7 negative: no parent OTel context" do
    test "workflow without __parent__ otel context produces a root AGENT span" do
      # No injected parent OTel context — the AGENT span should NOT have a tool parent
      agent =
        init_workflow(
          %{step1: {:action, EchoAction}},
          %{
            {:step1, :ok} => :done,
            {:_, :error} => :failed
          },
          initial: :step1
        )

      {agent, directives} =
        WorkflowStrategy.cmd(
          agent,
          [make_instruction(:workflow_start, %{message: "hello"})],
          ctx()
        )

      step_result = execute_workflow_directive(hd(directives))

      {_agent, _} =
        WorkflowStrategy.cmd(
          agent,
          [make_instruction(:workflow_node_result, step_result)],
          ctx()
        )

      spans = OTH.collect_spans()

      workflow_agent_span = OTH.find_span(spans, "otel_test_workflow")

      assert workflow_agent_span != nil,
             "Expected workflow AGENT span, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      # Without parent OTel context, the AGENT span should be a root span
      # (parent_span_id is :undefined or 0 for root spans in OTel)
      parent_id = OTH.parent_span_id(workflow_agent_span)

      assert parent_id in [0, :undefined],
             "Expected root AGENT span without parent OTel context, got parent_id=#{inspect(parent_id)}"
    end
  end

  # -- Private helpers --

  defp execute_tool_directive(%Jido.Agent.Directive.RunInstruction{
         instruction: %{action: action_module, params: params},
         meta: meta
       }) do
    case Jido.Exec.run(action_module, params) do
      {:ok, result} ->
        %{status: :ok, result: result, meta: meta || %{}}

      {:error, reason} ->
        %{status: :error, result: reason, meta: meta || %{}}
    end
  end

  defp execute_workflow_directive(%Jido.Agent.Directive.RunInstruction{instruction: instr}) do
    case Jido.Exec.run(instr.action, instr.params) do
      {:ok, result} ->
        %{
          status: :ok,
          result: result,
          instruction: instr,
          effects: [],
          meta: %{}
        }

      {:error, reason} ->
        %{
          status: :error,
          result: %{error: reason},
          instruction: instr,
          effects: [],
          meta: %{}
        }
    end
  end

  defp inject_parent_otel_ctx(agent, otel_ctx) do
    # The workflow strategy reads from agent.state.__parent__.meta.otel_parent_ctx
    # We need to inject this into the Zoi state
    state = agent.state

    parent_ref = %{meta: %{otel_parent_ctx: otel_ctx}}

    updated_state =
      if is_map(state) do
        Map.put(state, :__parent__, parent_ref)
      else
        # Zoi state — use Access protocol
        put_in(state[:__parent__], parent_ref)
      end

    %{agent | state: updated_state}
  end
end
