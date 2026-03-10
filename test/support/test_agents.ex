defmodule Jido.Composer.TestAgents do
  @moduledoc false

  defmodule EchoAgent do
    @moduledoc false
    use Jido.Agent,
      name: "echo_agent",
      description: "Echoes incoming signal data as state",
      schema: [
        result: [type: :any, default: nil]
      ]
  end

  defmodule CounterAgent do
    @moduledoc false
    use Jido.Agent,
      name: "counter_agent",
      description: "Maintains a simple counter",
      schema: [
        count: [type: :integer, default: 0]
      ]
  end

  defmodule TestWorkflowAgent do
    @moduledoc false
    use Jido.Composer.Workflow,
      name: "test_workflow_agent",
      description: "Simple 2-state workflow for nesting tests",
      nodes: %{
        transform: Jido.Composer.TestActions.TransformAction,
        load: Jido.Composer.TestActions.LoadAction
      },
      transitions: %{
        {:transform, :ok} => :load,
        {:load, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :transform
  end

  defmodule TestOrchestratorAgent do
    @moduledoc false
    use Jido.Composer.Orchestrator,
      name: "test_orchestrator_agent",
      description: "Single-tool orchestrator for nesting tests",
      nodes: [Jido.Composer.TestActions.EchoAction],
      system_prompt: "You have an echo tool. Use it to respond to queries."
  end

  defmodule FakeAIAgent do
    @moduledoc """
    Simulates a Jido.AI.Agent for testing jido_ai integration.

    Exports `ask_sync/3` (pid-based) but NOT `run_sync/2` or `query_sync/3`,
    matching the Jido.AI.Agent interface. Uses a simple GenServer that echoes
    queries back as results.
    """

    use GenServer

    # -- Jido.Agent interface (module-level) --

    def __agent_metadata__, do: %{name: "fake_ai_agent"}
    def name, do: "fake_ai_agent"
    def description, do: "A fake AI agent for testing Composer integration"
    def schema, do: Zoi.object(%{query: Zoi.string() |> Zoi.optional()})

    def new do
      %Jido.Agent{
        id: "fake-ai-agent-#{System.unique_integer([:positive])}",
        state: %{__strategy__: %{}}
      }
    end

    # -- Jido.AI.Agent interface (pid-based) --

    def ask_sync(pid, query, opts \\ []) when is_binary(query) do
      timeout = Keyword.get(opts, :timeout, 5_000)
      GenServer.call(pid, {:ask_sync, query}, timeout)
    end

    # -- GenServer (test harness) --

    def start_link(opts \\ []) do
      handler = Keyword.get(opts, :handler, &default_handler/1)
      GenServer.start_link(__MODULE__, handler)
    end

    @impl true
    def init(handler), do: {:ok, %{handler: handler}}

    @impl true
    def handle_call({:ask_sync, query}, _from, %{handler: handler} = state) do
      {:reply, handler.(query), state}
    end

    defp default_handler(query), do: {:ok, "AI response to: #{query}"}
  end
end
