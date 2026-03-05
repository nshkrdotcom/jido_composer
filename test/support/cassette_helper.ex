defmodule Jido.Composer.CassetteHelper do
  @moduledoc false

  @sensitive_headers ["authorization", "x-api-key", "cookie", "set-cookie"]

  @sensitive_patterns [
    {~r/sk-ant-[a-zA-Z0-9_-]+/, "<ANTHROPIC_KEY>"},
    {~r/sk-[a-zA-Z0-9]{20,}/, "<OPENAI_KEY>"},
    {~r/"api_key"\s*:\s*"[^"]+"/, "\"api_key\":\"<REDACTED>\""},
    {~r/Bearer\s+[a-zA-Z0-9._-]+/, "Bearer <TOKEN>"}
  ]

  def default_cassette_opts do
    [
      filter_request_headers: @sensitive_headers,
      filter_response_headers: @sensitive_headers
    ]
  end

  def filter_sensitive(body) when is_binary(body) do
    Enum.reduce(@sensitive_patterns, body, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  def filter_sensitive(other), do: other

  def req_options_for_cassette(cassette_name, opts \\ []) do
    cassette_dir = Keyword.get(opts, :cassette_dir, "test/cassettes")

    [
      plug: {ReqCassette, dir: cassette_dir, name: cassette_name},
      stream: false
    ]
  end
end
