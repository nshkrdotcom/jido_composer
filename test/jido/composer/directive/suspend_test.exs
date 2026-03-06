defmodule Jido.Composer.Directive.SuspendTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Directive.Suspend
  alias Jido.Composer.Directive.SuspendForHuman
  alias Jido.Composer.HITL.ApprovalRequest
  alias Jido.Composer.Suspension

  defp build_suspension!(attrs \\ []) do
    defaults = [reason: :rate_limit]
    {:ok, suspension} = Suspension.new(Keyword.merge(defaults, attrs))
    suspension
  end

  defp build_approval_request! do
    {:ok, request} =
      ApprovalRequest.new(
        prompt: "Approve deployment?",
        allowed_responses: [:approved, :rejected],
        timeout: 30_000
      )

    request
  end

  describe "struct creation" do
    test "creates a Suspend struct with required suspension field" do
      suspension = build_suspension!()
      directive = %Suspend{suspension: suspension}

      assert %Suspend{} = directive
      assert directive.suspension == suspension
    end

    test "raises when suspension field is missing" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Suspend, [])
      end
    end
  end

  describe "defaults" do
    test "notification defaults to nil" do
      suspension = build_suspension!()
      directive = %Suspend{suspension: suspension}

      assert directive.notification == nil
    end

    test "hibernate defaults to false" do
      suspension = build_suspension!()
      directive = %Suspend{suspension: suspension}

      assert directive.hibernate == false
    end
  end

  describe "custom values" do
    test "accepts custom notification" do
      suspension = build_suspension!()

      directive = %Suspend{
        suspension: suspension,
        notification: {:pubsub, topic: "suspensions"}
      }

      assert directive.notification == {:pubsub, topic: "suspensions"}
    end

    test "accepts hibernate as true" do
      suspension = build_suspension!()
      directive = %Suspend{suspension: suspension, hibernate: true}

      assert directive.hibernate == true
    end

    test "accepts hibernate as configuration map" do
      suspension = build_suspension!()

      directive = %Suspend{
        suspension: suspension,
        hibernate: %{after_ms: 300_000, storage: :ets}
      }

      assert directive.hibernate == %{after_ms: 300_000, storage: :ets}
    end
  end

  describe "SuspendForHuman.new/1 backward compatibility" do
    test "returns a %Suspend{} struct" do
      request = build_approval_request!()
      assert {:ok, directive} = SuspendForHuman.new(approval_request: request)

      assert %Suspend{} = directive
      assert directive.suspension.reason == :human_input
      assert directive.suspension.approval_request == request
    end

    test "carries notification and hibernate through to the Suspend struct" do
      request = build_approval_request!()

      {:ok, directive} =
        SuspendForHuman.new(
          approval_request: request,
          notification: {:webhook, url: "https://example.com"},
          hibernate: true
        )

      assert %Suspend{} = directive
      assert directive.notification == {:webhook, url: "https://example.com"}
      assert directive.hibernate == true
    end
  end

  describe "serialization" do
    test "round-trips through :erlang.term_to_binary" do
      suspension = build_suspension!(reason: :async_completion, metadata: %{job_id: "abc123"})

      directive = %Suspend{
        suspension: suspension,
        notification: {:webhook, url: "https://example.com/hook"},
        hibernate: %{after_ms: 60_000}
      }

      binary = :erlang.term_to_binary(directive)
      restored = :erlang.binary_to_term(binary)

      assert %Suspend{} = restored
      assert restored.suspension.reason == :async_completion
      assert restored.suspension.metadata == %{job_id: "abc123"}
      assert restored.notification == {:webhook, url: "https://example.com/hook"}
      assert restored.hibernate == %{after_ms: 60_000}
    end

    test "round-trips a Suspend created via SuspendForHuman.new/1" do
      request = build_approval_request!()
      {:ok, directive} = SuspendForHuman.new(approval_request: request, hibernate: true)

      binary = :erlang.term_to_binary(directive)
      restored = :erlang.binary_to_term(binary)

      assert %Suspend{} = restored
      assert restored.suspension.reason == :human_input
      assert restored.suspension.approval_request.prompt == "Approve deployment?"
      assert restored.hibernate == true
    end
  end
end
