defmodule Jido.Composer.Orchestrator.Obs do
  @moduledoc """
  Observability state and span lifecycle for orchestrator strategies.

  Encapsulates all OTel span management, token accumulation, and LLM
  message normalization that was previously scattered across Strategy.
  Strategy stores a single `_obs: %Obs{} | nil` field instead of five
  separate `_obs_*` fields.
  """

  alias Jido.Composer.NodeIO

  defstruct agent_span: nil,
            llm_span: nil,
            tool_spans: %{},
            iteration_span: nil,
            cumulative_tokens: %{prompt: 0, completion: 0, total: 0}

  @type t :: %__MODULE__{
          agent_span: term() | nil,
          llm_span: term() | nil,
          tool_spans: %{optional(String.t()) => term()},
          iteration_span: term() | nil,
          cumulative_tokens: %{
            prompt: non_neg_integer(),
            completion: non_neg_integer(),
            total: non_neg_integer()
          }
        }

  # Telemetry event prefixes
  @agent_prefix [:jido, :composer, :agent]
  @llm_prefix [:jido, :composer, :llm]
  @tool_prefix [:jido, :composer, :tool]
  @iteration_prefix [:jido, :composer, :iteration]

  @doc "Returns a fresh Obs struct."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # -- Agent span --

  @spec start_agent_span(t(), map()) :: t()
  def start_agent_span(%__MODULE__{} = obs, metadata) do
    span_ctx = Jido.Observe.start_span(@agent_prefix, metadata)
    %{obs | agent_span: span_ctx}
  end

  @spec finish_agent_span(t(), map(), map()) :: t()
  def finish_agent_span(obs, state, extra \\ %{})
  def finish_agent_span(%__MODULE__{agent_span: nil} = obs, _state, _extra), do: obs

  def finish_agent_span(%__MODULE__{agent_span: span_ctx} = obs, state, extra) do
    measurements =
      Map.merge(
        %{
          result: unwrap_result(state[:result]),
          iterations: state[:iteration],
          status: state[:status]
        },
        extra
      )

    measurements =
      case obs.cumulative_tokens do
        %{total: total} when total > 0 ->
          Map.put(measurements, :tokens, obs.cumulative_tokens)

        _ ->
          measurements
      end

    measurements =
      if state[:status] == :error and not Map.has_key?(measurements, :error) do
        Map.put(measurements, :error, state[:result])
      else
        measurements
      end

    Jido.Observe.finish_span(span_ctx, measurements)
    %{obs | agent_span: nil}
  end

  # -- LLM span --

  @spec start_llm_span(t(), map()) :: t()
  def start_llm_span(%__MODULE__{} = obs, metadata) do
    span_ctx = Jido.Observe.start_span(@llm_prefix, metadata)
    %{obs | llm_span: span_ctx}
  end

  @spec finish_llm_span(t(), map()) :: t()
  def finish_llm_span(%__MODULE__{llm_span: nil} = obs, _measurements), do: obs

  def finish_llm_span(%__MODULE__{llm_span: span_ctx} = obs, measurements) do
    Jido.Observe.finish_span(span_ctx, measurements)
    %{obs | llm_span: nil}
  end

  # -- Tool spans --

  @spec start_tool_span(t(), map()) :: t()
  def start_tool_span(%__MODULE__{} = obs, call) do
    span_ctx =
      Jido.Observe.start_span(@tool_prefix, %{
        tool_name: call.name,
        name: call.name,
        call_id: call.id,
        arguments: call[:arguments]
      })

    %{obs | tool_spans: Map.put(obs.tool_spans, call.id, span_ctx)}
  end

  @spec finish_tool_span(t(), String.t(), map()) :: t()
  def finish_tool_span(%__MODULE__{} = obs, call_id, measurements) do
    case Map.get(obs.tool_spans, call_id) do
      nil ->
        obs

      span_ctx ->
        Jido.Observe.finish_span(span_ctx, measurements)
        %{obs | tool_spans: Map.delete(obs.tool_spans, call_id)}
    end
  end

  # -- Iteration span --

  @spec start_iteration_span(t(), map()) :: t()
  def start_iteration_span(%__MODULE__{} = obs, metadata) do
    span_ctx = Jido.Observe.start_span(@iteration_prefix, metadata)
    %{obs | iteration_span: span_ctx}
  end

  @spec finish_iteration_span(t(), map()) :: t()
  def finish_iteration_span(%__MODULE__{iteration_span: nil} = obs, _measurements), do: obs

  def finish_iteration_span(%__MODULE__{iteration_span: span_ctx} = obs, measurements) do
    Jido.Observe.finish_span(span_ctx, measurements)
    %{obs | iteration_span: nil}
  end

  # -- Token accumulation --

  @spec accumulate_tokens(t(), map()) :: t()
  def accumulate_tokens(%__MODULE__{} = obs, measurements) do
    case measurements[:tokens] do
      %{} = tokens ->
        cumulative = obs.cumulative_tokens

        %{
          obs
          | cumulative_tokens: %{
              prompt: (cumulative.prompt || 0) + (tokens[:prompt] || 0),
              completion: (cumulative.completion || 0) + (tokens[:completion] || 0),
              total: (cumulative.total || 0) + (tokens[:total] || 0)
            }
        }

      _ ->
        obs
    end
  end

  # -- LLM measurement extraction --

  @doc """
  Builds observability measurements from an LLM result instruction params.
  Extracts token usage, finish reason, and output messages from the ReqLLM
  response structures.
  """
  @spec build_llm_measurements(map()) :: map()
  def build_llm_measurements(params) do
    case params do
      %{status: :ok, result: %{} = result} ->
        usage = result[:usage]

        tokens =
          if usage do
            %{
              prompt: usage[:input_tokens],
              completion: usage[:output_tokens],
              total: usage[:total_tokens]
            }
          end

        output_messages = extract_output_messages(result[:conversation])

        %{}
        |> maybe_put(:tokens, tokens)
        |> maybe_put(:finish_reason, result[:finish_reason])
        |> maybe_put(:output_messages, output_messages)

      %{status: :error, result: %{error: reason}} ->
        %{error: reason}

      _ ->
        %{}
    end
  end

  @doc """
  Extracts input messages from a ReqLLM conversation context, normalizing
  them into plain maps suitable for OTel span attributes.
  """
  @spec extract_input_messages(term()) :: [map()] | nil
  def extract_input_messages(nil), do: nil

  def extract_input_messages(%ReqLLM.Context{messages: messages}) do
    Enum.map(messages, &normalize_message/1)
  end

  def extract_input_messages(_), do: nil

  @doc "Summarizes the conversation state for span metadata."
  @spec summarize_conversation(map()) :: String.t()
  def summarize_conversation(state) do
    cond do
      state.conversation == nil -> state.query || ""
      is_list(state.conversation) -> "iteration with #{length(state.conversation)} messages"
      true -> state.query || ""
    end
  end

  @doc "Extracts the agent name for obs span metadata."
  @spec agent_name(map()) :: String.t()
  def agent_name(agent) do
    case agent do
      %{name: name} when is_binary(name) -> name
      %{id: id} -> id
      _ -> "orchestrator"
    end
  end

  # -- Private helpers --

  defp extract_output_messages(nil), do: nil

  defp extract_output_messages(%ReqLLM.Context{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn msg -> msg.role == :assistant end)
    |> case do
      nil -> nil
      msg -> [normalize_message(msg)]
    end
  end

  defp extract_output_messages(_), do: nil

  defp normalize_message(msg) do
    content =
      case msg.content do
        parts when is_list(parts) ->
          Enum.map_join(parts, "\n", fn
            %{type: :text, text: text} -> text
            %{text: text} -> text
            other -> inspect(other)
          end)

        other ->
          to_string(other)
      end

    base = %{role: to_string(msg.role), content: content}

    case msg do
      %{tool_calls: [_ | _] = calls} ->
        Map.put(base, :tool_calls, Enum.map(calls, &normalize_tool_call/1))

      _ ->
        base
    end
  end

  defp normalize_tool_call(%ReqLLM.ToolCall{} = tc) do
    %{name: tc.function.name, arguments: tc.function.arguments}
  end

  defp normalize_tool_call(tc) when is_map(tc) do
    %{
      name: tc[:name] || get_in(tc, [:function, :name]),
      arguments: tc[:arguments] || get_in(tc, [:function, :arguments])
    }
  end

  defp unwrap_result(%NodeIO{} = nio), do: NodeIO.unwrap(nio)
  defp unwrap_result(other), do: other

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
