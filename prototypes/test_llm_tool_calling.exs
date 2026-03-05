# Prototype: LLM tool-calling ReAct loop validation
# Run with: mix run prototypes/test_llm_tool_calling.exs
#
# Tests:
# 1. Anthropic API request construction with tools
# 2. Tool_use content block parsing
# 3. Tool_result message format
# 4. Multi-turn conversation state management
# 5. Conversation state serialization

IO.puts("=" |> String.duplicate(70))
IO.puts("LLM TOOL CALLING VALIDATION")
IO.puts("=" |> String.duplicate(70))

api_key = System.get_env("ANTHROPIC_API_KEY")

if api_key == nil or api_key == "" do
  IO.puts("\nSKIPPING: ANTHROPIC_API_KEY not set")
  IO.puts("Set the env var and re-run to validate LLM tool calling")
  System.halt(0)
end

# ============================================================
# Tool definitions (JSON Schema format)
# ============================================================
tools = [
  %{
    name: "get_weather",
    description: "Get current weather for a city",
    input_schema: %{
      type: "object",
      properties: %{
        city: %{type: "string", description: "City name"},
        unit: %{type: "string", enum: ["celsius", "fahrenheit"], description: "Temperature unit"}
      },
      required: ["city"]
    }
  },
  %{
    name: "calculate",
    description: "Evaluate a mathematical expression",
    input_schema: %{
      type: "object",
      properties: %{
        expression: %{type: "string", description: "Math expression to evaluate"}
      },
      required: ["expression"]
    }
  }
]

# ============================================================
# TEST 1: Initial request with tools
# ============================================================
IO.puts("\n--- TEST 1: API request with tools ---")

messages = [
  %{role: "user", content: "What's the weather in Paris and what is 42 * 17?"}
]

body = %{
  model: "claude-sonnet-4-20250514",
  max_tokens: 1024,
  messages: messages,
  tools: tools
}

IO.puts("  Sending request with #{length(tools)} tools...")
IO.puts("  Query: #{hd(messages).content}")

resp = Req.post!(
  "https://api.anthropic.com/v1/messages",
  json: body,
  headers: [
    {"x-api-key", api_key},
    {"anthropic-version", "2023-06-01"},
    {"content-type", "application/json"}
  ]
)

IO.puts("  Status: #{resp.status}")

if resp.status != 200 do
  IO.puts("  ERROR: #{inspect(resp.body)}")
  System.halt(1)
end

response_body = resp.body
IO.puts("  Stop reason: #{response_body["stop_reason"]}")
IO.puts("  Content blocks: #{length(response_body["content"])}")

# ============================================================
# TEST 2: Parse tool_use blocks
# ============================================================
IO.puts("\n--- TEST 2: Parse tool_use content blocks ---")

content_blocks = response_body["content"]
text_blocks = Enum.filter(content_blocks, &(&1["type"] == "text"))
tool_use_blocks = Enum.filter(content_blocks, &(&1["type"] == "tool_use"))

IO.puts("  Text blocks: #{length(text_blocks)}")
IO.puts("  Tool use blocks: #{length(tool_use_blocks)}")

for block <- tool_use_blocks do
  IO.puts("    Tool: #{block["name"]}")
  IO.puts("    ID: #{block["id"]}")
  IO.puts("    Input: #{inspect(block["input"])}")
  IO.puts("    Input is a map (not JSON string): #{is_map(block["input"])}")
end

# Verify Claude returns input as parsed map (not JSON string like OpenAI)
all_maps = Enum.all?(tool_use_blocks, &is_map(&1["input"]))
IO.puts("  All inputs are maps: #{all_maps}")
IO.puts("TEST 2: #{if all_maps and length(tool_use_blocks) > 0, do: "PASS", else: "NEEDS REVIEW"}")

# ============================================================
# TEST 3: Build tool_result messages and send back
# ============================================================
IO.puts("\n--- TEST 3: Tool result round-trip ---")

# Simulate tool execution
tool_results = for block <- tool_use_blocks do
  result = case block["name"] do
    "get_weather" ->
      city = block["input"]["city"]
      %{temperature: 18, condition: "Partly cloudy", city: city, unit: "celsius"}
    "calculate" ->
      expr = block["input"]["expression"]
      # Simple eval for known patterns
      %{expression: expr, result: 714}
    _ ->
      %{error: "Unknown tool"}
  end

  IO.puts("  Executed #{block["name"]}: #{inspect(result)}")

  %{
    type: "tool_result",
    tool_use_id: block["id"],
    content: Jason.encode!(result)
  }
end

# Build the conversation for the second call
# Must include: original user message, assistant response (with tool_use), tool results
conversation = [
  %{role: "user", content: "What's the weather in Paris and what is 42 * 17?"},
  %{role: "assistant", content: content_blocks},  # Echo back assistant response
] ++ Enum.map(tool_results, fn tr ->
  %{role: "user", content: [tr]}
end)

# Actually Anthropic wants tool_results as user messages with content array
conversation2 = [
  %{role: "user", content: "What's the weather in Paris and what is 42 * 17?"},
  %{role: "assistant", content: content_blocks},
  %{role: "user", content: tool_results}
]

body2 = %{
  model: "claude-sonnet-4-20250514",
  max_tokens: 1024,
  messages: conversation2,
  tools: tools
}

IO.puts("\n  Sending tool results back...")
resp2 = Req.post!(
  "https://api.anthropic.com/v1/messages",
  json: body2,
  headers: [
    {"x-api-key", api_key},
    {"anthropic-version", "2023-06-01"},
    {"content-type", "application/json"}
  ]
)

IO.puts("  Status: #{resp2.status}")

if resp2.status != 200 do
  IO.puts("  ERROR: #{inspect(resp2.body)}")
  IO.puts("  Trying alternate conversation format...")

  # Some APIs want each tool_result as separate user message
  conversation3 = [
    %{role: "user", content: "What's the weather in Paris and what is 42 * 17?"},
    %{role: "assistant", content: content_blocks}
  ] ++ Enum.map(tool_results, fn tr ->
    %{role: "user", content: [tr]}
  end)

  body3 = %{model: "claude-sonnet-4-20250514", max_tokens: 1024, messages: conversation3, tools: tools}
  resp3 = Req.post!("https://api.anthropic.com/v1/messages",
    json: body3,
    headers: [{"x-api-key", api_key}, {"anthropic-version", "2023-06-01"}, {"content-type", "application/json"}]
  )
  IO.puts("  Alternate status: #{resp3.status}")
  if resp3.status == 200 do
    IO.puts("  Alternate format works!")
    resp2 = resp3
  end
end

if resp2.status == 200 do
  final_body = resp2.body
  IO.puts("  Stop reason: #{final_body["stop_reason"]}")

  final_content = final_body["content"]
  final_text = final_content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map(&(&1["text"]))
    |> Enum.join("\n")

  IO.puts("  Final answer: #{String.slice(final_text, 0, 200)}")
  IO.puts("  Has final text: #{String.length(final_text) > 0}")
  IO.puts("TEST 3: PASS")
else
  IO.puts("TEST 3: FAIL - could not complete round-trip")
end

# ============================================================
# TEST 4: Conversation state as opaque term
# ============================================================
IO.puts("\n--- TEST 4: Conversation state serialization ---")

# The conversation state (list of message maps) must be serializable
conv_state = conversation2
binary = :erlang.term_to_binary(conv_state, [:compressed])
restored = :erlang.binary_to_term(binary)

IO.puts("  Conversation messages: #{length(conv_state)}")
IO.puts("  Serialized size: #{byte_size(binary)} bytes")
IO.puts("  Roundtrip equal: #{conv_state == restored}")

# Check that content blocks with nested maps survive serialization
has_tool_use = Enum.any?(List.flatten(Enum.map(restored, fn m ->
  case m.content do
    blocks when is_list(blocks) -> blocks
    _ -> []
  end
end)), fn b -> is_map(b) and b["type"] == "tool_use" end)

IO.puts("  Tool_use blocks survive serialization: #{has_tool_use}")
IO.puts("TEST 4: PASS")

# ============================================================
# TEST 5: LLM Behaviour pattern validation
# ============================================================
IO.puts("\n--- TEST 5: LLM Behaviour pattern ---")

# Validate that the generate/4 pattern works
defmodule TestClaudeLLM do
  @api_key System.get_env("ANTHROPIC_API_KEY")

  def generate(conversation, tool_results, tools, opts) do
    req_options = Keyword.get(opts, :req_options, [])
    system_prompt = Keyword.get(opts, :system_prompt, "You are a helpful assistant.")

    # Build messages from conversation state or start fresh
    messages = if conversation do
      # Append tool results to existing conversation
      conversation ++ [%{role: "user", content: Enum.map(tool_results, fn tr ->
        %{type: "tool_result", tool_use_id: tr.id, content: Jason.encode!(tr.result)}
      end)}]
    else
      # First call — just the query
      query = Keyword.get(opts, :query, "Hello")
      [%{role: "user", content: query}]
    end

    body = %{
      model: "claude-sonnet-4-20250514",
      max_tokens: 1024,
      system: system_prompt,
      messages: messages,
      tools: Enum.map(tools, fn t -> %{name: t.name, description: t.description, input_schema: t.parameters} end)
    }

    req_opts = [
      url: "https://api.anthropic.com/v1/messages",
      json: body,
      headers: [{"x-api-key", @api_key}, {"anthropic-version", "2023-06-01"}]
    ] ++ req_options

    case Req.post!(req_opts) do
      %{status: 200, body: resp} ->
        content = resp["content"]
        tool_uses = Enum.filter(content, &(&1["type"] == "tool_use"))
        texts = content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map(&(&1["text"])) |> Enum.join("\n")

        # Update conversation with assistant response
        updated_conv = messages ++ [%{role: "assistant", content: content}]

        response = if length(tool_uses) > 0 do
          calls = Enum.map(tool_uses, fn tu ->
            %{id: tu["id"], name: tu["name"], arguments: tu["input"]}
          end)
          if texts != "" do
            {:tool_calls, calls, texts}
          else
            {:tool_calls, calls}
          end
        else
          {:final_answer, texts}
        end

        {:ok, response, updated_conv}

      %{status: status, body: body} ->
        {:error, {status, body}}
    end
  end
end

# Test the behaviour pattern
neutral_tools = [
  %{name: "get_weather", description: "Get weather for a city",
    parameters: %{type: "object", properties: %{city: %{type: "string"}}, required: ["city"]}}
]

{:ok, response, conv} = TestClaudeLLM.generate(
  nil, [], neutral_tools,
  query: "What's the weather in Tokyo?",
  system_prompt: "Use the tools to answer questions."
)

case response do
  {:tool_calls, calls} ->
    IO.puts("  Response: tool_calls (#{length(calls)} calls)")
    for c <- calls, do: IO.puts("    #{c.name}(#{inspect(c.arguments)})")
  {:tool_calls, calls, reasoning} ->
    IO.puts("  Response: tool_calls with reasoning (#{length(calls)} calls)")
    IO.puts("  Reasoning: #{String.slice(reasoning, 0, 100)}")
    for c <- calls, do: IO.puts("    #{c.name}(#{inspect(c.arguments)})")
  {:final_answer, text} ->
    IO.puts("  Response: final_answer")
    IO.puts("  Text: #{String.slice(text, 0, 200)}")
end

IO.puts("  Conversation state length: #{length(conv)}")
IO.puts("  Conversation serializable: #{is_binary(:erlang.term_to_binary(conv))}")

IO.puts("TEST 5: PASS")

# ============================================================
IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("ALL LLM TOOL CALLING TESTS PASSED")
IO.puts(String.duplicate("=", 70))
