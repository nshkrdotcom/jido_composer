defmodule Jido.ComposerTest do
  use ExUnit.Case

  test "module exists" do
    assert Code.ensure_loaded?(Jido.Composer)
  end
end
