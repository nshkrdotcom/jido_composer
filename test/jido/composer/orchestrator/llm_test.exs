defmodule Jido.Composer.Orchestrator.LLMTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Orchestrator.LLM

  # A valid implementation of the LLM behaviour
  defmodule ValidLLM do
    @behaviour LLM

    @impl true
    def generate(conversation, _tool_results, _tools, _opts) do
      updated_conv = [%{role: "assistant", content: "hello"} | conversation || []]
      {:ok, {:final_answer, "hello"}, updated_conv}
    end
  end

  # A module that claims the behaviour but doesn't implement it
  # (This is validated at compile time — we test the shape instead)

  describe "behaviour contract" do
    test "defines generate/4 callback" do
      callbacks = LLM.behaviour_info(:callbacks)
      assert {:generate, 4} in callbacks
    end

    test "ValidLLM implements the behaviour" do
      assert function_exported?(ValidLLM, :generate, 4)
    end
  end

  describe "response types" do
    test "final_answer response" do
      {:ok, response, conv} = ValidLLM.generate(nil, [], [], [])
      assert {:final_answer, "hello"} = response
      assert is_list(conv)
    end

    test "tool_calls response" do
      defmodule ToolCallLLM do
        @behaviour LLM

        @impl true
        def generate(_conversation, _tool_results, _tools, _opts) do
          calls = [%{id: "call_1", name: "get_weather", arguments: %{"city" => "Paris"}}]
          conv = [%{role: "assistant", content: "tool_calls"}]
          {:ok, {:tool_calls, calls}, conv}
        end
      end

      {:ok, response, _conv} = ToolCallLLM.generate(nil, [], [], [])

      assert {:tool_calls,
              [%{id: "call_1", name: "get_weather", arguments: %{"city" => "Paris"}}]} = response
    end

    test "tool_calls with reasoning response" do
      defmodule ReasoningLLM do
        @behaviour LLM

        @impl true
        def generate(_conversation, _tool_results, _tools, _opts) do
          calls = [%{id: "call_1", name: "search", arguments: %{"q" => "test"}}]
          conv = [%{role: "assistant", content: "reasoning"}]
          {:ok, {:tool_calls, calls, "I need to search for this"}, conv}
        end
      end

      {:ok, response, _conv} = ReasoningLLM.generate(nil, [], [], [])
      assert {:tool_calls, [%{id: "call_1"}], "I need to search for this"} = response
    end

    test "error response" do
      defmodule ErrorLLM do
        @behaviour LLM

        @impl true
        def generate(_conversation, _tool_results, _tools, _opts) do
          {:error, :rate_limited}
        end
      end

      assert {:error, :rate_limited} = ErrorLLM.generate(nil, [], [], [])
    end
  end

  describe "conversation state" do
    test "first call receives nil conversation" do
      defmodule TrackingLLM do
        @behaviour LLM

        @impl true
        def generate(conversation, _tool_results, _tools, _opts) do
          {:ok, {:final_answer, inspect(conversation)}, [conversation]}
        end
      end

      {:ok, {:final_answer, text}, _conv} = TrackingLLM.generate(nil, [], [], [])
      assert text == "nil"
    end

    test "subsequent calls pass opaque conversation through" do
      {:ok, _response, conv1} = ValidLLM.generate(nil, [], [], [])
      {:ok, _response, conv2} = ValidLLM.generate(conv1, [], [], [])

      # Conversation accumulates
      assert length(conv2) == 2
    end

    test "conversation state is serializable" do
      {:ok, _response, conv} = ValidLLM.generate(nil, [], [], [])
      binary = :erlang.term_to_binary(conv)
      restored = :erlang.binary_to_term(binary)
      assert conv == restored
    end
  end

  describe "tool descriptions" do
    test "tools are passed as neutral format maps" do
      defmodule EchoToolsLLM do
        @behaviour LLM

        @impl true
        def generate(_conversation, _tool_results, tools, _opts) do
          {:ok, {:final_answer, inspect(tools)}, [%{tools: tools}]}
        end
      end

      tools = [
        %{name: "get_weather", description: "Get weather", parameters: %{type: "object"}},
        %{name: "calculate", description: "Calculate", parameters: %{type: "object"}}
      ]

      {:ok, _response, [%{tools: received}]} = EchoToolsLLM.generate(nil, [], tools, [])
      assert length(received) == 2
      assert Enum.all?(received, &(Map.has_key?(&1, :name) and Map.has_key?(&1, :description)))
    end
  end

  describe "req_options propagation" do
    test "opts can contain req_options key" do
      defmodule ReqOptsLLM do
        @behaviour LLM

        @impl true
        def generate(_conversation, _tool_results, _tools, opts) do
          req_opts = Keyword.get(opts, :req_options, [])
          {:ok, {:final_answer, inspect(req_opts)}, [%{req_options: req_opts}]}
        end
      end

      opts = [req_options: [plug: :some_plug, stream: false]]
      {:ok, _response, [%{req_options: received}]} = ReqOptsLLM.generate(nil, [], [], opts)
      assert received[:plug] == :some_plug
      assert received[:stream] == false
    end
  end
end
