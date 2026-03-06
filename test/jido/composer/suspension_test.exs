defmodule Jido.Composer.SuspensionTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Suspension
  alias Jido.Composer.HITL.ApprovalRequest

  describe "new/1" do
    test "creates a suspension with required reason and auto-generated id/created_at" do
      assert {:ok, suspension} = Suspension.new(reason: :human_input)

      assert is_binary(suspension.id)
      assert String.starts_with?(suspension.id, "suspend-")
      assert suspension.reason == :human_input
      assert %DateTime{} = suspension.created_at
    end

    test "auto-generates unique ids" do
      {:ok, s1} = Suspension.new(reason: :rate_limit)
      {:ok, s2} = Suspension.new(reason: :rate_limit)

      assert is_binary(s1.id)
      assert is_binary(s2.id)
      assert s1.id != s2.id
    end

    test "allows explicit id override" do
      {:ok, suspension} = Suspension.new(id: "my-suspend-id", reason: :custom)

      assert suspension.id == "my-suspend-id"
    end

    test "sets created_at timestamp automatically" do
      before = DateTime.utc_now()
      {:ok, suspension} = Suspension.new(reason: :async_completion)
      after_time = DateTime.utc_now()

      assert %DateTime{} = suspension.created_at
      assert DateTime.compare(suspension.created_at, before) in [:gt, :eq]
      assert DateTime.compare(suspension.created_at, after_time) in [:lt, :eq]
    end

    test "defaults for optional fields" do
      {:ok, suspension} = Suspension.new(reason: :human_input)

      assert suspension.resume_signal == nil
      assert suspension.timeout == :infinity
      assert suspension.timeout_outcome == :timeout
      assert suspension.metadata == %{}
      assert suspension.approval_request == nil
    end

    test "accepts all optional fields" do
      {:ok, approval} =
        ApprovalRequest.new(
          prompt: "Approve?",
          allowed_responses: [:approved, :rejected]
        )

      now = DateTime.utc_now()

      {:ok, suspension} =
        Suspension.new(
          id: "suspend-custom",
          reason: :human_input,
          created_at: now,
          resume_signal: "composer.suspend.resume",
          timeout: 60_000,
          timeout_outcome: :auto_reject,
          metadata: %{urgency: :high, source: "workflow"},
          approval_request: approval
        )

      assert suspension.id == "suspend-custom"
      assert suspension.reason == :human_input
      assert suspension.created_at == now
      assert suspension.resume_signal == "composer.suspend.resume"
      assert suspension.timeout == 60_000
      assert suspension.timeout_outcome == :auto_reject
      assert suspension.metadata == %{urgency: :high, source: "workflow"}
      assert suspension.approval_request == approval
    end
  end

  describe "new/1 valid reasons" do
    test "accepts :human_input" do
      assert {:ok, %Suspension{reason: :human_input}} = Suspension.new(reason: :human_input)
    end

    test "accepts :rate_limit" do
      assert {:ok, %Suspension{reason: :rate_limit}} = Suspension.new(reason: :rate_limit)
    end

    test "accepts :async_completion" do
      assert {:ok, %Suspension{reason: :async_completion}} =
               Suspension.new(reason: :async_completion)
    end

    test "accepts :external_job" do
      assert {:ok, %Suspension{reason: :external_job}} = Suspension.new(reason: :external_job)
    end

    test "accepts :custom" do
      assert {:ok, %Suspension{reason: :custom}} = Suspension.new(reason: :custom)
    end
  end

  describe "new/1 validation" do
    test "rejects invalid reason atom" do
      assert {:error, message} = Suspension.new(reason: :unknown_reason)
      assert message =~ "invalid reason"
      assert message =~ ":unknown_reason"
    end

    test "rejects non-atom reason" do
      assert {:error, message} = Suspension.new(reason: "human_input")
      assert message =~ "invalid reason"
    end

    test "errors when reason is missing" do
      assert {:error, "reason is required"} = Suspension.new([])
    end
  end

  describe "from_approval_request/1" do
    test "wraps an ApprovalRequest as a :human_input suspension" do
      {:ok, approval} =
        ApprovalRequest.new(
          prompt: "Deploy to prod?",
          allowed_responses: [:approved, :rejected],
          timeout: 30_000,
          timeout_outcome: :auto_reject,
          metadata: %{env: "production"}
        )

      assert {:ok, suspension} = Suspension.from_approval_request(approval)

      assert suspension.id == approval.id
      assert suspension.reason == :human_input
      assert suspension.created_at == approval.created_at
      assert suspension.resume_signal == "composer.suspend.resume"
      assert suspension.timeout == 30_000
      assert suspension.timeout_outcome == :auto_reject
      assert suspension.metadata == %{env: "production"}
      assert suspension.approval_request == approval
    end

    test "rejects non-ApprovalRequest struct" do
      assert_raise FunctionClauseError, fn ->
        apply(Suspension, :from_approval_request, [%{prompt: "not a request"}])
      end
    end

    test "rejects plain map" do
      assert_raise FunctionClauseError, fn ->
        apply(Suspension, :from_approval_request, [
          %{id: "x", prompt: "y", allowed_responses: [:yes]}
        ])
      end
    end
  end

  describe "serialization" do
    test "is JSON-serializable via Jason" do
      {:ok, suspension} =
        Suspension.new(
          reason: :rate_limit,
          resume_signal: "retry-after",
          timeout: 5_000,
          metadata: %{retry_count: 3}
        )

      assert {:ok, json} = Jason.encode(suspension)
      assert is_binary(json)

      decoded = Jason.decode!(json)
      assert decoded["reason"] == "rate_limit"
      assert decoded["resume_signal"] == "retry-after"
      assert decoded["timeout"] == 5_000
      assert decoded["metadata"] == %{"retry_count" => 3}
      assert decoded["id"] == suspension.id
    end

    test "JSON encodes suspension with embedded approval_request" do
      {:ok, approval} =
        ApprovalRequest.new(
          prompt: "Approve?",
          allowed_responses: [:approved, :rejected]
        )

      {:ok, suspension} = Suspension.from_approval_request(approval)

      assert {:ok, json} = Jason.encode(suspension)
      decoded = Jason.decode!(json)

      assert decoded["reason"] == "human_input"
      assert decoded["approval_request"]["prompt"] == "Approve?"
      assert decoded["approval_request"]["allowed_responses"] == ["approved", "rejected"]
    end

    test "round-trips via :erlang.term_to_binary" do
      {:ok, suspension} =
        Suspension.new(
          reason: :external_job,
          resume_signal: "webhook.complete",
          timeout: 120_000,
          timeout_outcome: :cancelled,
          metadata: %{job_id: "job-42", provider: "github"}
        )

      binary = :erlang.term_to_binary(suspension)
      restored = :erlang.binary_to_term(binary)

      assert restored.id == suspension.id
      assert restored.reason == suspension.reason
      assert restored.created_at == suspension.created_at
      assert restored.resume_signal == suspension.resume_signal
      assert restored.timeout == suspension.timeout
      assert restored.timeout_outcome == suspension.timeout_outcome
      assert restored.metadata == suspension.metadata
      assert restored.approval_request == suspension.approval_request
    end

    test "round-trips via :erlang.term_to_binary with embedded approval_request" do
      {:ok, approval} =
        ApprovalRequest.new(
          prompt: "Approve deployment?",
          allowed_responses: [:approved, :rejected],
          visible_context: %{version: "2.0"},
          timeout: 60_000,
          metadata: %{source: "ci"}
        )

      {:ok, suspension} = Suspension.from_approval_request(approval)

      binary = :erlang.term_to_binary(suspension)
      restored = :erlang.binary_to_term(binary)

      assert restored == suspension
      assert restored.approval_request.prompt == "Approve deployment?"
      assert restored.approval_request.allowed_responses == [:approved, :rejected]
    end
  end
end
