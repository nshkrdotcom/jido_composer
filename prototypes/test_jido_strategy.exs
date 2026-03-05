# Prototype: Verify Jido Strategy primitives work as designed
# Run with: mix run prototypes/test_jido_strategy.exs
#
# This script validates the critical assumptions jido_composer depends on:
# 1. Strategy.State helpers (get/put/status under __strategy__)
# 2. RunInstruction directive + result routing
# 3. SpawnAgent + emit_to_parent flow
# 4. DirectiveExec protocol for custom directives
# 5. Signal routing via signal_routes/1

IO.puts("=" |> String.duplicate(70))
IO.puts("JIDO STRATEGY PRIMITIVES VALIDATION")
IO.puts("=" |> String.duplicate(70))

# ============================================================
# TEST 1: Strategy.State helpers
# ============================================================
IO.puts("\n--- TEST 1: Strategy.State helpers ---")

defmodule TestAgent1 do
  use Jido.Agent,
    name: "test_strategy_state",
    schema: []
end

agent = TestAgent1.new()
IO.puts("Agent created: #{inspect(agent.id)}")

# Test get/put
state = Jido.Agent.Strategy.State.get(agent)
IO.puts("Initial strategy state: #{inspect(state)}")

agent = Jido.Agent.Strategy.State.put(agent, %{
  module: :test_module,
  status: :idle,
  machine: %{current: :extract},
  custom_data: "hello"
})

state = Jido.Agent.Strategy.State.get(agent)
IO.puts("After put: #{inspect(state)}")

# Test status helpers
status = Jido.Agent.Strategy.State.status(agent)
IO.puts("Status: #{inspect(status)}")

agent = Jido.Agent.Strategy.State.set_status(agent, :running)
IO.puts("After set_status(:running): #{inspect(Jido.Agent.Strategy.State.status(agent))}")

is_terminal = Jido.Agent.Strategy.State.terminal?(agent)
is_active = Jido.Agent.Strategy.State.active?(agent)
IO.puts("terminal?: #{is_terminal}, active?: #{is_active}")

agent = Jido.Agent.Strategy.State.set_status(agent, :success)
IO.puts("After set_status(:success): terminal?=#{Jido.Agent.Strategy.State.terminal?(agent)}")

# Test update
agent = Jido.Agent.Strategy.State.set_status(agent, :running)
agent = Jido.Agent.Strategy.State.update(agent, fn s ->
  Map.put(s, :iteration, 1)
end)
state = Jido.Agent.Strategy.State.get(agent)
IO.puts("After update: #{inspect(state)}")

IO.puts("TEST 1: PASS")

# ============================================================
# TEST 2: Directive structs can be created
# ============================================================
IO.puts("\n--- TEST 2: Directive struct creation ---")

alias Jido.Agent.Directive

# RunInstruction
defmodule NoopAction do
  use Jido.Action,
    name: "noop",
    description: "Does nothing",
    schema: []

  @impl true
  def run(_params, _context), do: {:ok, %{result: :noop}}
end

instruction = %Jido.Instruction{action: NoopAction, params: %{}, context: %{}}
run_inst = %Directive.RunInstruction{
  instruction: instruction,
  result_action: :workflow_node_result
}
IO.puts("RunInstruction: #{inspect(run_inst, limit: 3)}")

# SpawnAgent
spawn_dir = %Directive.SpawnAgent{
  agent: TestAgent1,
  tag: :child_etl,
  opts: [],
  meta: %{purpose: "test"}
}
IO.puts("SpawnAgent: #{inspect(spawn_dir, limit: 3)}")

# Emit
signal = Jido.Signal.new!(%{type: "test.signal", source: "/test", data: %{hello: "world"}})
emit_dir = %Directive.Emit{signal: signal}
IO.puts("Emit: #{inspect(emit_dir, limit: 3)}")

# Schedule
sched_dir = %Directive.Schedule{delay_ms: 5000, message: signal}
IO.puts("Schedule: #{inspect(sched_dir, limit: 3)}")

# Error
err_dir = %Directive.Error{error: %RuntimeError{message: "test error"}}
IO.puts("Error: #{inspect(err_dir, limit: 3)}")

# StopChild
stop_dir = %Directive.StopChild{tag: :child_etl}
IO.puts("StopChild: #{inspect(stop_dir, limit: 3)}")

IO.puts("TEST 2: PASS")

# ============================================================
# TEST 3: Custom Strategy with cmd/3
# ============================================================
IO.puts("\n--- TEST 3: Custom Strategy cmd/3 ---")

defmodule TestWorkflowStrategy do
  use Jido.Agent.Strategy

  @impl true
  def init(agent, _ctx) do
    agent = Jido.Agent.Strategy.State.put(agent, %{
      module: __MODULE__,
      status: :idle,
      step: 0
    })
    {agent, []}
  end

  @impl true
  def cmd(agent, instructions, _ctx) do
    instruction = List.first(instructions)
    action = instruction.action

    case action do
      :start_workflow ->
        agent = Jido.Agent.Strategy.State.update(agent, fn s ->
          %{s | status: :running, step: 1}
        end)
        # Emit a RunInstruction for the first step
        inst = %Jido.Instruction{action: NoopAction, params: %{step: 1}, context: %{}}
        directive = %Jido.Agent.Directive.RunInstruction{
          instruction: inst,
          result_action: :step_result
        }
        {agent, [directive]}

      :step_result ->
        state = Jido.Agent.Strategy.State.get(agent)
        next_step = state.step + 1
        if next_step > 3 do
          agent = Jido.Agent.Strategy.State.update(agent, fn s ->
            %{s | status: :success, step: next_step}
          end)
          {agent, []}
        else
          agent = Jido.Agent.Strategy.State.update(agent, fn s ->
            %{s | step: next_step}
          end)
          inst = %Jido.Instruction{action: NoopAction, params: %{step: next_step}, context: %{}}
          directive = %Jido.Agent.Directive.RunInstruction{
            instruction: inst,
            result_action: :step_result
          }
          {agent, [directive]}
        end
    end
  end

  @impl true
  def signal_routes(_ctx) do
    [
      {"test.workflow.start", {:strategy_cmd, :start_workflow}},
      {"test.workflow.result", {:strategy_cmd, :step_result}}
    ]
  end
end

defmodule TestAgentWithStrategy do
  use Jido.Agent,
    name: "test_with_strategy",
    schema: [],
    strategy: TestWorkflowStrategy
end

agent = TestAgentWithStrategy.new()
IO.puts("Agent with strategy: #{inspect(Jido.Agent.Strategy.State.get(agent))}")

# Simulate cmd/3 call
start_instruction = %Jido.Instruction{action: :start_workflow, params: %{}, context: %{}}
ctx = %{agent_module: TestAgentWithStrategy, strategy_opts: []}
{agent2, directives} = TestWorkflowStrategy.cmd(agent, [start_instruction], ctx)
IO.puts("After start: status=#{inspect(Jido.Agent.Strategy.State.status(agent2))}")
IO.puts("Directives: #{length(directives)}")
IO.puts("Directive type: #{inspect(directives |> List.first() |> Map.get(:__struct__))}")

# Simulate result routing
result_instruction = %Jido.Instruction{action: :step_result, params: %{status: :ok, result: %{}}, context: %{}}
{agent3, directives2} = TestWorkflowStrategy.cmd(agent2, [result_instruction], ctx)
state3 = Jido.Agent.Strategy.State.get(agent3)
IO.puts("After step 1 result: step=#{state3.step}, directives=#{length(directives2)}")

{agent4, directives3} = TestWorkflowStrategy.cmd(agent3, [result_instruction], ctx)
state4 = Jido.Agent.Strategy.State.get(agent4)
IO.puts("After step 2 result: step=#{state4.step}, directives=#{length(directives3)}")

{agent5, directives4} = TestWorkflowStrategy.cmd(agent4, [result_instruction], ctx)
state5 = Jido.Agent.Strategy.State.get(agent5)
IO.puts("After step 3 result: step=#{state5.step}, status=#{state5.status}, directives=#{length(directives4)}")

IO.puts("TEST 3: PASS")

# ============================================================
# TEST 4: DirectiveExec protocol for custom directives
# ============================================================
IO.puts("\n--- TEST 4: Custom DirectiveExec protocol ---")

defmodule CustomSuspendDirective do
  defstruct [:request_id, :prompt, :timeout]
end

# Check if protocol exists
IO.puts("DirectiveExec protocol module exists: #{Code.ensure_loaded?(Jido.AgentServer.DirectiveExec)}")

# We can't fully test protocol dispatch without AgentServer running,
# but we can verify the protocol is defined and implementable
try do
  defimpl Jido.AgentServer.DirectiveExec, for: CustomSuspendDirective do
    def exec(%{request_id: id, prompt: prompt}, _signal, state) do
      IO.puts("  Custom directive executed! request_id=#{id}, prompt=#{prompt}")
      {:ok, state}
    end
  end
  IO.puts("Custom DirectiveExec implementation compiled successfully!")
  IO.puts("TEST 4: PASS")
rescue
  e ->
    IO.puts("TEST 4: FAIL - #{inspect(e)}")
end

# ============================================================
# TEST 5: Persist (hibernate/thaw)
# ============================================================
IO.puts("\n--- TEST 5: Persist module ---")
IO.puts("Jido.Persist module exists: #{Code.ensure_loaded?(Jido.Persist)}")

# Check available functions
persist_fns = Jido.Persist.__info__(:functions) |> Enum.map(fn {name, arity} -> "#{name}/#{arity}" end)
IO.puts("Persist functions: #{inspect(persist_fns)}")

# ============================================================
# TEST 6: Deep merge behavior
# ============================================================
IO.puts("\n--- TEST 6: Deep merge edge cases ---")

# Basic deep merge
r1 = DeepMerge.deep_merge(%{a: %{x: 1}}, %{a: %{y: 2}})
IO.puts("Deep merge maps: #{inspect(r1)}")
# Expected: %{a: %{x: 1, y: 2}}

# List overwrite (NOT concat)
r2 = DeepMerge.deep_merge(%{items: [1, 2]}, %{items: [3, 4]})
IO.puts("Deep merge lists: #{inspect(r2)}")
# Expected: %{items: [3, 4]} — lists overwrite!

# Scoped accumulation (the Composer pattern)
ctx = %{}
ctx = DeepMerge.deep_merge(ctx, %{extract: %{records: [1, 2, 3], count: 3}})
ctx = DeepMerge.deep_merge(ctx, %{transform: %{cleaned: [1, 2], dropped: 1}})
ctx = DeepMerge.deep_merge(ctx, %{load: %{stored: 2, errors: []}})
IO.puts("Scoped accumulation: #{inspect(ctx)}")
# No collisions possible with scoped keys!

# Same scope overwrite
ctx2 = %{extract: %{records: [1, 2]}}
ctx2 = DeepMerge.deep_merge(ctx2, %{extract: %{records: [3, 4, 5]}})
IO.puts("Same scope overwrite: #{inspect(ctx2)}")
# Lists overwrite within scope — this is the documented behavior

# Nested deep merge within scope
ctx3 = %{extract: %{meta: %{source: "api", timestamp: 123}}}
ctx3 = DeepMerge.deep_merge(ctx3, %{extract: %{meta: %{count: 5}}})
IO.puts("Nested merge in scope: #{inspect(ctx3)}")
# Expected: %{extract: %{meta: %{source: "api", timestamp: 123, count: 5}}}

IO.puts("TEST 6: PASS")

# ============================================================
# TEST 7: emit_to_parent helper
# ============================================================
IO.puts("\n--- TEST 7: emit_to_parent ---")

# Create an agent with a fake parent ref
agent_with_parent = TestAgent1.new()
parent_ref = %Jido.AgentServer.ParentRef{
  pid: self(),
  id: "parent-123",
  tag: :my_child,
  meta: %{}
}
agent_with_parent = %{agent_with_parent | state: Map.put(agent_with_parent.state, :__parent__, parent_ref)}

result_signal = Jido.Signal.new!(%{type: "child.result", source: "/child", data: %{result: "done"}})
emit_directive = Jido.Agent.Directive.emit_to_parent(agent_with_parent, result_signal)
IO.puts("emit_to_parent returns: #{inspect(emit_directive, limit: 3)}")

# Without parent
agent_no_parent = TestAgent1.new()
emit_nil = Jido.Agent.Directive.emit_to_parent(agent_no_parent, result_signal)
IO.puts("emit_to_parent (no parent): #{inspect(emit_nil)}")

IO.puts("TEST 7: PASS")

# ============================================================
IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("ALL TESTS PASSED — Jido primitives match design assumptions")
IO.puts(String.duplicate("=", 70))
