defmodule Jido.Composer.HITL.ApprovalResponse do
  @moduledoc """
  The human's response to an `ApprovalRequest`.

  Constructed by external code and delivered to the suspended flow.
  The strategy validates the response against the original request
  before accepting it.
  """

  @derive Jason.Encoder

  @enforce_keys [:request_id, :decision, :responded_at]
  defstruct [
    :request_id,
    :decision,
    :responded_at,
    :data,
    :respondent,
    :comment
  ]

  @type t :: %__MODULE__{
          request_id: String.t(),
          decision: atom(),
          responded_at: DateTime.t(),
          data: map() | nil,
          respondent: term(),
          comment: String.t() | nil
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs) do
    attrs = Map.new(attrs)

    with :ok <- validate_required(attrs, :request_id, "request_id is required"),
         :ok <- validate_required(attrs, :decision, "decision is required"),
         :ok <- validate_atom(attrs[:decision]) do
      {:ok,
       %__MODULE__{
         request_id: attrs.request_id,
         decision: attrs.decision,
         responded_at: Map.get(attrs, :responded_at, DateTime.utc_now()),
         data: Map.get(attrs, :data),
         respondent: Map.get(attrs, :respondent),
         comment: Map.get(attrs, :comment)
       }}
    end
  end

  @spec validate(t(), Jido.Composer.HITL.ApprovalRequest.t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{} = response, %Jido.Composer.HITL.ApprovalRequest{} = request) do
    with :ok <- validate_request_id_match(response.request_id, request.id) do
      validate_decision_allowed(response.decision, request.allowed_responses)
    end
  end

  defp validate_required(attrs, key, message) do
    if Map.has_key?(attrs, key), do: :ok, else: {:error, message}
  end

  defp validate_atom(value) when is_atom(value), do: :ok
  defp validate_atom(_), do: {:error, "decision must be an atom"}

  defp validate_request_id_match(response_id, request_id) when response_id == request_id, do: :ok

  defp validate_request_id_match(response_id, request_id) do
    {:error,
     "request_id mismatch: response has #{inspect(response_id)}, request has #{inspect(request_id)}"}
  end

  defp validate_decision_allowed(decision, allowed) do
    if decision in allowed do
      :ok
    else
      {:error, "decision #{inspect(decision)} is not in allowed_responses #{inspect(allowed)}"}
    end
  end
end
