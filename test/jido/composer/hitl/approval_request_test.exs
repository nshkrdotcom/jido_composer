defmodule Jido.Composer.HITL.ApprovalRequestTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.HITL.ApprovalRequest

  describe "new/1" do
    test "creates a request with required fields" do
      assert {:ok, request} =
               ApprovalRequest.new(
                 prompt: "Approve deployment?",
                 allowed_responses: [:approved, :rejected]
               )

      assert request.prompt == "Approve deployment?"
      assert request.allowed_responses == [:approved, :rejected]
    end

    test "auto-generates a unique id" do
      {:ok, req1} = ApprovalRequest.new(prompt: "Q1", allowed_responses: [:yes, :no])
      {:ok, req2} = ApprovalRequest.new(prompt: "Q2", allowed_responses: [:yes, :no])

      assert is_binary(req1.id)
      assert is_binary(req2.id)
      assert req1.id != req2.id
    end

    test "allows explicit id override" do
      {:ok, request} =
        ApprovalRequest.new(
          id: "custom-id",
          prompt: "Approve?",
          allowed_responses: [:approved, :rejected]
        )

      assert request.id == "custom-id"
    end

    test "sets created_at timestamp" do
      before = DateTime.utc_now()
      {:ok, request} = ApprovalRequest.new(prompt: "Q?", allowed_responses: [:yes])
      after_time = DateTime.utc_now()

      assert %DateTime{} = request.created_at
      assert DateTime.compare(request.created_at, before) in [:gt, :eq]
      assert DateTime.compare(request.created_at, after_time) in [:lt, :eq]
    end

    test "defaults for optional fields" do
      {:ok, request} = ApprovalRequest.new(prompt: "Q?", allowed_responses: [:yes, :no])

      assert request.visible_context == %{}
      assert request.response_schema == nil
      assert request.timeout == :infinity
      assert request.timeout_outcome == :timeout
      assert request.metadata == %{}
      assert request.agent_id == nil
      assert request.agent_module == nil
      assert request.workflow_state == nil
      assert request.tool_call == nil
      assert request.node_name == nil
    end

    test "accepts all optional fields" do
      {:ok, request} =
        ApprovalRequest.new(
          prompt: "Deploy v1.2.3 to prod?",
          allowed_responses: [:approved, :rejected],
          visible_context: %{version: "1.2.3", env: "prod"},
          response_schema: [reason: [type: :string, required: true]],
          timeout: 30_000,
          timeout_outcome: :auto_reject,
          metadata: %{urgency: :high},
          agent_id: "agent-123",
          agent_module: SomeModule,
          workflow_state: :pending_approval,
          tool_call: %{id: "tc1", name: "deploy"},
          node_name: "deploy_approval"
        )

      assert request.visible_context == %{version: "1.2.3", env: "prod"}
      assert request.response_schema == [reason: [type: :string, required: true]]
      assert request.timeout == 30_000
      assert request.timeout_outcome == :auto_reject
      assert request.metadata == %{urgency: :high}
      assert request.agent_id == "agent-123"
      assert request.agent_module == SomeModule
      assert request.workflow_state == :pending_approval
      assert request.tool_call == %{id: "tc1", name: "deploy"}
      assert request.node_name == "deploy_approval"
    end

    test "errors when prompt is missing" do
      assert {:error, _} = ApprovalRequest.new(allowed_responses: [:yes])
    end

    test "errors when allowed_responses is missing" do
      assert {:error, _} = ApprovalRequest.new(prompt: "Q?")
    end

    test "errors when allowed_responses is empty" do
      assert {:error, _} = ApprovalRequest.new(prompt: "Q?", allowed_responses: [])
    end
  end

  describe "serialization" do
    test "is fully serializable with :erlang.term_to_binary" do
      {:ok, request} =
        ApprovalRequest.new(
          prompt: "Approve?",
          allowed_responses: [:approved, :rejected],
          visible_context: %{data: "test"},
          timeout: 30_000,
          metadata: %{source: "workflow"}
        )

      binary = :erlang.term_to_binary(request)
      restored = :erlang.binary_to_term(binary)

      assert restored.id == request.id
      assert restored.prompt == request.prompt
      assert restored.allowed_responses == request.allowed_responses
      assert restored.visible_context == request.visible_context
      assert restored.timeout == request.timeout
      assert restored.metadata == request.metadata
      assert restored.created_at == request.created_at
    end

    test "is JSON-serializable via Jason" do
      {:ok, request} =
        ApprovalRequest.new(
          prompt: "Approve?",
          allowed_responses: [:approved, :rejected],
          visible_context: %{amount: 100}
        )

      assert {:ok, json} = Jason.encode(request)
      assert is_binary(json)

      decoded = Jason.decode!(json)
      assert decoded["prompt"] == "Approve?"
      assert decoded["allowed_responses"] == ["approved", "rejected"]
      assert decoded["visible_context"] == %{"amount" => 100}
    end

    test "contains no PIDs, closures, or process references" do
      {:ok, request} =
        ApprovalRequest.new(
          prompt: "Approve?",
          allowed_responses: [:approved, :rejected],
          metadata: %{test: true}
        )

      # Verify struct fields don't contain PIDs
      fields = Map.from_struct(request)

      for {_key, value} <- fields do
        refute is_pid(value)
        refute is_function(value)
        refute is_port(value)
        refute is_reference(value)
      end
    end
  end
end
