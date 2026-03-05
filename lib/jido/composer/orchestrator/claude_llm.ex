defmodule Jido.Composer.Orchestrator.ClaudeLLM do
  @moduledoc """
  Reference LLM implementation for the Anthropic Messages API.

  Implements `Jido.Composer.Orchestrator.LLM` behaviour against Claude's API,
  handling conversation management, tool format conversion, and response parsing.

  ## Options

  - `:model` — Model identifier (default: `"claude-sonnet-4-20250514"`)
  - `:max_tokens` — Max tokens to generate (default: `1024`)
  - `:system_prompt` — System prompt string
  - `:query` — User query (used on first call when conversation is nil)
  - `:api_key` — Anthropic API key (defaults to `ANTHROPIC_API_KEY` env var)
  - `:req_options` — Options merged into Req HTTP calls (for cassette injection)
  """

  @behaviour Jido.Composer.Orchestrator.LLM

  @api_url "https://api.anthropic.com/v1/messages"
  @default_model "claude-sonnet-4-20250514"
  @default_max_tokens 1024

  @impl true
  def generate(conversation, tool_results, tools, opts) do
    messages = build_messages(conversation, tool_results, opts)
    body = build_request_body(messages, tools, opts)

    case do_request(body, opts) do
      {:ok, %{status: 200, body: resp}} ->
        parse_response(resp, messages)

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Converts neutral tool descriptions to Anthropic's format.
  """
  def to_anthropic_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        name: tool.name,
        description: tool.description,
        input_schema: tool.parameters
      }
    end)
  end

  # -- Private --

  defp build_messages(nil, _tool_results, opts) do
    query = Keyword.get(opts, :query, "Hello")
    [%{"role" => "user", "content" => query}]
  end

  defp build_messages(conversation, [], _opts) do
    conversation
  end

  defp build_messages(conversation, tool_results, _opts) do
    tool_result_blocks =
      Enum.map(tool_results, fn tr ->
        %{
          "type" => "tool_result",
          "tool_use_id" => tr.id,
          "content" => Jason.encode!(tr.result)
        }
      end)

    conversation ++ [%{"role" => "user", "content" => tool_result_blocks}]
  end

  defp build_request_body(messages, tools, opts) do
    body = %{
      model: Keyword.get(opts, :model, @default_model),
      max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens),
      messages: messages
    }

    body =
      case Keyword.get(opts, :system_prompt) do
        nil -> body
        prompt -> Map.put(body, :system, prompt)
      end

    case tools do
      [] -> body
      tools -> Map.put(body, :tools, to_anthropic_tools(tools))
    end
  end

  defp do_request(body, opts) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY") || ""
    req_options = Keyword.get(opts, :req_options, [])

    base_opts = [
      url: @api_url,
      json: body,
      headers: [
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"},
        {"content-type", "application/json"}
      ]
    ]

    merged = Keyword.merge(base_opts, req_options)

    try do
      {:ok, Req.post!(merged)}
    rescue
      e -> {:error, e}
    end
  end

  defp parse_response(resp, messages) do
    content = resp["content"] || []
    tool_uses = Enum.filter(content, &(&1["type"] == "tool_use"))

    texts =
      content
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("\n", & &1["text"])

    updated_conv = messages ++ [%{"role" => "assistant", "content" => content}]

    response =
      if tool_uses != [] do
        calls =
          Enum.map(tool_uses, fn tu ->
            %{
              id: tu["id"],
              name: tu["name"],
              arguments: tu["input"]
            }
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
  end
end
