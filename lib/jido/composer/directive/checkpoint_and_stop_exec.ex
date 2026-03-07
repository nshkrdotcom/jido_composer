defimpl Jido.AgentServer.DirectiveExec, for: Jido.Composer.Directive.CheckpointAndStop do
  @moduledoc false

  require Logger

  alias Jido.AgentServer.ParentRef

  def exec(%{suspension: suspension, storage_config: storage_config}, _input_signal, state) do
    storage = resolve_storage(storage_config, state)
    persist_checkpoint(storage, state)
    notify_parent(suspension, state)
    {:stop, {:shutdown, :hibernated}, state}
  end

  defp resolve_storage(config, _state) when not is_nil(config), do: config

  defp resolve_storage(nil, %{lifecycle: %{storage: storage}}) when not is_nil(storage),
    do: storage

  defp resolve_storage(nil, _state), do: nil

  defp persist_checkpoint(nil, state) do
    Logger.warning(
      "CheckpointAndStop: no storage configured for agent #{state.id}, skipping checkpoint"
    )
  end

  defp persist_checkpoint(storage, state) do
    case Jido.Persist.hibernate(storage, state.agent) do
      :ok ->
        Logger.debug("CheckpointAndStop: checkpoint persisted for agent #{state.id}")

      {:error, reason} ->
        Logger.error(
          "CheckpointAndStop: failed to persist checkpoint for agent #{state.id}: #{inspect(reason)}"
        )
    end
  end

  defp notify_parent(suspension, %{parent: %ParentRef{pid: pid}} = state)
       when is_pid(pid) do
    signal =
      Jido.Signal.new!(
        "composer.child.hibernated",
        %{
          tag: state.parent.tag,
          checkpoint_key: {state.agent_module, state.id},
          suspension_id: suspension.id
        },
        source: "/agent/#{state.id}"
      )

    _ = Jido.AgentServer.cast(pid, signal)
    :ok
  end

  defp notify_parent(_suspension, state) do
    Logger.debug(
      "CheckpointAndStop: no parent available for agent #{state.id}, skipping notification"
    )
  end
end
