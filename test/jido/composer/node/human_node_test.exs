defmodule Jido.Composer.Node.HumanNodeTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Node.HumanNode
  alias Jido.Composer.HITL.ApprovalRequest

  describe "new/1" do
    test "creates a HumanNode with required fields" do
      assert {:ok, node} =
               HumanNode.new(
                 name: "deploy_approval",
                 description: "Approve production deployment",
                 prompt: "Approve deployment to production?"
               )

      assert node.name == "deploy_approval"
      assert node.description == "Approve production deployment"
      assert node.prompt == "Approve deployment to production?"
    end

    test "defaults allowed_responses to [:approved, :rejected]" do
      {:ok, node} =
        HumanNode.new(
          name: "approval",
          description: "Approve",
          prompt: "Approve?"
        )

      assert node.allowed_responses == [:approved, :rejected]
    end

    test "accepts custom allowed_responses" do
      {:ok, node} =
        HumanNode.new(
          name: "triage",
          description: "Triage the issue",
          prompt: "How to handle?",
          allowed_responses: [:fix, :defer, :wontfix]
        )

      assert node.allowed_responses == [:fix, :defer, :wontfix]
    end

    test "defaults for optional fields" do
      {:ok, node} =
        HumanNode.new(name: "n", description: "d", prompt: "p?")

      assert node.response_schema == nil
      assert node.timeout == :infinity
      assert node.timeout_outcome == :timeout
      assert node.context_keys == nil
      assert node.metadata == %{}
    end

    test "accepts all optional fields" do
      {:ok, node} =
        HumanNode.new(
          name: "approval",
          description: "Approve",
          prompt: "Approve?",
          allowed_responses: [:yes, :no],
          response_schema: [reason: [type: :string]],
          timeout: 60_000,
          timeout_outcome: :auto_reject,
          context_keys: [:amount, :recipient],
          metadata: %{channel: "slack"}
        )

      assert node.response_schema == [reason: [type: :string]]
      assert node.timeout == 60_000
      assert node.timeout_outcome == :auto_reject
      assert node.context_keys == [:amount, :recipient]
      assert node.metadata == %{channel: "slack"}
    end

    test "errors when name is missing" do
      assert {:error, _} = HumanNode.new(description: "d", prompt: "p?")
    end

    test "errors when description is missing" do
      assert {:error, _} = HumanNode.new(name: "n", prompt: "p?")
    end

    test "errors when prompt is missing" do
      assert {:error, _} = HumanNode.new(name: "n", description: "d")
    end

    test "accepts a function prompt" do
      prompt_fn = fn ctx -> "Approve #{ctx[:action]}?" end

      {:ok, node} =
        HumanNode.new(
          name: "approval",
          description: "Dynamic approval",
          prompt: prompt_fn
        )

      assert is_function(node.prompt, 1)
    end
  end

  describe "run/2" do
    test "returns {:ok, context, :suspend} with ApprovalRequest in context" do
      {:ok, node} =
        HumanNode.new(
          name: "approval",
          description: "Approve action",
          prompt: "Approve this action?"
        )

      context = %{amount: 100, recipient: "user@example.com"}
      assert {:ok, updated_context, :suspend} = HumanNode.run(node, context)

      assert %ApprovalRequest{} = updated_context.__approval_request__
      assert updated_context.__approval_request__.prompt == "Approve this action?"
      assert updated_context.__approval_request__.allowed_responses == [:approved, :rejected]
    end

    test "evaluates dynamic prompt from context" do
      prompt_fn = fn ctx -> "Approve transfer of $#{ctx[:amount]}?" end

      {:ok, node} =
        HumanNode.new(
          name: "transfer_approval",
          description: "Approve transfer",
          prompt: prompt_fn
        )

      context = %{amount: 500}
      {:ok, updated, :suspend} = HumanNode.run(node, context)

      assert updated.__approval_request__.prompt == "Approve transfer of $500?"
    end

    test "filters visible_context by context_keys" do
      {:ok, node} =
        HumanNode.new(
          name: "approval",
          description: "Approve",
          prompt: "Approve?",
          context_keys: [:amount, :currency]
        )

      context = %{amount: 100, currency: "USD", secret_key: "abc123", internal: true}
      {:ok, updated, :suspend} = HumanNode.run(node, context)

      assert updated.__approval_request__.visible_context == %{amount: 100, currency: "USD"}
    end

    test "includes full context when context_keys is nil" do
      {:ok, node} =
        HumanNode.new(
          name: "approval",
          description: "Approve",
          prompt: "Approve?"
        )

      context = %{a: 1, b: 2}
      {:ok, updated, :suspend} = HumanNode.run(node, context)

      assert updated.__approval_request__.visible_context == %{a: 1, b: 2}
    end

    test "propagates timeout and timeout_outcome to request" do
      {:ok, node} =
        HumanNode.new(
          name: "approval",
          description: "Approve",
          prompt: "Approve?",
          timeout: 30_000,
          timeout_outcome: :auto_reject
        )

      {:ok, updated, :suspend} = HumanNode.run(node, %{})

      assert updated.__approval_request__.timeout == 30_000
      assert updated.__approval_request__.timeout_outcome == :auto_reject
    end

    test "propagates metadata to request" do
      {:ok, node} =
        HumanNode.new(
          name: "approval",
          description: "Approve",
          prompt: "Approve?",
          metadata: %{urgency: :high, channel: "slack"}
        )

      {:ok, updated, :suspend} = HumanNode.run(node, %{})

      assert updated.__approval_request__.metadata == %{urgency: :high, channel: "slack"}
    end

    test "generates unique request id for each run" do
      {:ok, node} =
        HumanNode.new(name: "n", description: "d", prompt: "p?")

      {:ok, ctx1, :suspend} = HumanNode.run(node, %{})
      {:ok, ctx2, :suspend} = HumanNode.run(node, %{})

      assert ctx1.__approval_request__.id != ctx2.__approval_request__.id
    end

    test "preserves original context alongside __approval_request__" do
      {:ok, node} =
        HumanNode.new(name: "n", description: "d", prompt: "p?")

      context = %{existing: "data", count: 42}
      {:ok, updated, :suspend} = HumanNode.run(node, context)

      assert updated.existing == "data"
      assert updated.count == 42
      assert Map.has_key?(updated, :__approval_request__)
    end
  end

  describe "to_directive/3" do
    test "produces a Suspend directive with pending_suspension side effect" do
      {:ok, node} =
        HumanNode.new(
          name: "approval",
          description: "Approve action",
          prompt: "Approve this action?"
        )

      context = %{amount: 100}

      assert {:ok, [directive], side_effects} = HumanNode.to_directive(node, context, [])
      assert %Jido.Composer.Directive.Suspend{} = directive
      assert directive.suspension.reason == :human_input
      assert Keyword.get(side_effects, :pending_suspension) != nil
      assert Keyword.get(side_effects, :status) == :waiting
    end

    test "enriches approval request with provided request_fields" do
      {:ok, node} =
        HumanNode.new(
          name: "deploy_check",
          description: "Check deploy",
          prompt: "OK to deploy?"
        )

      opts = [
        request_fields: %{
          agent_id: "agent_123",
          workflow_state: :deploying,
          node_name: "deploy_check"
        }
      ]

      assert {:ok, [directive], _side_effects} = HumanNode.to_directive(node, %{}, opts)
      request = directive.suspension.approval_request
      assert request.agent_id == "agent_123"
      assert request.workflow_state == :deploying
    end
  end

  describe "to_tool_spec/1" do
    test "returns nil (HumanNode cannot act as LLM tool)" do
      {:ok, node} = HumanNode.new(name: "n", description: "d", prompt: "p?")
      assert HumanNode.to_tool_spec(node) == nil
    end
  end

  describe "Node behaviour" do
    test "HumanNode declares Node behaviour" do
      behaviours =
        HumanNode.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Jido.Composer.Node in behaviours
    end

    test "run/3 returns {:ok, context, :suspend}" do
      {:ok, node} = HumanNode.new(name: "n", description: "d", prompt: "p?")
      assert {:ok, _ctx, :suspend} = HumanNode.run(node, %{}, [])
    end
  end

  describe "metadata" do
    test "name/1 returns the configured name" do
      {:ok, node} =
        HumanNode.new(name: "my_approval", description: "d", prompt: "p?")

      assert HumanNode.name(node) == "my_approval"
    end

    test "description/1 returns the configured description" do
      {:ok, node} =
        HumanNode.new(name: "n", description: "Requires human review", prompt: "p?")

      assert HumanNode.description(node) == "Requires human review"
    end

    test "schema/1 returns the response_schema" do
      {:ok, node} =
        HumanNode.new(
          name: "n",
          description: "d",
          prompt: "p?",
          response_schema: [reason: [type: :string]]
        )

      assert HumanNode.schema(node) == [reason: [type: :string]]
    end

    test "schema/1 returns nil when no response_schema" do
      {:ok, node} = HumanNode.new(name: "n", description: "d", prompt: "p?")
      assert HumanNode.schema(node) == nil
    end
  end
end
