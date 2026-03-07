defimpl Jido.AgentServer.DirectiveExec, for: Jido.Composer.Directive.Suspend do
  @moduledoc """
  Executes the Suspend directive at runtime.

  The strategy has already handled the state transition by the time this executes.
  This impl handles the optional `hibernate` field:

  - `false` (default) — no-op, returns `{:ok, state}`
  - `true` — logs the hibernate intent but cannot force GenServer hibernate from
    a directive executor. The primary hibernate mechanism is `CheckpointAndStop`,
    which stops the process entirely.
  - `%{after: ms}` — same as `true`; logs intent with the requested delay.

  OTP GenServer hibernate requires returning `:hibernate` from a callback, which
  directive executors cannot do. True hibernate support would require AgentServer
  modifications. For resource management of long-paused agents, use the
  `CheckpointAndStop` directive instead, which persists state and stops the process.
  """

  require Logger

  def exec(%{hibernate: false}, _input_signal, state) do
    {:ok, state}
  end

  def exec(%{hibernate: true}, _input_signal, state) do
    Logger.info(
      "Suspend: hibernate requested for agent #{state.id} (no-op without AgentServer support)"
    )

    {:ok, state}
  end

  def exec(%{hibernate: %{after: ms}}, _input_signal, state) when is_integer(ms) and ms >= 0 do
    Logger.info(
      "Suspend: hibernate requested for agent #{state.id} after #{ms}ms (no-op without AgentServer support)"
    )

    {:ok, state}
  end

  def exec(%{hibernate: _other}, _input_signal, state) do
    {:ok, state}
  end
end
