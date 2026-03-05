defmodule Jido.Composer.ErrorTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Error

  describe "validation_error/2" do
    test "creates a validation error with message" do
      error = Error.validation_error("invalid node config")
      assert %Error.ValidationError{} = error
      assert Exception.message(error) =~ "invalid node config"
    end

    test "creates a validation error with details" do
      error = Error.validation_error("bad schema", details: %{field: :name})
      assert error.details == %{field: :name}
    end

    test "has :invalid error class" do
      error = Error.validation_error("test")
      assert error.class == :invalid
    end
  end

  describe "transition_error/2" do
    test "creates a transition error with state and outcome" do
      error = Error.transition_error("no transition found", state: :extract, outcome: :ok)
      assert %Error.TransitionError{} = error
      assert Exception.message(error) =~ "no transition found"
      assert error.state == :extract
      assert error.outcome == :ok
    end

    test "has :transition error class" do
      error = Error.transition_error("test")
      assert error.class == :transition
    end
  end

  describe "execution_error/2" do
    test "creates an execution error with node info" do
      error = Error.execution_error("node failed", node: "add_action")
      assert %Error.ExecutionError{} = error
      assert Exception.message(error) =~ "node failed"
      assert error.node == "add_action"
    end

    test "has :execution error class" do
      error = Error.execution_error("test")
      assert error.class == :execution
    end
  end

  describe "orchestration_error/2" do
    test "creates an orchestration error" do
      error = Error.orchestration_error("LLM call failed", details: %{status: 500})
      assert %Error.OrchestrationError{} = error
      assert Exception.message(error) =~ "LLM call failed"
      assert error.details == %{status: 500}
    end

    test "has :orchestration error class" do
      error = Error.orchestration_error("test")
      assert error.class == :orchestration
    end
  end

  describe "communication_error/2" do
    test "creates a communication error" do
      error = Error.communication_error("signal delivery failed", details: %{timeout: 5000})
      assert %Error.CommunicationError{} = error
      assert Exception.message(error) =~ "signal delivery failed"
      assert error.details == %{timeout: 5000}
    end

    test "has :communication error class" do
      error = Error.communication_error("test")
      assert error.class == :communication
    end
  end

  describe "Splode integration" do
    test "errors are Splode-compatible exceptions" do
      error = Error.validation_error("test")
      assert is_exception(error)
      assert Error.splode_error?(error)
    end

    test "to_class aggregates errors" do
      errors = [
        Error.validation_error("error 1"),
        Error.validation_error("error 2")
      ]

      class = Error.to_class(errors)
      assert is_exception(class)
    end
  end
end
