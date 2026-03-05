defmodule Jido.Composer.Error do
  @moduledoc """
  Structured error types for Jido Composer using Splode.

  ## Error Classes

  | Class            | Use Case                              |
  |------------------|---------------------------------------|
  | `:invalid`       | Validation and configuration errors   |
  | `:transition`    | FSM transition failures               |
  | `:execution`     | Node execution failures               |
  | `:orchestration` | LLM/tool interaction errors           |
  """

  defmodule Invalid do
    @moduledoc false
    use Splode.ErrorClass, class: :invalid
  end

  defmodule Transition do
    @moduledoc false
    use Splode.ErrorClass, class: :transition
  end

  defmodule Execution do
    @moduledoc false
    use Splode.ErrorClass, class: :execution
  end

  defmodule Orchestration do
    @moduledoc false
    use Splode.ErrorClass, class: :orchestration
  end

  defmodule Unknown do
    @moduledoc false
    use Splode.ErrorClass, class: :unknown

    defmodule UnknownError do
      @moduledoc false
      use Splode.Error, fields: [:error, :details], class: :unknown

      def message(%{error: error}) when is_binary(error), do: error
      def message(_), do: "Unknown composer error"
    end
  end

  use Splode,
    error_classes: [
      invalid: Invalid,
      transition: Transition,
      execution: Execution,
      orchestration: Orchestration,
      unknown: Unknown
    ],
    unknown_error: Unknown.UnknownError

  # --- Error Structs ---

  defmodule ValidationError do
    @moduledoc false
    use Splode.Error, fields: [:msg, :details], class: :invalid

    def message(%{msg: msg}) when is_binary(msg), do: msg
    def message(_), do: "Validation failed"
  end

  defmodule TransitionError do
    @moduledoc false
    use Splode.Error, fields: [:msg, :state, :outcome, :details], class: :transition

    def message(%{msg: msg}) when is_binary(msg), do: msg
    def message(_), do: "Transition failed"
  end

  defmodule ExecutionError do
    @moduledoc false
    use Splode.Error, fields: [:msg, :node, :details], class: :execution

    def message(%{msg: msg}) when is_binary(msg), do: msg
    def message(_), do: "Execution failed"
  end

  defmodule OrchestrationError do
    @moduledoc false
    use Splode.Error, fields: [:msg, :details], class: :orchestration

    def message(%{msg: msg}) when is_binary(msg), do: msg
    def message(_), do: "Orchestration failed"
  end

  # --- Constructors ---

  @spec validation_error(String.t(), keyword()) :: ValidationError.t()
  def validation_error(message, opts \\ []) do
    ValidationError.exception(
      msg: message,
      details: Keyword.get(opts, :details, %{})
    )
  end

  @spec transition_error(String.t(), keyword()) :: TransitionError.t()
  def transition_error(message, opts \\ []) do
    TransitionError.exception(
      msg: message,
      state: Keyword.get(opts, :state),
      outcome: Keyword.get(opts, :outcome),
      details: Keyword.get(opts, :details, %{})
    )
  end

  @spec execution_error(String.t(), keyword()) :: ExecutionError.t()
  def execution_error(message, opts \\ []) do
    ExecutionError.exception(
      msg: message,
      node: Keyword.get(opts, :node),
      details: Keyword.get(opts, :details, %{})
    )
  end

  @spec orchestration_error(String.t(), keyword()) :: OrchestrationError.t()
  def orchestration_error(message, opts \\ []) do
    OrchestrationError.exception(
      msg: message,
      details: Keyword.get(opts, :details, %{})
    )
  end
end
