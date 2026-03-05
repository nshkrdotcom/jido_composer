defmodule Jido.Composer.HITL.ApprovalResponseTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.HITL.{ApprovalRequest, ApprovalResponse}

  describe "new/1" do
    test "creates a response with required fields" do
      assert {:ok, response} =
               ApprovalResponse.new(
                 request_id: "req-123",
                 decision: :approved
               )

      assert response.request_id == "req-123"
      assert response.decision == :approved
    end

    test "sets responded_at timestamp" do
      before = DateTime.utc_now()

      {:ok, response} =
        ApprovalResponse.new(request_id: "req-123", decision: :approved)

      after_time = DateTime.utc_now()

      assert %DateTime{} = response.responded_at
      assert DateTime.compare(response.responded_at, before) in [:gt, :eq]
      assert DateTime.compare(response.responded_at, after_time) in [:lt, :eq]
    end

    test "defaults for optional fields" do
      {:ok, response} =
        ApprovalResponse.new(request_id: "req-123", decision: :approved)

      assert response.data == nil
      assert response.respondent == nil
      assert response.comment == nil
    end

    test "accepts all optional fields" do
      {:ok, response} =
        ApprovalResponse.new(
          request_id: "req-123",
          decision: :approved,
          data: %{reason: "Looks correct"},
          respondent: "user@example.com",
          comment: "Ship it!"
        )

      assert response.data == %{reason: "Looks correct"}
      assert response.respondent == "user@example.com"
      assert response.comment == "Ship it!"
    end

    test "errors when request_id is missing" do
      assert {:error, _} = ApprovalResponse.new(decision: :approved)
    end

    test "errors when decision is missing" do
      assert {:error, _} = ApprovalResponse.new(request_id: "req-123")
    end

    test "errors when decision is not an atom" do
      assert {:error, _} =
               ApprovalResponse.new(request_id: "req-123", decision: "approved")
    end
  end

  describe "validate/2" do
    setup do
      {:ok, request} =
        ApprovalRequest.new(
          id: "req-456",
          prompt: "Approve deployment?",
          allowed_responses: [:approved, :rejected]
        )

      {:ok, request: request}
    end

    test "accepts valid response matching request", %{request: request} do
      {:ok, response} =
        ApprovalResponse.new(request_id: "req-456", decision: :approved)

      assert :ok = ApprovalResponse.validate(response, request)
    end

    test "rejects mismatched request_id", %{request: request} do
      {:ok, response} =
        ApprovalResponse.new(request_id: "req-999", decision: :approved)

      assert {:error, reason} = ApprovalResponse.validate(response, request)
      assert reason =~ "request_id"
    end

    test "rejects decision not in allowed_responses", %{request: request} do
      {:ok, response} =
        ApprovalResponse.new(request_id: "req-456", decision: :maybe)

      assert {:error, reason} = ApprovalResponse.validate(response, request)
      assert reason =~ "decision"
    end

    test "accepts all allowed responses", %{request: request} do
      for decision <- [:approved, :rejected] do
        {:ok, response} =
          ApprovalResponse.new(request_id: "req-456", decision: decision)

        assert :ok = ApprovalResponse.validate(response, request)
      end
    end
  end

  describe "serialization" do
    test "is fully serializable with :erlang.term_to_binary" do
      {:ok, response} =
        ApprovalResponse.new(
          request_id: "req-123",
          decision: :approved,
          data: %{reason: "LGTM"},
          respondent: "admin@co.com",
          comment: "Approved"
        )

      binary = :erlang.term_to_binary(response)
      restored = :erlang.binary_to_term(binary)

      assert restored.request_id == response.request_id
      assert restored.decision == response.decision
      assert restored.data == response.data
      assert restored.respondent == response.respondent
      assert restored.comment == response.comment
      assert restored.responded_at == response.responded_at
    end

    test "is JSON-serializable via Jason" do
      {:ok, response} =
        ApprovalResponse.new(
          request_id: "req-123",
          decision: :approved,
          data: %{notes: "all good"}
        )

      assert {:ok, json} = Jason.encode(response)
      assert is_binary(json)

      decoded = Jason.decode!(json)
      assert decoded["request_id"] == "req-123"
      assert decoded["decision"] == "approved"
    end
  end
end
