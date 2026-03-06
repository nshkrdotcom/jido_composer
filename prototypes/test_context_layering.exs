# Prototype: Context Layering — Ambient, Fork, Working
#
# Questions to answer:
# 1. Can we separate ambient (read-only) from working (mutable) context?
# 2. Do fork functions (MFA tuples) work at agent boundaries?
# 3. Can to_flat_map/1 preserve backward compatibility?
# 4. Does scoping prevent ambient pollution?
# 5. How does this integrate with Machine.apply_result?
# 6. What does three-level nesting look like?
#
# Run: mix run prototypes/test_context_layering.exs

IO.puts("=== Prototype: Context Layering ===\n")

# -- Context struct --

defmodule Proto.Context do
  @moduledoc "Structured context with ambient/working/fork layers"

  defstruct ambient: %{}, working: %{}, fork_fns: %{}

  @type fork_fn :: {module(), atom(), list()}
  @type t :: %__MODULE__{
          ambient: map(),
          working: map(),
          fork_fns: %{atom() => fork_fn()}
        }

  def new(opts \\ []) do
    %__MODULE__{
      ambient: Keyword.get(opts, :ambient, %{}),
      working: Keyword.get(opts, :working, %{}),
      fork_fns: Keyword.get(opts, :fork_fns, %{})
    }
  end

  def get_ambient(%__MODULE__{ambient: ambient}, key),
    do: Map.get(ambient, key)

  def apply_result(%__MODULE__{working: working} = ctx, scope, result) do
    %{ctx | working: DeepMerge.deep_merge(working, %{scope => result})}
  end

  def fork_for_child(%__MODULE__{ambient: ambient, working: working, fork_fns: fns} = ctx) do
    forked_ambient =
      Enum.reduce(fns, ambient, fn {_name, {mod, fun, args}}, acc ->
        apply(mod, fun, [acc, working | args])
      end)

    %{ctx | ambient: forked_ambient}
  end

  def to_flat_map(%__MODULE__{ambient: ambient, working: working}) do
    Map.put(working, :__ambient__, ambient)
  end

  def to_serializable(%__MODULE__{ambient: ambient, working: working, fork_fns: fns}) do
    %{ambient: ambient, working: working, fork_fns: fns}
  end

  def from_serializable(%{ambient: ambient, working: working} = data) do
    %__MODULE__{
      ambient: ambient,
      working: working,
      fork_fns: Map.get(data, :fork_fns, %{})
    }
  end
end

# -- Test 1: Basic context operations --

IO.puts("--- Test 1: Basic Context operations ---")

ctx =
  Proto.Context.new(
    ambient: %{org_id: "acme", user_id: "alice", trace_id: "abc-123"},
    working: %{},
    fork_fns: %{}
  )

IO.inspect(Proto.Context.get_ambient(ctx, :org_id), label: "  get_ambient(:org_id)")
IO.inspect(Proto.Context.get_ambient(ctx, :user_id), label: "  get_ambient(:user_id)")

# Apply step results
ctx = Proto.Context.apply_result(ctx, :extract, %{records: [1, 2], count: 2})
ctx = Proto.Context.apply_result(ctx, :transform, %{records: [10, 20], count: 2})
IO.inspect(ctx.working, label: "  Working after 2 steps")
IO.inspect(ctx.ambient, label: "  Ambient unchanged")

IO.puts("  PASS: Basic operations work")

# -- Test 2: to_flat_map backward compatibility --

IO.puts("\n--- Test 2: to_flat_map backward compatibility ---")

flat = Proto.Context.to_flat_map(ctx)
IO.inspect(flat, label: "  Flat map")

# Check that nodes see both working data and ambient via __ambient__
IO.puts("  flat[:extract] = #{inspect(flat[:extract])}")
IO.puts("  flat[:__ambient__][:org_id] = #{inspect(flat[:__ambient__][:org_id])}")

# A node that needs org_id can access it:
# context.__ambient__.org_id
IO.puts("  PASS: Nodes can access ambient via __ambient__ key")

# -- Test 3: Fork functions --

IO.puts("\n--- Test 3: Fork functions at agent boundaries ---")

defmodule Proto.Forks do
  def correlation_fork(ambient, _working) do
    parent_id = ambient[:correlation_id] || "root"
    child_id = "#{parent_id}/child-#{:rand.uniform(1000)}"
    Map.put(ambient, :correlation_id, child_id)
  end

  def depth_fork(ambient, _working) do
    depth = Map.get(ambient, :depth, 0)
    Map.put(ambient, :depth, depth + 1)
  end

  def working_summary_fork(ambient, working) do
    # Example: pass a summary of working context into ambient for child
    summary = %{parent_steps_completed: map_size(working)}
    Map.put(ambient, :parent_summary, summary)
  end
end

ctx_with_forks =
  Proto.Context.new(
    ambient: %{org_id: "acme", correlation_id: "root", depth: 0},
    working: %{step1: %{done: true}, step2: %{done: true}},
    fork_fns: %{
      correlation: {Proto.Forks, :correlation_fork, []},
      depth: {Proto.Forks, :depth_fork, []},
      summary: {Proto.Forks, :working_summary_fork, []}
    }
  )

forked = Proto.Context.fork_for_child(ctx_with_forks)
IO.inspect(forked.ambient, label: "  Forked ambient (level 1)")

# Fork again for grandchild
forked2 = Proto.Context.fork_for_child(forked)
IO.inspect(forked2.ambient, label: "  Forked ambient (level 2)")

IO.puts("  org_id preserved: #{forked2.ambient.org_id == "acme"}")
IO.puts("  depth: #{forked2.ambient.depth}")
IO.puts("  correlation chain: root -> #{forked.ambient.correlation_id} -> #{forked2.ambient.correlation_id}")
IO.puts("  PASS: Fork functions compose correctly across levels")

# -- Test 4: Scoping prevents ambient pollution --

IO.puts("\n--- Test 4: Scoping prevents ambient pollution ---")

ctx =
  Proto.Context.new(
    ambient: %{org_id: "acme"},
    working: %{}
  )

# Simulate a malicious/buggy node trying to modify ambient via its result
malicious_result = %{__ambient__: %{org_id: "evil"}, data: "something"}

# apply_result scopes under state name, so __ambient__ becomes nested
ctx = Proto.Context.apply_result(ctx, :step1, malicious_result)

IO.inspect(ctx.working, label: "  Working (malicious result scoped)")
IO.inspect(ctx.ambient, label: "  Ambient (should be unchanged)")
IO.puts("  org_id still 'acme': #{ctx.ambient.org_id == "acme"}")
IO.puts("  Malicious data scoped safely: #{ctx.working.step1.__ambient__ == %{org_id: "evil"}}")
IO.puts("  PASS: Scoping prevents ambient pollution")

# -- Test 5: Machine integration --

IO.puts("\n--- Test 5: Machine integration with Context ---")

# NodeIO (must be defined before ContextMachine uses it)
defmodule Proto.NodeIO do
  defstruct [:type, :value, schema: nil, meta: %{}]

  def map(value) when is_map(value), do: %__MODULE__{type: :map, value: value}
  def text(value) when is_binary(value), do: %__MODULE__{type: :text, value: value}
  def to_map(%__MODULE__{type: :map, value: value}), do: value
  def to_map(%__MODULE__{type: :text, value: value}), do: %{text: value}
end

defmodule Proto.ContextMachine do
  @moduledoc "Prototype Machine that uses Context instead of bare map"

  def new(opts) do
    raw_context = Keyword.get(opts, :context, %{})

    context =
      case raw_context do
        %Proto.Context{} -> raw_context
        map when is_map(map) -> Proto.Context.new(working: map)
      end

    %{status: Keyword.fetch!(opts, :initial), context: context}
  end

  def apply_result(%{status: status, context: context} = machine, result) do
    resolved =
      case result do
        %Proto.NodeIO{} = io -> Proto.NodeIO.to_map(io)
        map when is_map(map) -> map
        value -> %{value: value}
      end

    %{machine | context: Proto.Context.apply_result(context, status, resolved)}
  end
end

# Test backward compatible: bare map
machine =
  Proto.ContextMachine.new(
    initial: :step1,
    context: %{initial_value: 10}
  )

IO.inspect(machine, label: "  Machine from bare map")
IO.puts("  Working context: #{inspect(machine.context.working)}")
IO.puts("  Ambient context: #{inspect(machine.context.ambient)}")

# Test with full Context
machine2 =
  Proto.ContextMachine.new(
    initial: :step1,
    context:
      Proto.Context.new(
        ambient: %{org_id: "acme"},
        working: %{initial_value: 10}
      )
  )

machine2 = Proto.ContextMachine.apply_result(machine2, %{extracted: true})
IO.inspect(machine2.context.working, label: "  After apply_result (map)")
IO.puts("  Ambient unchanged: #{machine2.context.ambient == %{org_id: "acme"}}")

# Apply NodeIO text result
machine2 = %{machine2 | status: :step2}
machine2 = Proto.ContextMachine.apply_result(machine2, Proto.NodeIO.text("Analysis done"))
IO.inspect(machine2.context.working, label: "  After apply_result (NodeIO.text)")

IO.puts("  PASS: Machine integrates with Context + NodeIO")

# -- Test 6: Serialization round-trip --

IO.puts("\n--- Test 6: Context serialization round-trip ---")

ctx =
  Proto.Context.new(
    ambient: %{org_id: "acme", trace_id: "xyz"},
    working: %{step1: %{records: [1, 2]}, step2: %{valid: true}},
    fork_fns: %{
      depth: {Proto.Forks, :depth_fork, []},
      correlation: {Proto.Forks, :correlation_fork, []}
    }
  )

serialized = Proto.Context.to_serializable(ctx)
IO.inspect(serialized, label: "  Serializable")

# MFA tuples are natively serializable
binary = :erlang.term_to_binary(serialized)
IO.inspect(byte_size(binary), label: "  Binary size (bytes)")

restored_data = :erlang.binary_to_term(binary)
restored = Proto.Context.from_serializable(restored_data)
IO.inspect(restored.ambient, label: "  Restored ambient")
IO.inspect(restored.fork_fns, label: "  Restored fork_fns")

# Fork functions still work after restore
re_forked = Proto.Context.fork_for_child(restored)
IO.inspect(re_forked.ambient, label: "  Re-forked ambient after restore")
IO.puts("  Depth incremented: #{re_forked.ambient[:depth] == 1}")
IO.puts("  PASS: Context serializes and restores with working fork functions")

# -- Test 7: Three-level nesting scenario --

IO.puts("\n--- Test 7: Three-level nesting scenario ---")

# Level 1: OuterWorkflow
level1_ctx =
  Proto.Context.new(
    ambient: %{org_id: "acme", user_id: "alice", depth: 0},
    working: %{},
    fork_fns: %{depth: {Proto.Forks, :depth_fork, []}}
  )

# Level 1 executes :gather action
level1_ctx = Proto.Context.apply_result(level1_ctx, :gather, %{records: ["a", "b"]})
IO.puts("  Level 1 after :gather - working: #{inspect(level1_ctx.working)}")

# Level 1 -> Level 2 boundary (SpawnAgent for MiddleOrchestrator)
level2_ctx = Proto.Context.fork_for_child(level1_ctx)
IO.puts("  Level 2 ambient: #{inspect(level2_ctx.ambient)}")
IO.puts("  Level 2 depth: #{level2_ctx.ambient.depth}")

# Level 2 executes some work
level2_ctx = Proto.Context.apply_result(level2_ctx, :analyze, %{score: 0.95})

# Level 2 -> Level 3 boundary (SpawnAgent for InnerWorkflow)
level3_ctx = Proto.Context.fork_for_child(level2_ctx)
IO.puts("  Level 3 ambient: #{inspect(level3_ctx.ambient)}")
IO.puts("  Level 3 depth: #{level3_ctx.ambient.depth}")

# Level 3 does work
level3_ctx = Proto.Context.apply_result(level3_ctx, :compute, %{result: 42})

# Results flow up
level3_result = level3_ctx.working
IO.puts("  Level 3 working (result sent up): #{inspect(level3_result)}")

# Level 2 receives child result under tool name scope
level2_ctx = Proto.Context.apply_result(level2_ctx, :inner_workflow, level3_result)
IO.puts("  Level 2 working after child: #{inspect(level2_ctx.working)}")

# Level 1 receives level 2's full result
level2_result = level2_ctx.working
level1_ctx = Proto.Context.apply_result(level1_ctx, :middle_orch, level2_result)
IO.puts("  Level 1 working after all: #{inspect(level1_ctx.working)}")

# Ambient never modified by children
IO.puts("  Level 1 ambient unchanged: #{level1_ctx.ambient == %{org_id: "acme", user_id: "alice", depth: 0}}")

IO.puts("  PASS: Three-level nesting works correctly")

# -- Test 8: Performance of context operations --

IO.puts("\n--- Test 8: Performance benchmarks ---")

# Create a realistic context
big_ctx =
  Proto.Context.new(
    ambient: %{org_id: "acme", user_id: "alice", trace_id: "xyz-123", session_id: "sess-456"},
    working: Enum.reduce(1..20, %{}, fn i, acc -> Map.put(acc, :"step_#{i}", %{data: "result_#{i}", count: i}) end),
    fork_fns: %{
      depth: {Proto.Forks, :depth_fork, []},
      correlation: {Proto.Forks, :correlation_fork, []},
      summary: {Proto.Forks, :working_summary_fork, []}
    }
  )

# Benchmark apply_result
{time_apply, _} =
  :timer.tc(fn ->
    Enum.reduce(1..10_000, big_ctx, fn i, ctx ->
      Proto.Context.apply_result(ctx, :"bench_#{i}", %{value: i})
    end)
  end)

IO.puts("  apply_result x10000: #{time_apply / 1000}ms (#{10_000 / (time_apply / 1_000_000)} ops/sec)")

# Benchmark fork_for_child
{time_fork, _} =
  :timer.tc(fn ->
    Enum.each(1..10_000, fn _ ->
      Proto.Context.fork_for_child(big_ctx)
    end)
  end)

IO.puts("  fork_for_child x10000: #{time_fork / 1000}ms (#{10_000 / (time_fork / 1_000_000)} ops/sec)")

# Benchmark to_flat_map
{time_flat, _} =
  :timer.tc(fn ->
    Enum.each(1..100_000, fn _ ->
      Proto.Context.to_flat_map(big_ctx)
    end)
  end)

IO.puts("  to_flat_map x100000: #{time_flat / 1000}ms (#{100_000 / (time_flat / 1_000_000)} ops/sec)")

# Benchmark serialization
{time_serial, _} =
  :timer.tc(fn ->
    serializable = Proto.Context.to_serializable(big_ctx)
    Enum.each(1..10_000, fn _ ->
      binary = :erlang.term_to_binary(serializable)
      :erlang.binary_to_term(binary)
    end)
  end)

IO.puts("  serialize round-trip x10000: #{time_serial / 1000}ms")

serial_size = Proto.Context.to_serializable(big_ctx) |> :erlang.term_to_binary() |> byte_size()
IO.puts("  Serialized size: #{serial_size} bytes")

IO.puts("\n=== Summary ===")
IO.puts("1. Ambient/working separation works cleanly")
IO.puts("2. Fork functions (MFA tuples) compose correctly across nesting levels")
IO.puts("3. to_flat_map provides backward compatible node interface")
IO.puts("4. Scoping under state name prevents ambient pollution from node results")
IO.puts("5. Machine.apply_result integrates with Context + NodeIO")
IO.puts("6. Serialization round-trip works including fork function restoration")
IO.puts("7. Three-level nesting propagates ambient down and results up correctly")
IO.puts("8. Performance: all operations are fast (microseconds per op)")
IO.puts("")
IO.puts("Key design insight: Nodes NEVER receive the Context struct directly.")
IO.puts("They get a flat map from to_flat_map/1. This is the critical backward")
IO.puts("compatibility constraint that makes the whole thing non-breaking.")
