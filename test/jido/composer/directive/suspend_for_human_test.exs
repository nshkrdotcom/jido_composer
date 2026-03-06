defmodule Jido.Composer.Directive.SuspendForHumanTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Directive.Suspend
  alias Jido.Composer.Directive.SuspendForHuman
  alias Jido.Composer.HITL.ApprovalRequest

  describe "new/1" do
    setup do
      {:ok, request} =
        ApprovalRequest.new(
          prompt: "Approve deployment?",
          allowed_responses: [:approved, :rejected],
          timeout: 30_000
        )

      {:ok, request: request}
    end

    test "creates a Suspend directive with a Suspension wrapping the ApprovalRequest", %{
      request: request
    } do
      assert {:ok, directive} = SuspendForHuman.new(approval_request: request)

      assert %Suspend{} = directive
      assert directive.suspension.reason == :human_input
      assert directive.suspension.approval_request == request
    end

    test "defaults notification to nil", %{request: request} do
      {:ok, directive} = SuspendForHuman.new(approval_request: request)
      assert directive.notification == nil
    end

    test "defaults hibernate to false", %{request: request} do
      {:ok, directive} = SuspendForHuman.new(approval_request: request)
      assert directive.hibernate == false
    end

    test "accepts notification config", %{request: request} do
      {:ok, directive} =
        SuspendForHuman.new(
          approval_request: request,
          notification: {:pubsub, topic: "approvals"}
        )

      assert directive.notification == {:pubsub, topic: "approvals"}
    end

    test "accepts hibernate config", %{request: request} do
      {:ok, directive} =
        SuspendForHuman.new(
          approval_request: request,
          hibernate: true
        )

      assert directive.hibernate == true
    end

    test "accepts hibernate with configuration map", %{request: request} do
      {:ok, directive} =
        SuspendForHuman.new(
          approval_request: request,
          hibernate: %{after_ms: 300_000, storage: :ets}
        )

      assert directive.hibernate == %{after_ms: 300_000, storage: :ets}
    end

    test "errors when approval_request is missing" do
      assert {:error, _} = SuspendForHuman.new([])
    end

    test "errors when approval_request is not an ApprovalRequest struct" do
      assert {:error, _} = SuspendForHuman.new(approval_request: %{not: "a request"})
    end
  end

  describe "consumer pattern matching" do
    setup do
      {:ok, request} =
        ApprovalRequest.new(
          prompt: "Approve deployment?",
          allowed_responses: [:approved, :rejected],
          timeout: 30_000
        )

      {:ok, request: request}
    end

    test "directive matches %Suspend{} not %SuspendForHuman{}", %{request: request} do
      {:ok, directive} = SuspendForHuman.new(approval_request: request)

      # Consumer code must match on %Suspend{}, not %SuspendForHuman{}
      assert %Suspend{suspension: suspension} = directive
      assert suspension.reason == :human_input
      assert suspension.approval_request == request

      # SuspendForHuman is no longer a struct module
      refute function_exported?(SuspendForHuman, :__struct__, 0)
    end

    test "approval_request is accessed via suspension.approval_request", %{request: request} do
      {:ok, directive} = SuspendForHuman.new(approval_request: request)

      # The correct access path for consumers
      %Suspend{suspension: suspension} = directive
      assert suspension.approval_request.prompt == "Approve deployment?"
      assert suspension.approval_request.allowed_responses == [:approved, :rejected]
    end
  end

  describe "serialization" do
    test "is fully serializable with :erlang.term_to_binary" do
      {:ok, request} =
        ApprovalRequest.new(
          prompt: "Approve?",
          allowed_responses: [:approved, :rejected]
        )

      {:ok, directive} =
        SuspendForHuman.new(
          approval_request: request,
          notification: {:webhook, url: "https://example.com"},
          hibernate: true
        )

      binary = :erlang.term_to_binary(directive)
      restored = :erlang.binary_to_term(binary)

      assert restored.suspension.approval_request.prompt == "Approve?"
      assert restored.notification == {:webhook, url: "https://example.com"}
      assert restored.hibernate == true
    end
  end
end
