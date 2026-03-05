defmodule Jido.Composer.NodeTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Node

  defmodule ValidNode do
    @behaviour Node

    @impl Node
    def run(context, _opts), do: {:ok, Map.put(context, :ran, true)}

    @impl Node
    def name, do: "valid_node"

    @impl Node
    def description, do: "A test node"

    @impl Node
    def schema, do: [input: [type: :string, required: true]]
  end

  defmodule OutcomeNode do
    @behaviour Node

    @impl Node
    def run(context, _opts), do: {:ok, context, :custom_outcome}

    @impl Node
    def name, do: "outcome_node"

    @impl Node
    def description, do: "Returns explicit outcome"

    @impl Node
    def schema, do: nil
  end

  defmodule ErrorNode do
    @behaviour Node

    @impl Node
    def run(_context, _opts), do: {:error, "something went wrong"}

    @impl Node
    def name, do: "error_node"

    @impl Node
    def description, do: "Always errors"

    @impl Node
    def schema, do: nil
  end

  describe "behaviour contract" do
    test "module implementing Node can return {:ok, context}" do
      assert {:ok, %{ran: true}} = ValidNode.run(%{}, [])
    end

    test "module implementing Node can return {:ok, context, outcome}" do
      assert {:ok, %{}, :custom_outcome} = OutcomeNode.run(%{}, [])
    end

    test "module implementing Node can return {:error, reason}" do
      assert {:error, "something went wrong"} = ErrorNode.run(%{}, [])
    end

    test "name/0 returns a string" do
      assert is_binary(ValidNode.name())
    end

    test "description/0 returns a string" do
      assert is_binary(ValidNode.description())
    end

    test "schema/0 returns keyword list or nil" do
      assert is_list(ValidNode.schema())
      assert is_nil(OutcomeNode.schema())
    end
  end

  describe "compiler enforcement" do
    test "behaviour defines all required callbacks" do
      callbacks = Node.behaviour_info(:callbacks)
      assert {:run, 2} in callbacks
      assert {:name, 0} in callbacks
      assert {:description, 0} in callbacks
      assert {:schema, 0} in callbacks
    end
  end
end
