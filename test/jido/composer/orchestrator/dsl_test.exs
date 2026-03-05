defmodule Jido.Composer.Orchestrator.DSLTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.TestActions.{AddAction, EchoAction}
  alias Jido.Composer.TestSupport.MockLLM

  defmodule SimpleOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "simple_orchestrator",
      description: "A simple orchestrator for testing",
      llm: Jido.Composer.TestSupport.MockLLM,
      nodes: [
        Jido.Composer.TestActions.AddAction,
        Jido.Composer.TestActions.EchoAction
      ],
      system_prompt: "You are a helpful test assistant.",
      max_iterations: 5
  end

  defmodule MinimalOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "minimal_orchestrator",
      llm: Jido.Composer.TestSupport.MockLLM,
      nodes: [Jido.Composer.TestActions.AddAction]
  end

  defmodule GatedOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "gated_orchestrator",
      description: "Orchestrator with approval-gated nodes",
      llm: Jido.Composer.TestSupport.MockLLM,
      nodes: [
        Jido.Composer.TestActions.AddAction,
        {Jido.Composer.TestActions.EchoAction, requires_approval: true}
      ],
      system_prompt: "You have gated tools."
  end

  describe "module generation" do
    test "generates a module that can create an agent" do
      agent = SimpleOrchestrator.new()
      assert agent.name == "simple_orchestrator"
    end

    test "agent has orchestrator strategy configured" do
      assert SimpleOrchestrator.strategy() == Jido.Composer.Orchestrator.Strategy
    end

    test "strategy_opts contain expected configuration" do
      opts = SimpleOrchestrator.strategy_opts()
      assert is_list(opts[:nodes])
      assert opts[:llm_module] == MockLLM
      assert opts[:system_prompt] == "You are a helpful test assistant."
      assert opts[:max_iterations] == 5
    end
  end

  describe "defaults" do
    test "description defaults when not provided" do
      agent = MinimalOrchestrator.new()
      assert agent.name == "minimal_orchestrator"
    end

    test "max_iterations defaults to 10 when not provided" do
      opts = MinimalOrchestrator.strategy_opts()
      assert opts[:max_iterations] == 10
    end

    test "system_prompt defaults to nil when not provided" do
      opts = MinimalOrchestrator.strategy_opts()
      assert opts[:system_prompt] == nil
    end

    test "req_options defaults to empty list" do
      opts = MinimalOrchestrator.strategy_opts()
      assert opts[:req_options] == []
    end
  end

  describe "node auto-wrapping" do
    test "bare action modules are included in strategy opts nodes list" do
      opts = SimpleOrchestrator.strategy_opts()
      assert AddAction in opts[:nodes]
      assert EchoAction in opts[:nodes]
    end
  end

  describe "signal routes" do
    test "generated module declares orchestrator signal routes" do
      routes = SimpleOrchestrator.signal_routes()
      route_types = Enum.map(routes, fn {type, _target} -> type end)
      assert "composer.orchestrator.query" in route_types
    end
  end

  describe "query/3" do
    test "sends orchestrator_start signal and returns directives" do
      MockLLM.setup([{:final_answer, "Test response"}])
      agent = SimpleOrchestrator.new()

      {agent, directives} = SimpleOrchestrator.query(agent, "Hello", %{})

      assert [%Jido.Agent.Directive.RunInstruction{}] = directives
      assert agent.state.__strategy__.status == :awaiting_llm
      assert agent.state.__strategy__.query == "Hello"
    end
  end

  describe "query_sync/3" do
    test "blocks until orchestrator produces final answer" do
      MockLLM.setup([{:final_answer, "The answer is 42"}])
      agent = SimpleOrchestrator.new()

      assert {:ok, "The answer is 42"} = SimpleOrchestrator.query_sync(agent, "What is 42?")
    end

    test "returns error on LLM failure" do
      MockLLM.setup([{:error, "API down"}])
      agent = SimpleOrchestrator.new()

      assert {:error, _reason} = SimpleOrchestrator.query_sync(agent, "Fail")
    end
  end

  describe "node options preservation" do
    defmodule OptionsOrchestrator do
      use Jido.Composer.Orchestrator,
        name: "options_orchestrator",
        llm: Jido.Composer.TestSupport.MockLLM,
        nodes: [
          Jido.Composer.TestActions.AddAction,
          {Jido.Composer.TestActions.EchoAction,
           description: "Custom echo", requires_approval: true}
        ]
    end

    test "node options other than requires_approval are preserved" do
      opts = OptionsOrchestrator.strategy_opts()
      # Nodes should carry their extra options for the strategy to use
      nodes = opts[:nodes]

      echo_entry =
        Enum.find(nodes, fn
          {mod, _opts} when is_atom(mod) -> mod == Jido.Composer.TestActions.EchoAction
          mod when is_atom(mod) -> mod == Jido.Composer.TestActions.EchoAction
          _ -> false
        end)

      assert echo_entry != nil
      # Options like description should be preserved as a tuple
      assert {Jido.Composer.TestActions.EchoAction, opts_list} = echo_entry
      assert Keyword.get(opts_list, :description) == "Custom echo"
    end
  end

  describe "HITL DSL options" do
    defmodule HITLOrchestrator do
      use Jido.Composer.Orchestrator,
        name: "hitl_orchestrator",
        llm: Jido.Composer.TestSupport.MockLLM,
        nodes: [
          {Jido.Composer.TestActions.AddAction, requires_approval: true}
        ],
        rejection_policy: :cancel_siblings
    end

    test "rejection_policy is passed to strategy opts" do
      opts = HITLOrchestrator.strategy_opts()
      assert opts[:rejection_policy] == :cancel_siblings
    end
  end

  describe "gated_nodes via DSL" do
    test "requires_approval metadata is passed through to strategy opts" do
      opts = GatedOrchestrator.strategy_opts()
      assert is_list(opts[:gated_nodes])
      assert "echo" in opts[:gated_nodes]
    end

    test "non-gated nodes are not in gated_nodes list" do
      opts = GatedOrchestrator.strategy_opts()
      refute "add" in opts[:gated_nodes]
    end
  end
end
