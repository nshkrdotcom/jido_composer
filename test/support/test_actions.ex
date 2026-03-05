defmodule Jido.Composer.TestActions do
  @moduledoc false

  defmodule AddAction do
    @moduledoc false
    use Jido.Action,
      name: "add",
      description: "Adds an amount to a value",
      schema: [
        value: [type: :float, required: true, doc: "The current value"],
        amount: [type: :float, required: true, doc: "The amount to add"]
      ]

    def run(%{value: value, amount: amount}, _context) do
      {:ok, %{result: value + amount}}
    end
  end

  defmodule MultiplyAction do
    @moduledoc false
    use Jido.Action,
      name: "multiply",
      description: "Multiplies a value by an amount",
      schema: [
        value: [type: :float, required: true, doc: "The current value"],
        amount: [type: :float, required: true, doc: "The multiplier"]
      ]

    def run(%{value: value, amount: amount}, _context) do
      {:ok, %{result: value * amount}}
    end
  end

  defmodule FailAction do
    @moduledoc false
    use Jido.Action,
      name: "fail",
      description: "Always fails with an error",
      schema: [
        reason: [type: :string, required: false, doc: "The failure reason"]
      ]

    def run(params, _context) do
      {:error, Map.get(params, :reason, "intentional failure")}
    end
  end

  defmodule SlowAction do
    @moduledoc false
    use Jido.Action,
      name: "slow",
      description: "Simulates a slow operation",
      schema: [
        delay_ms: [type: :pos_integer, required: true, doc: "Delay in milliseconds"],
        value: [type: :any, required: false, doc: "Value to return"]
      ]

    def run(%{delay_ms: delay} = params, _context) do
      Process.sleep(delay)
      {:ok, %{result: Map.get(params, :value, :done)}}
    end
  end

  defmodule NoopAction do
    @moduledoc false
    use Jido.Action,
      name: "noop",
      description: "Does nothing, returns empty result",
      schema: []

    def run(_params, _context) do
      {:ok, %{}}
    end
  end

  defmodule EchoAction do
    @moduledoc false
    use Jido.Action,
      name: "echo",
      description: "Echoes input params as the result",
      schema: [
        message: [type: :string, required: true, doc: "Message to echo"]
      ]

    def run(%{message: message}, _context) do
      {:ok, %{echoed: message}}
    end
  end
end
