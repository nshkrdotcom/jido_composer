defmodule Jido.Composer.ApprovalGateTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.ApprovalGate
  alias Jido.Composer.Context

  describe "new/1" do
    test "creates default gate" do
      gate = ApprovalGate.new()
      assert gate.gated_node_names == MapSet.new()
      assert gate.approval_policy == nil
      assert gate.rejection_policy == :continue_siblings
      assert gate.gated_calls == %{}
    end

    test "creates gate with options" do
      gate =
        ApprovalGate.new(
          gated_nodes: ["add", "echo"],
          rejection_policy: :abort_iteration,
          approval_policy: fn _call, _ctx -> :require_approval end
        )

      assert MapSet.member?(gate.gated_node_names, "add")
      assert MapSet.member?(gate.gated_node_names, "echo")
      assert gate.rejection_policy == :abort_iteration
      assert is_function(gate.approval_policy, 2)
    end
  end

  describe "requires_approval?/3" do
    test "returns true for statically gated tool" do
      gate = ApprovalGate.new(gated_nodes: ["add"])
      call = %{name: "add", id: "c1", arguments: %{}}
      assert ApprovalGate.requires_approval?(gate, call, Context.new())
    end

    test "returns false for non-gated tool" do
      gate = ApprovalGate.new(gated_nodes: ["add"])
      call = %{name: "echo", id: "c1", arguments: %{}}
      refute ApprovalGate.requires_approval?(gate, call, Context.new())
    end

    test "uses dynamic policy" do
      gate =
        ApprovalGate.new(
          approval_policy: fn call, _ctx ->
            if call.name == "echo", do: :require_approval, else: :no
          end
        )

      assert ApprovalGate.requires_approval?(gate, %{name: "echo", id: "c1"}, Context.new())
      refute ApprovalGate.requires_approval?(gate, %{name: "add", id: "c2"}, Context.new())
    end

    test "returns false when no policy and no gating" do
      gate = ApprovalGate.new()
      refute ApprovalGate.requires_approval?(gate, %{name: "add", id: "c1"}, Context.new())
    end
  end

  describe "partition_calls/3" do
    test "splits calls into ungated and gated" do
      gate = ApprovalGate.new(gated_nodes: ["add"])

      calls = [
        %{name: "echo", id: "c1", arguments: %{"message" => "hi"}},
        %{name: "add", id: "c2", arguments: %{"value" => 1}}
      ]

      {:ok, ungated, gated} = ApprovalGate.partition_calls(gate, calls, Context.new())

      assert length(ungated) == 1
      assert hd(ungated).name == "echo"
      assert map_size(gated) == 1
      [{_req_id, entry}] = Map.to_list(gated)
      assert entry.call.name == "add"
      assert %Jido.Composer.HITL.ApprovalRequest{} = entry.request
    end

    test "all ungated when no gating configured" do
      gate = ApprovalGate.new()
      calls = [%{name: "add", id: "c1", arguments: %{}}]
      {:ok, ungated, gated} = ApprovalGate.partition_calls(gate, calls, Context.new())
      assert length(ungated) == 1
      assert gated == %{}
    end
  end

  describe "gate_calls/2" do
    test "stores gated entries" do
      gate = ApprovalGate.new()
      entries = %{"req1" => %{request: :r, call: :c}}
      gate = ApprovalGate.gate_calls(gate, entries)
      assert gate.gated_calls == entries
    end
  end

  describe "get/2 and remove/2" do
    test "retrieves and removes gated call" do
      gate = ApprovalGate.new()
      gate = ApprovalGate.gate_calls(gate, %{"req1" => %{request: :r, call: :c}})

      assert ApprovalGate.get(gate, "req1") == %{request: :r, call: :c}
      assert ApprovalGate.get(gate, "req2") == nil

      gate = ApprovalGate.remove(gate, "req1")
      assert gate.gated_calls == %{}
    end
  end

  describe "has_pending?/1" do
    test "false when no gated calls" do
      refute ApprovalGate.has_pending?(ApprovalGate.new())
    end

    test "true when gated calls exist" do
      gate = ApprovalGate.gate_calls(ApprovalGate.new(), %{"req1" => %{request: :r, call: :c}})
      assert ApprovalGate.has_pending?(gate)
    end
  end

  describe "serialization" do
    test "survives term_to_binary round-trip (policy stripped)" do
      gate =
        ApprovalGate.new(
          gated_nodes: ["add"],
          rejection_policy: :cancel_siblings
        )

      gate = ApprovalGate.gate_calls(gate, %{"req1" => %{request: :r, call: :c}})

      binary = :erlang.term_to_binary(gate, [:compressed])
      restored = :erlang.binary_to_term(binary)

      assert %ApprovalGate{} = restored
      assert MapSet.member?(restored.gated_node_names, "add")
      assert restored.rejection_policy == :cancel_siblings
      assert map_size(restored.gated_calls) == 1
    end
  end
end
