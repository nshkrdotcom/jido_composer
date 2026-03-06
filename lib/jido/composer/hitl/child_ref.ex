defmodule Jido.Composer.HITL.ChildRef do
  @moduledoc """
  Backward-compatible alias for `Jido.Composer.ChildRef`.

  ChildRef has been promoted to a top-level Composer concept since
  any suspension reason (not just HITL) requires serializable child tracking.
  This module delegates to the new location for backward compatibility.
  """

  defdelegate new(attrs), to: Jido.Composer.ChildRef
end
