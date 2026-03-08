defmodule Jido.Composer.Children do
  @moduledoc """
  Typed sub-state for tracking child agent references and their lifecycle phases.

  Replaces the flat `children: %{}` + `child_phases: %{}` maps that were
  previously stored directly in both Workflow and Orchestrator strategy state.
  """

  alias Jido.Composer.ChildRef

  @derive Jason.Encoder

  defstruct refs: %{},
            phases: %{}

  @type t :: %__MODULE__{
          refs: %{term() => ChildRef.t()},
          phases: %{term() => :spawning | :awaiting_result}
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Register a child that has started (child_started signal)."
  @spec register_started(t(), term(), keyword()) :: t()
  def register_started(%__MODULE__{} = children, tag, child_ref_params) do
    child_ref =
      ChildRef.new(
        Keyword.merge(child_ref_params,
          tag: tag,
          status: :running,
          phase: :awaiting_result
        )
      )

    %{
      children
      | refs: Map.put(children.refs, tag, child_ref),
        phases: Map.put(children.phases, tag, :awaiting_result)
    }
  end

  @doc "Record that a child produced a result (child_result signal)."
  @spec record_result(t(), term()) :: t()
  def record_result(%__MODULE__{} = children, tag) do
    new_refs =
      case Map.get(children.refs, tag) do
        nil -> children.refs
        ref -> Map.put(children.refs, tag, %{ref | phase: nil})
      end

    %{children | refs: new_refs, phases: Map.delete(children.phases, tag)}
  end

  @doc "Record that a child process exited."
  @spec record_exit(t(), term(), term()) :: t()
  def record_exit(%__MODULE__{} = children, tag, reason) do
    exit_status = if reason == :normal, do: :completed, else: :failed

    new_refs =
      Map.update(children.refs, tag, nil, fn ref ->
        %{ref | status: exit_status}
      end)

    %{children | refs: new_refs}
  end

  @doc "Record that a child has hibernated (checkpoint)."
  @spec record_hibernation(t(), term(), term(), String.t() | nil) :: t()
  def record_hibernation(%__MODULE__{} = children, tag, checkpoint_key, suspension_id) do
    new_refs =
      Map.update(children.refs, tag, nil, fn ref ->
        %{ref | status: :paused, checkpoint_key: checkpoint_key, suspension_id: suspension_id}
      end)

    %{children | refs: new_refs}
  end

  @doc "Set the phase for a child tag."
  @spec set_phase(t(), term(), :spawning | :awaiting_result) :: t()
  def set_phase(%__MODULE__{} = children, tag, phase) do
    %{children | phases: Map.put(children.phases, tag, phase)}
  end

  @doc "Merge multiple phase entries at once."
  @spec merge_phases(t(), %{term() => :spawning | :awaiting_result}) :: t()
  def merge_phases(%__MODULE__{} = children, phase_map) do
    %{children | phases: Map.merge(children.phases, phase_map)}
  end

  @doc "Get the ChildRef for a given tag."
  @spec get_ref(t(), term()) :: ChildRef.t() | nil
  def get_ref(%__MODULE__{} = children, tag) do
    Map.get(children.refs, tag)
  end

  @doc "Returns all ChildRefs with status :paused."
  @spec paused_refs(t()) :: [{term(), ChildRef.t()}]
  def paused_refs(%__MODULE__{} = children) do
    Enum.filter(children.refs, fn {_tag, ref} -> ref.status == :paused end)
  end

  @doc "Returns tags of children in :spawning phase."
  @spec spawning_tags(t()) :: [term()]
  def spawning_tags(%__MODULE__{} = children) do
    children.phases
    |> Enum.filter(fn {_tag, phase} -> phase == :spawning end)
    |> Enum.map(fn {tag, _} -> tag end)
  end
end
