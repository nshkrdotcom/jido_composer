defmodule Jido.Composer.Orchestrator.MultiTurnTest do
  @moduledoc """
  Tests for multi-turn conversational orchestrators where conversation
  history is pre-loaded and subsequent query_sync calls must append the
  new user query to the existing conversation.
  """
  use ExUnit.Case, async: true

  alias Jido.Composer.TestSupport.LLMStub

  defmodule MultiTurnOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "multi_turn_orchestrator",
      model: "anthropic:claude-sonnet-4-20250514",
      nodes: [
        Jido.Composer.TestActions.AddAction,
        Jido.Composer.TestActions.EchoAction
      ],
      system_prompt: "You are a helpful assistant.",
      max_iterations: 5
  end

  describe "multi-turn: new query appended to pre-loaded conversation" do
    test "second query_sync appends new user message to existing conversation" do
      # Turn 1: normal first query
      plug = LLMStub.setup_req_stub(:multi_turn_1, [{:final_answer, "Answer 1"}])
      agent = MultiTurnOrchestrator.new()
      agent = put_in(agent.state.__strategy__.req_options, plug: plug)

      assert {:ok, agent, "Answer 1"} =
               MultiTurnOrchestrator.query_sync(agent, "First question")

      # At this point agent has a conversation with: system, user("First question"), assistant("Answer 1")
      strat = agent.state.__strategy__
      assert %ReqLLM.Context{} = strat.conversation
      first_conv_messages = strat.conversation.messages

      assert Enum.any?(first_conv_messages, fn msg ->
               msg.role == :user and
                 is_list(msg.content) and
                 Enum.any?(msg.content, fn
                   %{text: text} -> text == "First question"
                   _ -> false
                 end)
             end)

      # Turn 2: new query with the existing conversation
      # The new query should be appended as a user message
      plug2 = LLMStub.setup_req_stub(:multi_turn_2, [{:final_answer, "Answer 2"}])
      agent = put_in(agent.state.__strategy__.req_options, plug: plug2)

      assert {:ok, agent, "Answer 2"} =
               MultiTurnOrchestrator.query_sync(agent, "Second question")

      strat = agent.state.__strategy__
      messages = strat.conversation.messages

      # The conversation should contain BOTH user messages
      user_messages =
        Enum.filter(messages, fn msg ->
          msg.role == :user
        end)

      user_texts =
        Enum.flat_map(user_messages, fn msg ->
          case msg.content do
            content when is_list(content) ->
              Enum.flat_map(content, fn
                %{text: text} -> [text]
                _ -> []
              end)

            text when is_binary(text) ->
              [text]

            _ ->
              []
          end
        end)

      assert "First question" in user_texts,
             "First user message should be preserved. Got: #{inspect(user_texts)}"

      assert "Second question" in user_texts,
             "Second user message should be appended. Got: #{inspect(user_texts)}"
    end

    test "query is NOT double-appended on ReAct iterations with tool results" do
      plug =
        LLMStub.setup_req_stub(:multi_turn_no_double, [
          # Turn 1: final answer
          {:final_answer, "First answer"},
          # Turn 2: tool call then final answer
          {:tool_calls, [%{id: "call_1", name: "echo", arguments: %{"message" => "test"}}]},
          {:final_answer, "Second answer with tool"}
        ])

      agent = MultiTurnOrchestrator.new()
      agent = put_in(agent.state.__strategy__.req_options, plug: plug)

      # Turn 1
      assert {:ok, agent, "First answer"} =
               MultiTurnOrchestrator.query_sync(agent, "First question")

      # Turn 2: involves a tool call (ReAct iteration)
      agent = put_in(agent.state.__strategy__.req_options, plug: plug)

      assert {:ok, agent, "Second answer with tool"} =
               MultiTurnOrchestrator.query_sync(agent, "Use echo tool")

      strat = agent.state.__strategy__
      messages = strat.conversation.messages

      # Count how many times "Use echo tool" appears as a user message
      use_echo_count =
        Enum.count(messages, fn msg ->
          msg.role == :user and
            is_list(msg.content) and
            Enum.any?(msg.content, fn
              %{text: "Use echo tool"} -> true
              _ -> false
            end)
        end)

      assert use_echo_count == 1,
             "Second query should appear exactly once (not double-appended). Found #{use_echo_count} times."
    end
  end
end
