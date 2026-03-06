defmodule Jido.Composer.ChildRefTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.ChildRef

  describe "new/1" do
    test "creates ChildRef with required fields" do
      ref = ChildRef.new(agent_module: SomeModule, agent_id: "child-1", tag: :worker)

      assert ref.agent_module == SomeModule
      assert ref.agent_id == "child-1"
      assert ref.tag == :worker
      assert ref.status == :running
      assert ref.checkpoint_key == nil
      assert ref.suspension_id == nil
    end

    test "creates ChildRef with all fields" do
      ref =
        ChildRef.new(
          agent_module: SomeModule,
          agent_id: "child-2",
          tag: :etl,
          checkpoint_key: {"store", "child-2"},
          status: :paused,
          suspension_id: "suspend-xyz"
        )

      assert ref.agent_module == SomeModule
      assert ref.agent_id == "child-2"
      assert ref.tag == :etl
      assert ref.checkpoint_key == {"store", "child-2"}
      assert ref.status == :paused
      assert ref.suspension_id == "suspend-xyz"
    end
  end

  describe "suspension_id field" do
    test "includes suspension_id field" do
      ref =
        ChildRef.new(
          agent_module: SomeModule,
          agent_id: "child-3",
          tag: :worker,
          suspension_id: "suspend-abc"
        )

      assert ref.suspension_id == "suspend-abc"
    end

    test "suspension_id defaults to nil" do
      ref = ChildRef.new(agent_module: SomeModule, agent_id: "child-4", tag: :t)
      assert ref.suspension_id == nil
    end
  end

  describe "status transitions" do
    test ":running → :paused → :completed" do
      ref = ChildRef.new(agent_module: SomeModule, agent_id: "c1", tag: :t)
      assert ref.status == :running

      paused = %{ref | status: :paused}
      assert paused.status == :paused

      completed = %{paused | status: :completed}
      assert completed.status == :completed
    end

    test ":running → :failed" do
      ref = ChildRef.new(agent_module: SomeModule, agent_id: "c2", tag: :t)
      failed = %{ref | status: :failed}
      assert failed.status == :failed
    end
  end

  describe "Jason encoding" do
    test "is Jason encodable" do
      ref =
        ChildRef.new(
          agent_module: SomeModule,
          agent_id: "child-json",
          tag: :worker,
          checkpoint_key: "ck-1",
          suspension_id: "suspend-1"
        )

      assert {:ok, json} = Jason.encode(ref)
      assert is_binary(json)

      decoded = Jason.decode!(json)
      assert decoded["agent_id"] == "child-json"
      assert decoded["status"] == "running"
      assert decoded["suspension_id"] == "suspend-1"
    end
  end

  describe "backward compatibility" do
    test "Jido.Composer.HITL.ChildRef still works as alias" do
      ref =
        Jido.Composer.HITL.ChildRef.new(
          agent_module: SomeModule,
          agent_id: "compat-1",
          tag: :t
        )

      assert ref.__struct__ == Jido.Composer.ChildRef
    end
  end
end
