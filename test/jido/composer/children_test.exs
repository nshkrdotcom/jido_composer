defmodule Jido.Composer.ChildrenTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Children
  alias Jido.Composer.ChildRef

  describe "new/0" do
    test "creates empty children state" do
      children = Children.new()
      assert children.refs == %{}
      assert children.phases == %{}
    end
  end

  describe "register_started/3" do
    test "adds a ChildRef with :running status and :awaiting_result phase" do
      children = Children.new()

      children =
        Children.register_started(children, :worker,
          agent_module: SomeModule,
          agent_id: "child-1"
        )

      assert %ChildRef{} = ref = children.refs[:worker]
      assert ref.agent_module == SomeModule
      assert ref.agent_id == "child-1"
      assert ref.tag == :worker
      assert ref.status == :running
      assert ref.phase == :awaiting_result
      assert children.phases[:worker] == :awaiting_result
    end
  end

  describe "record_result/2" do
    test "clears phase for existing child" do
      children =
        Children.new()
        |> Children.register_started(:worker,
          agent_module: SomeModule,
          agent_id: "child-1"
        )
        |> Children.record_result(:worker)

      assert children.refs[:worker].phase == nil
      refute Map.has_key?(children.phases, :worker)
    end

    test "no-op for unknown tag" do
      children = Children.new() |> Children.record_result(:unknown)
      assert children.refs == %{}
    end
  end

  describe "record_exit/3" do
    test "normal exit sets :completed" do
      children =
        Children.new()
        |> Children.register_started(:worker,
          agent_module: SomeModule,
          agent_id: "child-1"
        )
        |> Children.record_exit(:worker, :normal)

      assert children.refs[:worker].status == :completed
    end

    test "abnormal exit sets :failed" do
      children =
        Children.new()
        |> Children.register_started(:worker,
          agent_module: SomeModule,
          agent_id: "child-1"
        )
        |> Children.record_exit(:worker, {:error, :crashed})

      assert children.refs[:worker].status == :failed
    end
  end

  describe "record_hibernation/4" do
    test "sets status to :paused with checkpoint data" do
      children =
        Children.new()
        |> Children.register_started(:worker,
          agent_module: SomeModule,
          agent_id: "child-1"
        )
        |> Children.record_hibernation(:worker, "ck-1", "sus-1")

      ref = children.refs[:worker]
      assert ref.status == :paused
      assert ref.checkpoint_key == "ck-1"
      assert ref.suspension_id == "sus-1"
    end
  end

  describe "set_phase/3" do
    test "sets phase for a tag" do
      children = Children.new() |> Children.set_phase(:worker, :spawning)
      assert children.phases[:worker] == :spawning
    end
  end

  describe "merge_phases/2" do
    test "merges multiple phases" do
      children =
        Children.new()
        |> Children.merge_phases(%{a: :spawning, b: :awaiting_result})

      assert children.phases[:a] == :spawning
      assert children.phases[:b] == :awaiting_result
    end
  end

  describe "paused_refs/1" do
    test "returns only paused children" do
      children =
        Children.new()
        |> Children.register_started(:running,
          agent_module: A,
          agent_id: "1"
        )
        |> Children.register_started(:paused,
          agent_module: B,
          agent_id: "2"
        )
        |> Children.record_hibernation(:paused, "ck", "sus")

      paused = Children.paused_refs(children)
      assert length(paused) == 1
      [{:paused, ref}] = paused
      assert ref.status == :paused
    end
  end

  describe "spawning_tags/1" do
    test "returns tags in :spawning phase" do
      children =
        Children.new()
        |> Children.set_phase(:a, :spawning)
        |> Children.set_phase(:b, :awaiting_result)
        |> Children.set_phase(:c, :spawning)

      tags = Children.spawning_tags(children) |> Enum.sort()
      assert tags == [:a, :c]
    end
  end

  describe "Jason encoding" do
    test "Children struct is JSON-encodable" do
      children =
        Children.new()
        |> Children.register_started(:worker,
          agent_module: SomeModule,
          agent_id: "child-1"
        )

      assert {:ok, _json} = Jason.encode(children)
    end
  end

  describe "term_to_binary round-trip" do
    test "survives serialization" do
      children =
        Children.new()
        |> Children.register_started(:worker,
          agent_module: SomeModule,
          agent_id: "child-1"
        )

      binary = :erlang.term_to_binary(children, [:compressed])
      restored = :erlang.binary_to_term(binary)

      assert %Children{} = restored
      assert %ChildRef{} = restored.refs[:worker]
      assert restored.refs[:worker].agent_module == SomeModule
    end
  end
end
