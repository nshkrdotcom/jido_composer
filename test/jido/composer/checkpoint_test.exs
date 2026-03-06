defmodule Jido.Composer.CheckpointTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Checkpoint
  alias Jido.Composer.Context

  describe "prepare_for_checkpoint/1" do
    test "strips closures (approval_policy → nil)" do
      strategy_state = %{
        module: Jido.Composer.Orchestrator.Strategy,
        status: :awaiting_approval,
        approval_policy: fn _call, _ctx -> :require_approval end,
        nodes: %{"echo" => %{name: "echo"}},
        conversation: [%{role: "user", content: "hello"}],
        context: %{foo: "bar"}
      }

      cleaned = Checkpoint.prepare_for_checkpoint(strategy_state)
      assert cleaned.approval_policy == nil
      assert cleaned.status == :awaiting_approval
      assert cleaned.nodes == %{"echo" => %{name: "echo"}}
      assert cleaned.conversation == [%{role: "user", content: "hello"}]
    end

    test "preserves serializable state" do
      machine = %{
        status: :approval,
        context: Context.new(working: %{tag: "test"}),
        nodes: %{},
        transitions: %{},
        terminal_states: MapSet.new([:done, :failed]),
        history: [{:process, :ok, 12_345}]
      }

      strategy_state = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :waiting,
        machine: machine,
        pending_suspension: %{id: "suspend-abc", reason: :human_input},
        pending_fan_out: nil,
        pending_child: nil,
        child_request_id: nil,
        ambient_keys: [:tenant_id],
        fork_fns: %{}
      }

      cleaned = Checkpoint.prepare_for_checkpoint(strategy_state)

      assert cleaned.machine.status == :approval
      assert cleaned.pending_suspension.id == "suspend-abc"
      assert cleaned.ambient_keys == [:tenant_id]

      # Must be fully serializable
      binary = :erlang.term_to_binary(cleaned, [:compressed])
      restored = :erlang.binary_to_term(binary)
      assert restored.machine.status == :approval
    end

    test "strips any closure values at top level" do
      strategy_state = %{
        module: Jido.Composer.Orchestrator.Strategy,
        status: :running,
        approval_policy: &is_atom/1,
        some_other_fn: fn -> :nope end,
        data: "keep me"
      }

      cleaned = Checkpoint.prepare_for_checkpoint(strategy_state)
      assert cleaned.approval_policy == nil
      assert cleaned.some_other_fn == nil
      assert cleaned.data == "keep me"
    end
  end

  describe "reattach_runtime_config/2" do
    test "restores closures from strategy_opts" do
      policy_fn = fn _call, _ctx -> :require_approval end

      strategy_opts = [
        approval_policy: policy_fn,
        nodes: [SomeModule],
        model: "test-model"
      ]

      checkpoint_state = %{
        module: Jido.Composer.Orchestrator.Strategy,
        status: :awaiting_approval,
        approval_policy: nil,
        nodes: %{},
        context: %{}
      }

      restored = Checkpoint.reattach_runtime_config(checkpoint_state, strategy_opts)
      assert restored.approval_policy == policy_fn
    end

    test "does not overwrite existing non-nil values" do
      existing_fn = fn _call, _ctx -> :existing end
      new_fn = fn _call, _ctx -> :new end

      strategy_opts = [approval_policy: new_fn]

      checkpoint_state = %{
        approval_policy: existing_fn,
        status: :running
      }

      restored = Checkpoint.reattach_runtime_config(checkpoint_state, strategy_opts)
      # The existing non-nil value should be preserved
      assert restored.approval_policy == existing_fn
    end

    test "restores nil closures from strategy_opts" do
      policy_fn = fn _call, _ctx -> :ok end

      strategy_opts = [approval_policy: policy_fn]
      checkpoint_state = %{approval_policy: nil, status: :waiting}

      restored = Checkpoint.reattach_runtime_config(checkpoint_state, strategy_opts)
      assert restored.approval_policy == policy_fn
    end
  end

  describe "migrate/2" do
    test "v1 → v2 adds :children field" do
      v1_state = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :running,
        machine: %{status: :process}
      }

      migrated = Checkpoint.migrate(v1_state, 1)
      assert migrated.children == %{}
      # Original fields preserved
      assert migrated.module == Jido.Composer.Workflow.Strategy
      assert migrated.status == :running
      assert migrated.machine == %{status: :process}
    end

    test "v1 → v2 does not overwrite existing :children" do
      v1_state = %{
        status: :running,
        children: %{child1: :ref}
      }

      migrated = Checkpoint.migrate(v1_state, 1)
      assert migrated.children == %{child1: :ref}
    end

    test "v2 is a no-op for current version" do
      v2_state = %{
        status: :running,
        children: %{},
        machine: %{status: :done}
      }

      assert Checkpoint.migrate(v2_state, 2) == v2_state
    end
  end

  describe "checkpoint schema version" do
    test "checkpoint schema version is :composer_v2" do
      assert Checkpoint.schema_version() == :composer_v2
    end
  end
end
