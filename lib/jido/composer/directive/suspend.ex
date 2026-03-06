defmodule Jido.Composer.Directive.Suspend do
  @moduledoc """
  Generalized suspend directive emitted by strategies when a flow suspends.

  The runtime interprets this directive to:

  1. Deliver the notification through the configured channel
  2. Optionally start a timeout timer via a Schedule directive
  3. Optionally hibernate the agent for long-pause resource management
  """

  alias Jido.Composer.Suspension

  @enforce_keys [:suspension]
  defstruct [:suspension, :notification, hibernate: false]

  @type t :: %__MODULE__{
          suspension: Suspension.t(),
          notification: term() | nil,
          hibernate: boolean() | map()
        }
end
