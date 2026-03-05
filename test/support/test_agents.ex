defmodule Jido.Composer.TestAgents do
  @moduledoc false

  defmodule EchoAgent do
    @moduledoc false
    use Jido.Agent,
      name: "echo_agent",
      description: "Echoes incoming signal data as state",
      schema: [
        result: [type: :any, default: nil]
      ]
  end

  defmodule CounterAgent do
    @moduledoc false
    use Jido.Agent,
      name: "counter_agent",
      description: "Maintains a simple counter",
      schema: [
        count: [type: :integer, default: 0]
      ]
  end
end
