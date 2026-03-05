defmodule Jido.Composer.Node do
  @moduledoc """
  Uniform context-in/context-out interface for workflow participants.

  Every participant in a composition — actions, agents, nested workflows —
  implements this behaviour. Nodes form an endomorphism monoid over context
  maps, composed via Kleisli arrows.

  ## Return Types

  - `{:ok, context}` — success with implicit outcome `:ok`
  - `{:ok, context, outcome}` — success with explicit outcome for FSM transitions
  - `{:error, reason}` — failure with implicit outcome `:error`
  """

  @type context :: map()
  @type outcome :: atom()
  @type result :: {:ok, context()} | {:ok, context(), outcome()} | {:error, term()}

  @callback run(context :: context(), opts :: keyword()) :: result()
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback schema() :: keyword() | nil
end
