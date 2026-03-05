defmodule Jido.Composer.Node.ActionNodeTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.TestActions.{AddAction, FailAction, EchoAction, ValidateOutcomeAction}

  describe "new/2" do
    test "creates an ActionNode from a valid action module" do
      assert {:ok, node} = ActionNode.new(AddAction)
      assert %ActionNode{} = node
      assert node.action_module == AddAction
    end

    test "accepts options" do
      assert {:ok, node} = ActionNode.new(AddAction, timeout: 5000)
      assert node.opts == [timeout: 5000]
    end

    test "rejects non-action modules" do
      assert {:error, _reason} = ActionNode.new(String)
    end

    test "rejects non-existent modules" do
      assert {:error, _reason} = ActionNode.new(NonExistent.Module)
    end
  end

  describe "run/2" do
    test "executes the wrapped action and returns result" do
      {:ok, node} = ActionNode.new(AddAction)
      assert {:ok, %{result: 3.0}} = ActionNode.run(node, %{value: 1.0, amount: 2.0})
    end

    test "returns error when action fails" do
      {:ok, node} = ActionNode.new(FailAction)
      assert {:error, _reason} = ActionNode.run(node, %{})
    end

    test "passes context through to action" do
      {:ok, node} = ActionNode.new(EchoAction)
      assert {:ok, %{echoed: "hello"}} = ActionNode.run(node, %{message: "hello"})
    end

    test "propagates 3-tuple with custom outcome from action" do
      {:ok, node} = ActionNode.new(ValidateOutcomeAction)

      assert {:ok, %{validated: false, quality: :bad}, :invalid} =
               ActionNode.run(node, %{data: "invalid"})
    end

    test "propagates 3-tuple with :retry outcome from action" do
      {:ok, node} = ActionNode.new(ValidateOutcomeAction)

      assert {:ok, %{validated: false, quality: :unstable}, :retry} =
               ActionNode.run(node, %{data: "retry"})
    end

    test "returns plain {:ok, result} when action succeeds without outcome" do
      {:ok, node} = ActionNode.new(ValidateOutcomeAction)

      assert {:ok, %{validated: true, quality: :good}} =
               ActionNode.run(node, %{data: "valid"})
    end
  end

  describe "Node behaviour" do
    test "ActionNode declares Node behaviour" do
      behaviours =
        ActionNode.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Jido.Composer.Node in behaviours
    end
  end

  describe "metadata delegation" do
    test "name/1 delegates to action module" do
      {:ok, node} = ActionNode.new(AddAction)
      assert ActionNode.name(node) == "add"
    end

    test "description/1 delegates to action module" do
      {:ok, node} = ActionNode.new(AddAction)
      assert ActionNode.description(node) == "Adds an amount to a value"
    end

    test "schema/1 delegates to action module" do
      {:ok, node} = ActionNode.new(AddAction)
      schema = ActionNode.schema(node)
      assert is_list(schema)
      assert Keyword.has_key?(schema, :value)
    end
  end
end
