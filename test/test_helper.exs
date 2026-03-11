ExUnit.start(capture_log: true)

# Provide a dummy API key so ReqLLM.Keys.get!/2 does not raise in tests
# that use Req.Test stubs or ReqCassette replay (where no real HTTP call is made).
# Skip when a real key is available (needed for recording cassettes).
unless System.get_env("ANTHROPIC_API_KEY") do
  Application.put_env(:req_llm, :anthropic_api_key, "test-dummy-key")
end
