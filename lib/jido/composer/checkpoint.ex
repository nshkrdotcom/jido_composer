defmodule Jido.Composer.Checkpoint do
  @moduledoc """
  Checkpoint preparation and restore for Composer strategy state.

  Before persisting strategy state, closures must be stripped since they
  cannot be serialized. On restore, they are reattached from the agent
  module's DSL configuration (`strategy_opts`).

  ## Schema Version

  Current checkpoint schema is `:composer_v2`. Migration from v1 adds
  the `children` field (empty map default).
  """

  @schema_version :composer_v2

  @doc """
  Returns the current checkpoint schema version.
  """
  @spec schema_version() :: atom()
  def schema_version, do: @schema_version

  @doc """
  Prepares strategy state for checkpoint by stripping non-serializable
  values (closures/functions) from top-level fields.
  """
  @spec prepare_for_checkpoint(map()) :: map()
  def prepare_for_checkpoint(strategy_state) when is_map(strategy_state) do
    Map.new(strategy_state, fn {key, value} ->
      if is_function(value) do
        {key, nil}
      else
        {key, value}
      end
    end)
  end

  @doc """
  Reattaches runtime configuration (closures) from strategy_opts.

  Only restores values that are currently nil in the checkpoint state.
  """
  @spec reattach_runtime_config(map(), keyword()) :: map()
  def reattach_runtime_config(checkpoint_state, strategy_opts) when is_map(checkpoint_state) do
    Enum.reduce(strategy_opts, checkpoint_state, fn {key, value}, acc ->
      if is_function(value) and Map.get(acc, key) == nil do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  @doc """
  Migrates checkpoint state from an older schema version to the current one.
  """
  @spec migrate(map(), pos_integer()) :: map()
  def migrate(state, version)

  def migrate(state, 1) do
    state
    |> Map.put_new(:children, %{})
    |> migrate(2)
  end

  def migrate(state, 2), do: state
end
