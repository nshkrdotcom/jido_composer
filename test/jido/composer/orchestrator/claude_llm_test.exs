defmodule Jido.Composer.Orchestrator.ClaudeLLMTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.CassetteHelper
  alias Jido.Composer.Orchestrator.ClaudeLLM

  @tools [
    %{
      name: "get_weather",
      description: "Get current weather for a city",
      parameters: %{
        type: "object",
        properties: %{city: %{type: "string", description: "City name"}},
        required: ["city"]
      }
    },
    %{
      name: "calculate",
      description: "Evaluate a mathematical expression",
      parameters: %{
        type: "object",
        properties: %{expression: %{type: "string", description: "Math expression"}},
        required: ["expression"]
      }
    }
  ]

  defp cassette_opts(cassette_name) do
    cassette_mode = CassetteHelper.cassette_mode()

    [
      req_options: [
        plug:
          {ReqCassette.Plug,
           %{
             cassette_name: cassette_name,
             cassette_dir: "test/cassettes",
             mode: cassette_mode,
             match_requests_on: [:method, :uri]
           }}
      ],
      model: "claude-sonnet-4-20250514",
      max_tokens: 1024,
      system_prompt: "You are a helpful assistant. Use tools when needed."
    ]
  end

  describe "single tool call (cassette)" do
    test "parses tool_use content blocks into tool_calls" do
      opts = cassette_opts("claude_llm_tool_call")

      {:ok, response, conversation} =
        ClaudeLLM.generate(
          nil,
          [],
          @tools,
          Keyword.put(opts, :query, "What's the weather in Paris?")
        )

      # Response should be tool_calls (with or without reasoning)
      case response do
        {:tool_calls, calls} ->
          assert length(calls) == 1
          [call] = calls
          assert call.name == "get_weather"
          assert call.arguments["city"] == "Paris"
          assert is_binary(call.id)

        {:tool_calls, calls, reasoning} ->
          assert length(calls) == 1
          [call] = calls
          assert call.name == "get_weather"
          assert call.arguments["city"] == "Paris"
          assert is_binary(reasoning)
      end

      # Conversation should be a non-empty list of messages
      assert [_ | _] = conversation
    end
  end

  describe "multi-tool call (cassette)" do
    test "parses multiple tool_use blocks" do
      opts = cassette_opts("claude_llm_multi_tool")

      {:ok, response, _conversation} =
        ClaudeLLM.generate(
          nil,
          [],
          @tools,
          Keyword.put(opts, :query, "Weather in Tokyo and 42*17?")
        )

      calls =
        case response do
          {:tool_calls, calls} -> calls
          {:tool_calls, calls, _reasoning} -> calls
        end

      assert [_, _] = calls
      names = Enum.map(calls, & &1.name) |> Enum.sort()
      assert names == ["calculate", "get_weather"]

      weather_call = Enum.find(calls, &(&1.name == "get_weather"))
      assert weather_call.arguments["city"] == "Tokyo"

      calc_call = Enum.find(calls, &(&1.name == "calculate"))
      assert calc_call.arguments["expression"] =~ "42"
      assert calc_call.arguments["expression"] =~ "17"
    end
  end

  describe "final answer (cassette)" do
    test "parses end_turn response as final_answer" do
      opts = cassette_opts("claude_llm_final_answer")

      # Simulate a follow-up call with tool results
      initial_conv = [
        %{"role" => "user", "content" => "What's the weather in Paris?"},
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "Let me check."},
            %{
              "type" => "tool_use",
              "id" => "toolu_prev",
              "name" => "get_weather",
              "input" => %{"city" => "Paris"}
            }
          ]
        }
      ]

      tool_results = [
        %{
          id: "toolu_prev",
          name: "get_weather",
          result: %{temperature: 18, condition: "Partly cloudy"}
        }
      ]

      {:ok, response, conversation} = ClaudeLLM.generate(initial_conv, tool_results, @tools, opts)

      assert {:final_answer, text} = response
      assert is_binary(text)
      assert String.length(text) > 0

      # Conversation should include the new messages
      assert is_list(conversation)
      assert length(conversation) > length(initial_conv)
    end
  end

  describe "API error (cassette)" do
    test "returns structured error on authentication failure" do
      opts = cassette_opts("claude_llm_api_error")
      # Force an invalid API key to trigger a 401 error
      opts = Keyword.put(opts, :api_key, "sk-ant-invalid-key")

      result = ClaudeLLM.generate(nil, [], @tools, Keyword.put(opts, :query, "Hello"))

      assert {:error, error} = result
      assert is_map(error)
      assert error.status == 401
    end
  end

  describe "conversation state management" do
    test "first call with nil conversation initializes messages" do
      opts = cassette_opts("claude_llm_conversation_init")

      {:ok, _response, conversation} =
        ClaudeLLM.generate(
          nil,
          [],
          @tools,
          Keyword.put(opts, :query, "What's the weather in Paris?")
        )

      # Should have user message + assistant response
      assert is_list(conversation)
      assert length(conversation) == 2

      [user_msg, assistant_msg] = conversation
      assert user_msg["role"] == "user"
      assert assistant_msg["role"] == "assistant"
    end

    test "conversation is serializable" do
      opts = cassette_opts("claude_llm_serializable")

      {:ok, _response, conv} =
        ClaudeLLM.generate(
          nil,
          [],
          @tools,
          Keyword.put(opts, :query, "What's the weather in London?")
        )

      binary = :erlang.term_to_binary(conv)
      restored = :erlang.binary_to_term(binary)
      assert conv == restored
    end
  end

  describe "tool format conversion" do
    test "converts neutral tool format to Anthropic input_schema" do
      # This is tested indirectly via the cassette calls working,
      # but we can also test the internal conversion directly
      tools = [
        %{
          name: "my_tool",
          description: "Does something",
          parameters: %{type: "object", properties: %{x: %{type: "integer"}}}
        }
      ]

      anthropic_tools = ClaudeLLM.to_anthropic_tools(tools)

      assert [%{name: "my_tool", description: "Does something", input_schema: schema}] =
               anthropic_tools

      assert schema.type == "object"
    end
  end
end
