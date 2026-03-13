defmodule Jido.Composer.OtelInputMessagesTest do
  @moduledoc """
  Tests that LLM span `input_messages` attributes include the complete
  conversation history — including tool results from the preceding iteration.

  Uses LLMStub plug mode (Req.Test stub) so LLMAction produces a real
  ReqLLM.Context, combined with OTel span capture to verify attributes.

  This is a regression test for a bug where `emit_llm_call` captured
  `input_messages` from `state.conversation` before tool results were
  appended by LLMAction.
  """
  use ExUnit.Case, async: false

  alias Jido.Composer.Orchestrator.Strategy, as: OrchestratorStrategy
  alias Jido.Composer.OtelTestHelper, as: OTH
  alias Jido.Composer.TestSupport.LLMStub
  alias Jido.Composer.TestActions.AddAction

  @moduletag :capture_log

  # -- Test Agent --

  defmodule InputMsgOrchestrator do
    use Jido.Agent,
      name: "input_msg_orchestrator",
      description: "Agent for input_messages completeness tests",
      schema: []
  end

  # -- Setup / Teardown --

  setup do
    handler_state = OTH.setup_otel_capture(self())
    on_exit(fn -> OTH.teardown_otel(handler_state) end)
    :ok
  end

  # -- Helpers --

  defp init_orchestrator(plug) do
    strategy_opts = [
      nodes: [AddAction],
      model: "anthropic:claude-haiku-4-5-20251001",
      system_prompt: "You are a test assistant.",
      max_iterations: 10,
      req_options: [plug: plug]
    ]

    agent = InputMsgOrchestrator.new()
    ctx = %{strategy_opts: strategy_opts}
    {agent, _directives} = OrchestratorStrategy.init(agent, ctx)
    agent
  end

  defp make_instruction(action, params) do
    %Jido.Instruction{action: action, params: params}
  end

  defp ctx, do: %{}

  defp execute_llm_directive(%Jido.Agent.Directive.RunInstruction{instruction: instr}) do
    # Execute through the real LLMAction → ReqLLM → Req.Test stub path
    # so we get a real ReqLLM.Context with proper message history.
    # Use log_level: false to avoid Inspect crash on ReqLLM.Context in logs.
    case Jido.Exec.run(instr.action, instr.params, %{}, timeout: 0, log_level: false) do
      {:ok, result} ->
        %{status: :ok, result: result, meta: instr.context || %{}}

      {:error, reason} ->
        %{status: :error, result: %{error: reason}, meta: instr.context || %{}}
    end
  end

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

  defp find_llm_spans(spans) do
    spans
    |> Enum.filter(fn s ->
      attrs = OTH.span_attributes(s)
      attrs["openinference.span.kind"] == "LLM"
    end)
    |> Enum.sort_by(&OTH.span_name/1)
  end

  defp get_input_message_roles(attrs) do
    # Extract llm.input_messages.N.message.role for all N
    attrs
    |> Enum.filter(fn {k, _v} ->
      String.match?(k, ~r/^llm\.input_messages\.\d+\.message\.role$/)
    end)
    |> Enum.sort_by(fn {k, _v} ->
      [idx] = Regex.run(~r/\d+/, k)
      String.to_integer(idx)
    end)
    |> Enum.map(fn {_k, v} -> v end)
  end

  # -- Tests --

  describe "LLM span input_messages completeness" do
    test "second LLM call includes tool results from first iteration" do
      # Iteration 1: LLM returns tool_calls for "add"
      # Iteration 2: LLM sees tool results and returns final answer
      plug =
        LLMStub.setup_req_stub(:input_msg_test, [
          {:tool_calls,
           [%{id: "call_1", name: "add", arguments: %{"value" => 1.0, "amount" => 2.0}}]},
          {:final_answer, "The result is 3"}
        ])

      agent = init_orchestrator(plug)

      # Step 1: orchestrator_start → emits LLM directive
      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Add 1+2"})],
          ctx()
        )

      # Step 2: Execute LLM call #1 (returns tool_calls)
      llm_result = execute_llm_directive(hd(directives))

      {agent, tool_directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      # Step 3: Execute the tool
      tool_result = execute_tool_directive(hd(tool_directives))

      {agent, directives2} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_tool_result, tool_result)],
          ctx()
        )

      # Step 4: Execute LLM call #2 (returns final answer)
      llm_result2 = execute_llm_directive(hd(directives2))

      {_agent, _} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result2)],
          ctx()
        )

      # Collect and inspect OTel spans
      spans = OTH.collect_spans()
      llm_spans = find_llm_spans(spans)

      assert length(llm_spans) == 2,
             "Expected 2 LLM spans, got #{length(llm_spans)}: #{inspect(Enum.map(llm_spans, &OTH.span_name/1))}"

      # The second LLM span should have input_messages that include:
      # 0: system prompt (role=system)
      # 1: user query (role=user)
      # 2: assistant with tool_calls (role=assistant)
      # 3: tool result (role=tool)   <-- THIS IS THE BUG: currently missing
      second_llm = Enum.at(llm_spans, 1)
      attrs = OTH.span_attributes(second_llm)

      roles = get_input_message_roles(attrs)

      assert length(roles) >= 4,
             "Expected at least 4 input messages (system, user, assistant, tool) in second LLM span, " <>
               "got #{length(roles)}: #{inspect(roles)}"

      # The tool result message must be present
      assert "tool" in roles,
             "Expected a 'tool' role message in second LLM span input_messages, " <>
               "got roles: #{inspect(roles)}. " <>
               "This means tool results are missing from the LLM span's recorded input."

      # Verify ordering: system, user, assistant, tool
      assert Enum.at(roles, 0) == "system"
      assert Enum.at(roles, 1) == "user"
      assert Enum.at(roles, 2) == "assistant"
      assert Enum.at(roles, 3) == "tool"
    end

    test "third LLM call includes all prior tool results across iterations" do
      # Iteration 1: LLM → tool call "add" (1+2)
      # Iteration 2: LLM sees result, makes another tool call "add" (3+4)
      # Iteration 3: LLM sees both results, final answer
      plug =
        LLMStub.setup_req_stub(:input_msg_multi, [
          {:tool_calls,
           [%{id: "call_1", name: "add", arguments: %{"value" => 1.0, "amount" => 2.0}}]},
          {:tool_calls,
           [%{id: "call_2", name: "add", arguments: %{"value" => 3.0, "amount" => 4.0}}]},
          {:final_answer, "Results: 3 and 7"}
        ])

      agent = init_orchestrator(plug)

      # Iteration 1: start → LLM #1 → tool_calls
      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Add 1+2 then 3+4"})],
          ctx()
        )

      llm_result1 = execute_llm_directive(hd(directives))

      {agent, tool_directives1} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result1)],
          ctx()
        )

      tool_result1 = execute_tool_directive(hd(tool_directives1))

      {agent, directives2} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_tool_result, tool_result1)],
          ctx()
        )

      # Iteration 2: LLM #2 → more tool_calls
      llm_result2 = execute_llm_directive(hd(directives2))

      {agent, tool_directives2} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result2)],
          ctx()
        )

      tool_result2 = execute_tool_directive(hd(tool_directives2))

      {agent, directives3} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_tool_result, tool_result2)],
          ctx()
        )

      # Iteration 3: LLM #3 → final answer
      llm_result3 = execute_llm_directive(hd(directives3))

      {_agent, _} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result3)],
          ctx()
        )

      spans = OTH.collect_spans()
      llm_spans = find_llm_spans(spans)

      assert length(llm_spans) == 3,
             "Expected 3 LLM spans, got #{length(llm_spans)}"

      # LLM #3 should have the full conversation:
      # system, user, assistant(tool_calls), tool, assistant(tool_calls), tool
      third_llm = Enum.at(llm_spans, 2)
      attrs = OTH.span_attributes(third_llm)
      roles = get_input_message_roles(attrs)

      # Count tool messages - should have 2 (one per iteration)
      tool_count = Enum.count(roles, &(&1 == "tool"))

      assert tool_count == 2,
             "Expected 2 tool result messages in third LLM span, " <>
               "got #{tool_count}. Roles: #{inspect(roles)}. " <>
               "Tool results from prior iterations are missing."

      # Full expected pattern: system, user, assistant, tool, assistant, tool
      assert roles == ["system", "user", "assistant", "tool", "assistant", "tool"],
             "Expected conversation pattern [system, user, assistant, tool, assistant, tool], " <>
               "got #{inspect(roles)}"
    end
  end
end
