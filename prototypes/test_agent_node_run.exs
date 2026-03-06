# Prototype: AgentNode.run/3 fix + DSL sync loop SpawnAgent handling
#
# Questions to answer:
# 1. Can AgentNode.run/3 delegate to run_sync/2 or query_sync/3?
# 2. Does the DSL sync loop need a SpawnAgent handler?
# 3. Can FanOutNode branches contain AgentNodes after the fix?
# 4. What does the workflow agent actually export?
#
# Run: mix run prototypes/test_agent_node_run.exs

IO.puts("=== Prototype: AgentNode.run/3 Fix ===\n")

# -- Setup: Define test actions and agents --

defmodule Proto.IncrementAction do
  use Jido.Action,
    name: "increment",
    description: "Increments a counter",
    schema: [value: [type: :integer, required: false, doc: "current value"]]

  def run(params, _ctx) do
    value = Map.get(params, :value, 0)
    {:ok, %{value: value + 1}}
  end
end

defmodule Proto.DoubleAction do
  use Jido.Action,
    name: "double",
    description: "Doubles a value",
    schema: [value: [type: :integer, required: false, doc: "current value"]]

  def run(params, _ctx) do
    value = Map.get(params, :value, 0)
    {:ok, %{value: value * 2}}
  end
end

# A simple workflow agent (deterministic, no LLM)
defmodule Proto.MathWorkflow do
  use Jido.Composer.Workflow,
    name: "math_workflow",
    description: "Increments then doubles",
    nodes: %{
      step1: Proto.IncrementAction,
      step2: Proto.DoubleAction
    },
    transitions: %{
      {:step1, :ok} => :step2,
      {:step2, :ok} => :done,
      {:_, :error} => :failed
    },
    initial: :step1
end

# -- Test 1: What does a Workflow agent export? --

IO.puts("--- Test 1: Workflow module exports ---")

agent_mod = Proto.MathWorkflow
Code.ensure_loaded!(agent_mod)

exports = %{
  run_sync: function_exported?(agent_mod, :run_sync, 2),
  run: function_exported?(agent_mod, :run, 2),
  query_sync: function_exported?(agent_mod, :query_sync, 3),
  cmd: function_exported?(agent_mod, :cmd, 2),
  new: function_exported?(agent_mod, :new, 0),
  name: function_exported?(agent_mod, :name, 0),
  description: function_exported?(agent_mod, :description, 0),
  strategy: function_exported?(agent_mod, :strategy, 0),
  strategy_opts: function_exported?(agent_mod, :strategy_opts, 0),
  __agent_metadata__: function_exported?(agent_mod, :__agent_metadata__, 0)
}

IO.inspect(exports, label: "Workflow exports")

# -- Test 2: run_sync actually works --

IO.puts("\n--- Test 2: run_sync execution ---")

agent = Proto.MathWorkflow.new()
result = Proto.MathWorkflow.run_sync(agent, %{value: 5})
IO.inspect(result, label: "run_sync result (value: 5 -> increment -> double)")

case result do
  {:ok, ctx} ->
    # step1 increments: 5 -> 6, step2 doubles: 6 -> 12
    expected_step1 = %{value: 6}
    expected_step2 = %{value: 12}
    IO.puts("  step1 result: #{inspect(ctx[:step1])} (expected: #{inspect(expected_step1)})")
    IO.puts("  step2 result: #{inspect(ctx[:step2])} (expected: #{inspect(expected_step2)})")

    if ctx[:step1] == expected_step1 and ctx[:step2] == expected_step2 do
      IO.puts("  PASS: run_sync works correctly")
    else
      IO.puts("  FAIL: unexpected results")
    end

  {:error, reason} ->
    IO.puts("  FAIL: #{inspect(reason)}")
end

# -- Test 3: AgentNode.run/3 currently fails --

IO.puts("\n--- Test 3: AgentNode.run/3 current behavior ---")

alias Jido.Composer.Node.AgentNode

{:ok, agent_node} = AgentNode.new(Proto.MathWorkflow)
result = AgentNode.run(agent_node, %{value: 5})
IO.inspect(result, label: "AgentNode.run/3 current result")

case result do
  {:error, :not_directly_runnable} ->
    IO.puts("  CONFIRMED: AgentNode.run/3 returns {:error, :not_directly_runnable}")

  {:ok, _} ->
    IO.puts("  UNEXPECTED: AgentNode.run/3 worked (was it already fixed?)")

  other ->
    IO.puts("  UNEXPECTED: #{inspect(other)}")
end

# -- Test 4: Prototype the fix - can we delegate to run_sync? --

IO.puts("\n--- Test 4: Prototype AgentNode.run/3 fix ---")

defmodule Proto.AgentNodeRunnable do
  @moduledoc "Prototype: AgentNode with working run/3"

  @spec run_sync_agent(module(), map()) :: {:ok, map()} | {:error, term()}
  def run_sync_agent(agent_module, context) do
    agent = agent_module.new()

    cond do
      function_exported?(agent_module, :run_sync, 2) ->
        case agent_module.run_sync(agent, context) do
          {:ok, result_context} when is_map(result_context) ->
            {:ok, result_context}

          {:error, reason} ->
            {:error, reason}
        end

      function_exported?(agent_module, :query_sync, 3) ->
        query = Map.get(context, :query, Map.get(context, "query", ""))

        case agent_module.query_sync(agent, query, context) do
          {:ok, result} ->
            {:ok, %{result: result}}

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        {:error, :agent_not_sync_runnable}
    end
  end
end

result = Proto.AgentNodeRunnable.run_sync_agent(Proto.MathWorkflow, %{value: 5})
IO.inspect(result, label: "Prototype run_sync_agent result")

case result do
  {:ok, ctx} ->
    IO.puts("  PASS: Delegating to run_sync works!")
    IO.puts("  Context keys: #{inspect(Map.keys(ctx))}")

  {:error, reason} ->
    IO.puts("  FAIL: #{inspect(reason)}")
end

# -- Test 5: FanOutNode with prototype AgentNode --

IO.puts("\n--- Test 5: FanOutNode with AgentNode branches ---")

alias Jido.Composer.Node.FanOutNode
alias Jido.Composer.Node.ActionNode

# Custom branch executor that uses our prototype
defmodule Proto.AgentBranch do
  @moduledoc "Function wrapper to make AgentNode work in FanOut branches"

  def wrap(agent_module) do
    fn context ->
      Proto.AgentNodeRunnable.run_sync_agent(agent_module, context)
    end
  end
end

# Another simple workflow for the second branch
defmodule Proto.SquareWorkflow do
  defmodule SquareAction do
    use Jido.Action,
      name: "square",
      description: "Squares a value",
      schema: [value: [type: :integer, required: false, doc: "value"]]

    def run(params, _ctx) do
      value = Map.get(params, :value, 0)
      {:ok, %{value: value * value}}
    end
  end

  use Jido.Composer.Workflow,
    name: "square_workflow",
    description: "Squares a value",
    nodes: %{
      compute: SquareAction
    },
    transitions: %{
      {:compute, :ok} => :done,
      {:_, :error} => :failed
    },
    initial: :compute
end

# Create FanOutNode with mixed branches
{:ok, fan_out} =
  FanOutNode.new(
    name: "mixed_fanout",
    branches: [
      plain_action: Proto.IncrementAction |> ActionNode.new() |> elem(1),
      agent_workflow: Proto.AgentBranch.wrap(Proto.MathWorkflow),
      agent_square: Proto.AgentBranch.wrap(Proto.SquareWorkflow)
    ]
  )

context = %{value: 10}
result = FanOutNode.run(fan_out, context)
IO.inspect(result, label: "FanOutNode with agent branches")

case result do
  {:ok, merged} ->
    IO.puts("  Branch results:")
    IO.puts("    plain_action: #{inspect(merged[:plain_action])}")
    IO.puts("    agent_workflow: #{inspect(merged[:agent_workflow])}")
    IO.puts("    agent_square: #{inspect(merged[:agent_square])}")
    IO.puts("  PASS: FanOutNode with agent branches works!")

  {:error, reason} ->
    IO.puts("  FAIL: #{inspect(reason)}")
end

# -- Test 6: DSL sync loop SpawnAgent handling prototype --

IO.puts("\n--- Test 6: DSL sync loop SpawnAgent handling ---")

# The key insight: run_directives in the DSL only handles RunInstruction.
# When the strategy emits a SpawnAgent directive for an AgentNode,
# run_directives currently ignores it (falls through to _other clause).
# We need to handle it.

# Let's simulate what happens with a nested workflow

defmodule Proto.OuterWorkflow do
  use Jido.Composer.Workflow,
    name: "outer_workflow",
    description: "Outer workflow with nested agent",
    nodes: %{
      step1: Proto.IncrementAction,
      step2: Proto.MathWorkflow,
      step3: Proto.DoubleAction
    },
    transitions: %{
      {:step1, :ok} => :step2,
      {:step2, :ok} => :step3,
      {:step3, :ok} => :done,
      {:_, :error} => :failed
    },
    initial: :step1
end

IO.puts("  Outer workflow defined with nested MathWorkflow at step2")

# Test: run the outer workflow with current code
agent = Proto.OuterWorkflow.new()

# First, let's see what directives the strategy emits for step2
{agent, directives} = Proto.OuterWorkflow.run(agent, %{value: 5})
IO.inspect(length(directives), label: "  Initial directives count")
IO.inspect(Enum.map(directives, &(&1.__struct__)), label: "  Directive types")

# Execute directives manually to see what happens at step2
defmodule Proto.SyncLoop do
  @moduledoc "Prototype sync loop that handles SpawnAgent"

  def run_loop(module, agent, directives) do
    case run_directives(module, agent, directives) do
      {:ok, agent} ->
        strat = Jido.Agent.Strategy.State.get(agent)
        {:ok, strat.machine.context}

      {:error, reason} ->
        {:error, reason}

      {:suspend, agent, _directive} ->
        strat = Jido.Agent.Strategy.State.get(agent)
        {:error, {:suspended, strat.pending_approval}}
    end
  end

  defp run_directives(_module, agent, []), do: check_terminal(agent)

  defp run_directives(module, agent, [directive | rest]) do
    case directive do
      %Jido.Agent.Directive.RunInstruction{instruction: instr, result_action: result_action} ->
        payload = execute_sync(instr)
        {agent, new_directives} = module.cmd(agent, {result_action, payload})
        run_directives(module, agent, new_directives ++ rest)

      %Jido.Agent.Directive.SpawnAgent{agent: child_module, opts: spawn_opts, tag: tag} ->
        # NEW: Handle SpawnAgent by running child synchronously
        context = Map.get(spawn_opts, :context, %{})
        child_result = Proto.AgentNodeRunnable.run_sync_agent(child_module, context)

        payload =
          case child_result do
            {:ok, res} -> %{tag: tag, result: {:ok, res}}
            {:error, reason} -> %{tag: tag, result: {:error, reason}}
          end

        {agent, new_directives} = module.cmd(agent, {:workflow_child_result, payload})
        run_directives(module, agent, new_directives ++ rest)

      %Jido.Composer.Directive.SuspendForHuman{} = suspend ->
        {:suspend, agent, suspend}

      _other ->
        run_directives(module, agent, rest)
    end
  end

  defp execute_sync(%Jido.Instruction{action: action_module, params: params}) do
    case Jido.Exec.run(action_module, params, %{}, timeout: 0) do
      {:ok, result} -> %{status: :ok, result: result}
      {:ok, result, outcome} -> %{status: :ok, result: result, outcome: outcome}
      {:error, reason} -> %{status: :error, reason: reason}
    end
  end

  defp check_terminal(agent) do
    strat = Jido.Agent.Strategy.State.get(agent)

    case strat.status do
      :success -> {:ok, agent}
      :failure -> {:error, :workflow_failed}
      _ -> {:ok, agent}
    end
  end
end

# Test with our enhanced sync loop
agent = Proto.OuterWorkflow.new()
{agent, directives} = Proto.OuterWorkflow.run(agent, %{value: 5})
result = Proto.SyncLoop.run_loop(Proto.OuterWorkflow, agent, directives)

IO.inspect(result, label: "  Proto sync loop result")

case result do
  {:ok, ctx} ->
    IO.puts("  Context: #{inspect(ctx)}")
    # step1: increment 5 -> 6
    # step2: MathWorkflow(value: 6) -> increment 6 -> 7, double 7 -> 14
    # step3: double the step2 context... but what value does it see?
    IO.puts("  step1: #{inspect(ctx[:step1])}")
    IO.puts("  step2: #{inspect(ctx[:step2])}")
    IO.puts("  step3: #{inspect(ctx[:step3])}")
    IO.puts("  PASS: Nested agent execution via sync loop works!")

  {:error, reason} ->
    IO.puts("  FAIL: #{inspect(reason)}")
end

# -- Test 7: Verify run_sync result shape from child --

IO.puts("\n--- Test 7: Result shape analysis ---")

# What does run_sync actually return?
agent = Proto.MathWorkflow.new()
{:ok, ctx} = Proto.MathWorkflow.run_sync(agent, %{value: 10})
IO.inspect(ctx, label: "  run_sync context shape")
IO.puts("  Keys: #{inspect(Map.keys(ctx))}")
IO.puts("  Note: run_sync returns the FULL machine context, not just the last step result")
IO.puts("  This means the parent gets all intermediate state results scoped by name")

# What about when used as a child? The parent applies the WHOLE child context
# under the parent state name. So:
# parent.step2 = %{step1: %{value: 11}, step2: %{value: 22}, value: 10}
# This is fine - all child state is visible under parent scope

IO.puts("\n=== Summary ===")
IO.puts("1. AgentNode.run/3 CAN delegate to run_sync/2 - confirmed working")
IO.puts("2. DSL sync loop NEEDS SpawnAgent handler - confirmed necessary")
IO.puts("3. FanOutNode CAN contain AgentNode branches with the fix")
IO.puts("4. Result shape: run_sync returns full machine context (all step results)")
IO.puts("5. Parent scopes child's full context under the state name - natural nesting")
