defmodule Jido.Composer.Suspension do
  @moduledoc """
  Generalized suspension metadata for any reason a flow might pause.

  Supersedes `ApprovalRequest` as the primary suspension primitive. HITL
  becomes `reason: :human_input` with an embedded `approval_request`.

  ## Supported Reasons

  - `:human_input` — waiting for a human decision (wraps ApprovalRequest)
  - `:rate_limit` — backoff due to rate limiting
  - `:async_completion` — waiting for an external async operation
  - `:external_job` — waiting for an external job/webhook
  - `:custom` — application-defined reason
  """

  alias Jido.Composer.HITL.ApprovalRequest

  @derive Jason.Encoder

  @enforce_keys [:id, :reason, :created_at]
  defstruct [
    :id,
    :reason,
    :created_at,
    :resume_signal,
    :approval_request,
    timeout: :infinity,
    timeout_outcome: :timeout,
    metadata: %{}
  ]

  @type reason :: :human_input | :rate_limit | :async_completion | :external_job | :custom

  @type t :: %__MODULE__{
          id: String.t(),
          reason: reason(),
          created_at: DateTime.t(),
          resume_signal: String.t() | nil,
          timeout: pos_integer() | :infinity,
          timeout_outcome: atom(),
          metadata: map(),
          approval_request: ApprovalRequest.t() | nil
        }

  @valid_reasons [:human_input, :rate_limit, :async_completion, :external_job, :custom]

  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs) do
    attrs = Map.new(attrs)

    with :ok <- validate_required(attrs, :reason, "reason is required"),
         :ok <- validate_reason(attrs[:reason]) do
      {:ok,
       %__MODULE__{
         id: Map.get(attrs, :id, generate_id()),
         reason: attrs.reason,
         created_at: Map.get(attrs, :created_at, DateTime.utc_now()),
         resume_signal: Map.get(attrs, :resume_signal),
         timeout: Map.get(attrs, :timeout, :infinity),
         timeout_outcome: Map.get(attrs, :timeout_outcome, :timeout),
         metadata: Map.get(attrs, :metadata, %{}),
         approval_request: Map.get(attrs, :approval_request)
       }}
    end
  end

  @spec from_approval_request(ApprovalRequest.t()) :: {:ok, t()}
  def from_approval_request(%ApprovalRequest{} = request) do
    {:ok,
     %__MODULE__{
       id: request.id,
       reason: :human_input,
       created_at: request.created_at,
       resume_signal: "composer.suspend.resume",
       timeout: request.timeout,
       timeout_outcome: request.timeout_outcome,
       metadata: request.metadata,
       approval_request: request
     }}
  end

  defp validate_required(attrs, key, message) do
    if Map.has_key?(attrs, key), do: :ok, else: {:error, message}
  end

  defp validate_reason(reason) when reason in @valid_reasons, do: :ok

  defp validate_reason(reason),
    do: {:error, "invalid reason #{inspect(reason)}, expected one of #{inspect(@valid_reasons)}"}

  defp generate_id do
    "suspend-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end
end
