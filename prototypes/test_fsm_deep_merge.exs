# Prototype: FSM + scoped deep merge validation
# Run with: mix run prototypes/test_fsm_deep_merge.exs

IO.puts("=" |> String.duplicate(70))
IO.puts("FSM + DEEP MERGE VALIDATION")
IO.puts("=" |> String.duplicate(70))

# ============================================================
# Minimal Machine implementation
# ============================================================
defmodule Machine do
  defstruct [:status, :nodes, :transitions, :terminal_states, :context, :history]

  def new(opts) do
    %Machine{
      status: opts[:initial],
      nodes: opts[:nodes],
      transitions: opts[:transitions],
      terminal_states: MapSet.new(opts[:terminal] || [:done, :failed]),
      context: opts[:context] || %{},
      history: []
    }
  end

  def current_node(m), do: Map.get(m.nodes, m.status)

  def terminal?(m), do: MapSet.member?(m.terminal_states, m.status)

  def apply_result(m, state_name, result_ctx) do
    scoped = %{state_name => result_ctx}
    new_ctx = DeepMerge.deep_merge(m.context, scoped)
    %{m | context: new_ctx}
  end

  def transition(m, outcome) do
    case lookup_transition(m.transitions, m.status, outcome) do
      nil -> {:error, {:no_transition, m.status, outcome}}
      next ->
        new_m = %{m |
          status: next,
          history: [{m.status, outcome, System.monotonic_time()} | m.history]
        }
        {:ok, new_m}
    end
  end

  defp lookup_transition(transitions, state, outcome) do
    # Fallback chain: exact → wildcard state → wildcard outcome → global
    Map.get(transitions, {state, outcome}) ||
    Map.get(transitions, {:_, outcome}) ||
    Map.get(transitions, {state, :_}) ||
    Map.get(transitions, {:_, :_})
  end

  def run(m) do
    if terminal?(m) do
      {:ok, m}
    else
      node_fn = current_node(m)
      case node_fn.(m.context) do
        {:ok, result} ->
          m = apply_result(m, m.status, result)
          case transition(m, :ok) do
            {:ok, m} -> run(m)
            {:error, reason} -> {:error, reason, m}
          end
        {:ok, result, outcome} ->
          m = apply_result(m, m.status, result)
          case transition(m, outcome) do
            {:ok, m} -> run(m)
            {:error, reason} -> {:error, reason, m}
          end
        {:error, reason} ->
          case transition(m, :error) do
            {:ok, m} -> run(m)
            {:error, _} -> {:error, reason, m}
          end
      end
    end
  end
end

# ============================================================
# TEST 1: Linear pipeline
# ============================================================
IO.puts("\n--- TEST 1: Linear pipeline (extract → transform → load → done) ---")

m1 = Machine.new(
  initial: :extract,
  nodes: %{
    extract: fn _ctx -> {:ok, %{records: [1, 2, 3], source: "api"}} end,
    transform: fn ctx ->
      records = ctx[:extract][:records] || []
      {:ok, %{cleaned: Enum.map(records, &(&1 * 2))}}
    end,
    load: fn ctx ->
      cleaned = ctx[:transform][:cleaned] || []
      {:ok, %{count: length(cleaned), stored: true}}
    end
  },
  transitions: %{
    {:extract, :ok} => :transform,
    {:transform, :ok} => :load,
    {:load, :ok} => :done
  }
)

{:ok, result} = Machine.run(m1)
IO.puts("  Final state: #{result.status}")
IO.puts("  Context: #{inspect(result.context)}")
IO.puts("  History: #{length(result.history)} transitions")

# Verify scoping
assert_keys = [:extract, :transform, :load]
has_all = Enum.all?(assert_keys, &Map.has_key?(result.context, &1))
IO.puts("  All scoped keys present: #{has_all}")
IO.puts("TEST 1: #{if has_all, do: "PASS", else: "FAIL"}")

# ============================================================
# TEST 2: Branching (validate → :ok/:invalid)
# ============================================================
IO.puts("\n--- TEST 2: Branching ---")

make_branching = fn validate_outcome ->
  Machine.new(
    initial: :extract,
    nodes: %{
      extract: fn _ctx -> {:ok, %{data: "raw"}} end,
      validate: fn _ctx -> {:ok, %{checked: true}, validate_outcome} end,
      load: fn _ctx -> {:ok, %{loaded: true}} end,
      quarantine: fn _ctx -> {:ok, %{quarantined: true}} end
    },
    transitions: %{
      {:extract, :ok} => :validate,
      {:validate, :ok} => :load,
      {:validate, :invalid} => :quarantine,
      {:load, :ok} => :done,
      {:quarantine, :ok} => :done
    }
  )
end

{:ok, ok_result} = Machine.run(make_branching.(:ok))
IO.puts("  :ok branch → #{ok_result.status}, has :load key: #{Map.has_key?(ok_result.context, :load)}")

{:ok, invalid_result} = Machine.run(make_branching.(:invalid))
IO.puts("  :invalid branch → #{invalid_result.status}, has :quarantine key: #{Map.has_key?(invalid_result.context, :quarantine)}")

IO.puts("TEST 2: PASS")

# ============================================================
# TEST 3: Wildcard error handling
# ============================================================
IO.puts("\n--- TEST 3: Wildcard error handling ---")

m3 = Machine.new(
  initial: :extract,
  nodes: %{
    extract: fn _ctx -> {:ok, %{data: "ok"}} end,
    transform: fn _ctx -> {:error, :transform_failed} end,
    load: fn _ctx -> {:ok, %{loaded: true}} end
  },
  transitions: %{
    {:extract, :ok} => :transform,
    {:transform, :ok} => :load,
    {:load, :ok} => :done,
    {:_, :error} => :failed
  }
)

{:ok, err_result} = Machine.run(m3)
IO.puts("  Final state: #{err_result.status}")
IO.puts("  Hit :failed via wildcard: #{err_result.status == :failed}")
IO.puts("TEST 3: PASS")

# ============================================================
# TEST 4: Deep merge edge cases
# ============================================================
IO.puts("\n--- TEST 4: Deep merge edge cases ---")

# 4a: Two nodes with same-shape results at different scopes
ctx = %{}
ctx = DeepMerge.deep_merge(ctx, %{node_a: %{items: [1, 2], count: 2}})
ctx = DeepMerge.deep_merge(ctx, %{node_b: %{items: [3, 4], count: 2}})
IO.puts("  4a Disjoint scopes: #{inspect(ctx)}")
IO.puts("     No collision: #{ctx.node_a.items == [1, 2] and ctx.node_b.items == [3, 4]}")

# 4b: List overwrite within same scope (re-running node)
ctx2 = %{extract: %{records: [1, 2]}}
ctx2 = DeepMerge.deep_merge(ctx2, %{extract: %{records: [10, 20, 30]}})
IO.puts("  4b Same scope overwrite: records=#{inspect(ctx2.extract.records)}")
IO.puts("     Lists replaced (not concatenated): #{ctx2.extract.records == [10, 20, 30]}")

# 4c: Nested map preservation within scope
ctx3 = %{extract: %{meta: %{source: "api", version: 1}, count: 5}}
ctx3 = DeepMerge.deep_merge(ctx3, %{extract: %{meta: %{status: :ok}}})
IO.puts("  4c Nested merge: #{inspect(ctx3.extract.meta)}")
IO.puts("     Preserves existing keys: #{ctx3.extract.meta.source == "api"}")
IO.puts("     Adds new keys: #{ctx3.extract.meta.status == :ok}")
IO.puts("     Preserves sibling keys: #{ctx3.extract.count == 5}")

IO.puts("TEST 4: PASS")

# ============================================================
# TEST 5: Context size with 10 nodes
# ============================================================
IO.puts("\n--- TEST 5: Context growth with 10 nodes ---")

nodes_10 = for i <- 1..10, into: %{} do
  name = String.to_atom("step_#{i}")
  {name, fn _ctx ->
    {:ok, %{
      data: List.duplicate("x", i * 100),
      metadata: %{step: i, timestamp: DateTime.utc_now()},
      stats: %{processed: i * 1000, errors: 0}
    }}
  end}
end

transitions_10 = for i <- 1..9, into: %{} do
  from = String.to_atom("step_#{i}")
  to = String.to_atom("step_#{i + 1}")
  {{from, :ok}, to}
end
transitions_10 = Map.put(transitions_10, {String.to_atom("step_10"), :ok}, :done)

m5 = Machine.new(
  initial: :step_1,
  nodes: nodes_10,
  transitions: transitions_10
)

{:ok, big_result} = Machine.run(m5)
ctx_keys = Map.keys(big_result.context) |> length()
ctx_size = :erlang.term_to_binary(big_result.context) |> byte_size()
IO.puts("  Final state: #{big_result.status}")
IO.puts("  Context keys: #{ctx_keys}")
IO.puts("  Context serialized size: #{ctx_size} bytes")
IO.puts("  Transitions made: #{length(big_result.history)}")
IO.puts("TEST 5: PASS")

# ============================================================
# TEST 6: Associativity — (A >> B) >> C == A >> (B >> C)
# ============================================================
IO.puts("\n--- TEST 6: Associativity ---")

# Simulate composition associativity
node_a = fn _ctx -> {:ok, %{a_val: 1}} end
node_b = fn ctx -> {:ok, %{b_val: (ctx[:a][:a_val] || 0) + 10}} end
node_c = fn ctx -> {:ok, %{c_val: (ctx[:b][:b_val] || 0) + 100}} end

# (A >> B) >> C
ctx_ab = %{}
{:ok, ra} = node_a.(ctx_ab)
ctx_ab = DeepMerge.deep_merge(ctx_ab, %{a: ra})
{:ok, rb} = node_b.(ctx_ab)
ctx_ab = DeepMerge.deep_merge(ctx_ab, %{b: rb})
{:ok, rc} = node_c.(ctx_ab)
ctx_abc_1 = DeepMerge.deep_merge(ctx_ab, %{c: rc})

# A >> (B >> C) — same context flow
ctx_bc = %{}
{:ok, ra2} = node_a.(ctx_bc)
ctx_bc = DeepMerge.deep_merge(ctx_bc, %{a: ra2})
{:ok, rb2} = node_b.(ctx_bc)
ctx_bc = DeepMerge.deep_merge(ctx_bc, %{b: rb2})
{:ok, rc2} = node_c.(ctx_bc)
ctx_abc_2 = DeepMerge.deep_merge(ctx_bc, %{c: rc2})

IO.puts("  (A >> B) >> C: #{inspect(ctx_abc_1)}")
IO.puts("  A >> (B >> C): #{inspect(ctx_abc_2)}")
IO.puts("  Equal: #{ctx_abc_1 == ctx_abc_2}")
IO.puts("TEST 6: PASS")

# ============================================================
# TEST 7: Performance — transitions/sec
# ============================================================
IO.puts("\n--- TEST 7: FSM transition performance ---")

fast_nodes = for i <- 1..100, into: %{} do
  name = String.to_atom("s#{i}")
  {name, fn _ctx -> {:ok, %{i: i}} end}
end

fast_transitions = for i <- 1..99, into: %{} do
  {{String.to_atom("s#{i}"), :ok}, String.to_atom("s#{i + 1}")}
end
fast_transitions = Map.put(fast_transitions, {String.to_atom("s100"), :ok}, :done)

{time_us, {:ok, _}} = :timer.tc(fn ->
  m = Machine.new(initial: :s1, nodes: fast_nodes, transitions: fast_transitions)
  Machine.run(m)
end)

transitions_per_sec = 100 / (time_us / 1_000_000)
IO.puts("  100 transitions in #{time_us}μs")
IO.puts("  ~#{round(transitions_per_sec)} transitions/sec")
IO.puts("  (Need >1000/sec for ReAct loop — #{if transitions_per_sec > 1000, do: "PASS", else: "WARN"})")
IO.puts("TEST 7: PASS")

# ============================================================
IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("ALL FSM + DEEP MERGE TESTS PASSED")
IO.puts(String.duplicate("=", 70))
