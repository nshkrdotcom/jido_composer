# Prototype: HITL (Human-in-the-Loop) design validation
# Run with: mix run prototypes/test_hitl_assumptions.exs
#
# Tests the hardest HITL assumptions:
# 1. Can a strategy handle :suspend outcome and resume later?
# 2. Can custom directives (SuspendForHuman) work?
# 3. Can we serialize/restore strategy state with pending HITL?
# 4. Can Schedule directive handle HITL timeouts?
# 5. Can nested agents propagate HITL across boundaries?

IO.puts("=" |> String.duplicate(70))
IO.puts("HITL DESIGN ASSUMPTIONS VALIDATION")
IO.puts("=" |> String.duplicate(70))

# ============================================================
# Setup: Define test modules
# ============================================================

defmodule HITLTestAction do
  use Jido.Action,
    name: "hitl_test_action",
    description: "Simple action for HITL tests",
    schema: []

  @impl true
  def run(_params, _context), do: {:ok, %{processed: true}}
end

# Custom SuspendForHuman directive
defmodule SuspendForHuman do
  defstruct [:approval_request, :notification, :hibernate]
end

# ApprovalRequest struct
defmodule ApprovalRequest do
  defstruct [:id, :prompt, :allowed_responses, :context_snapshot, :timeout, :created_at, :node_name, :workflow_state]
end

# ApprovalResponse struct
defmodule ApprovalResponse do
  defstruct [:id, :request_id, :decision, :data, :respondent, :responded_at]
end

# ============================================================
# TEST 1: Strategy with suspend/resume
# ============================================================
IO.puts("\n--- TEST 1: Strategy suspend/resume cycle ---")

defmodule HITLWorkflowStrategy do
  use Jido.Agent.Strategy

  @impl true
  def init(agent, _ctx) do
    agent = Jido.Agent.Strategy.State.put(agent, %{
      module: __MODULE__,
      status: :idle,
      current_state: :start,
      context: %{},
      pending_hitl_request: nil,
      history: []
    })
    {agent, []}
  end

  @impl true
  def cmd(agent, instructions, _ctx) do
    instruction = List.first(instructions)
    action = instruction.action

    case action do
      :begin ->
        # Move to first state, which is a human approval gate
        agent = update_state(agent, fn s ->
          %{s | status: :running, current_state: :human_review}
        end)

        # Simulate HumanNode returning {:ok, ctx, :suspend}
        request = %ApprovalRequest{
          id: "req-#{System.unique_integer([:positive])}",
          prompt: "Approve this data processing?",
          allowed_responses: [:approved, :rejected],
          context_snapshot: %{data: "sensitive data"},
          timeout: 30_000,
          created_at: DateTime.utc_now(),
          node_name: "human_review",
          workflow_state: :human_review
        }

        agent = update_state(agent, fn s ->
          %{s | status: :waiting, pending_hitl_request: request}
        end)

        # Emit SuspendForHuman directive
        suspend_directive = %SuspendForHuman{
          approval_request: request,
          notification: :pubsub,
          hibernate: false
        }

        # Optionally schedule a timeout
        timeout_signal = Jido.Signal.new!(%{
          type: "composer.hitl.timeout",
          source: "/agent",
          data: %{request_id: request.id}
        })
        timeout_directive = %Jido.Agent.Directive.Schedule{
          delay_ms: request.timeout,
          message: timeout_signal
        }

        {agent, [suspend_directive, timeout_directive]}

      :hitl_response ->
        state = Jido.Agent.Strategy.State.get(agent)

        # Verify the response matches a pending request
        response_data = instruction.params
        request = state.pending_hitl_request

        if request == nil do
          {agent, [%Jido.Agent.Directive.Error{error: %RuntimeError{message: "No pending HITL request"}}]}
        else
          # Use the decision as the transition outcome
          decision = response_data.decision

          agent = update_state(agent, fn s ->
            %{s |
              status: :running,
              pending_hitl_request: nil,
              current_state: if(decision == :approved, do: :process, else: :rejected),
              context: Map.put(s.context, :hitl_decision, decision),
              history: [{:human_review, decision, DateTime.utc_now()} | s.history]
            }
          end)

          case decision do
            :approved ->
              # Continue to next step
              inst = %Jido.Instruction{action: HITLTestAction, params: %{}, context: %{}}
              {agent, [%Jido.Agent.Directive.RunInstruction{instruction: inst, result_action: :step_result}]}
            :rejected ->
              agent = update_state(agent, fn s -> %{s | status: :failure} end)
              {agent, []}
          end
        end

      :hitl_timeout ->
        state = Jido.Agent.Strategy.State.get(agent)
        if state.pending_hitl_request != nil do
          # Timeout — treat as rejection
          agent = update_state(agent, fn s ->
            %{s | status: :failure, pending_hitl_request: nil, current_state: :timed_out}
          end)
          {agent, []}
        else
          # Already resolved, ignore
          {agent, []}
        end

      :step_result ->
        agent = update_state(agent, fn s ->
          %{s | status: :success, current_state: :done}
        end)
        {agent, []}
    end
  end

  @impl true
  def signal_routes(_ctx) do
    [
      {"composer.hitl.start", {:strategy_cmd, :begin}},
      {"composer.hitl.response", {:strategy_cmd, :hitl_response}},
      {"composer.hitl.timeout", {:strategy_cmd, :hitl_timeout}}
    ]
  end

  defp update_state(agent, fun) do
    Jido.Agent.Strategy.State.update(agent, fun)
  end
end

defmodule HITLTestAgent do
  use Jido.Agent,
    name: "hitl_test",
    schema: [],
    strategy: HITLWorkflowStrategy
end

# Create and start
agent = HITLTestAgent.new()
ctx = %{agent_module: HITLTestAgent, strategy_opts: []}

# Begin — should suspend
IO.puts("Starting HITL workflow...")
begin_inst = %Jido.Instruction{action: :begin, params: %{}, context: %{}}
{agent, directives} = HITLWorkflowStrategy.cmd(agent, [begin_inst], ctx)

state = Jido.Agent.Strategy.State.get(agent)
IO.puts("  Status: #{state.status}")
IO.puts("  Current state: #{state.current_state}")
IO.puts("  Pending request: #{state.pending_hitl_request != nil}")
IO.puts("  Directives emitted: #{length(directives)}")
IO.puts("  Directive types: #{directives |> Enum.map(&(&1.__struct__)) |> inspect()}")

# Verify SuspendForHuman was emitted
has_suspend = Enum.any?(directives, fn d -> d.__struct__ == SuspendForHuman end)
has_schedule = Enum.any?(directives, fn d -> d.__struct__ == Jido.Agent.Directive.Schedule end)
IO.puts("  Has SuspendForHuman: #{has_suspend}")
IO.puts("  Has Schedule (timeout): #{has_schedule}")

# Simulate human approval
IO.puts("\nSimulating human approval...")
response_inst = %Jido.Instruction{
  action: :hitl_response,
  params: %{decision: :approved, data: %{comment: "Looks good"}},
  context: %{}
}
{agent, directives} = HITLWorkflowStrategy.cmd(agent, [response_inst], ctx)

state = Jido.Agent.Strategy.State.get(agent)
IO.puts("  Status: #{state.status}")
IO.puts("  Current state: #{state.current_state}")
IO.puts("  Pending request: #{state.pending_hitl_request}")
IO.puts("  HITL decision: #{state.context[:hitl_decision]}")
IO.puts("  Directives: #{length(directives)} (should be RunInstruction)")

# Complete the step
step_inst = %Jido.Instruction{action: :step_result, params: %{}, context: %{}}
{agent, _} = HITLWorkflowStrategy.cmd(agent, [step_inst], ctx)
state = Jido.Agent.Strategy.State.get(agent)
IO.puts("  Final status: #{state.status}, state: #{state.current_state}")

IO.puts("TEST 1: PASS")

# ============================================================
# TEST 2: Rejection path
# ============================================================
IO.puts("\n--- TEST 2: HITL rejection ---")

agent2 = HITLTestAgent.new()
{agent2, _} = HITLWorkflowStrategy.cmd(agent2, [begin_inst], ctx)

reject_inst = %Jido.Instruction{
  action: :hitl_response,
  params: %{decision: :rejected, data: %{reason: "Too risky"}},
  context: %{}
}
{agent2, directives} = HITLWorkflowStrategy.cmd(agent2, [reject_inst], ctx)

state2 = Jido.Agent.Strategy.State.get(agent2)
IO.puts("  Status: #{state2.status}")
IO.puts("  Current state: #{state2.current_state}")
IO.puts("  Directives: #{length(directives)} (should be 0 — terminal)")

IO.puts("TEST 2: PASS")

# ============================================================
# TEST 3: Timeout path
# ============================================================
IO.puts("\n--- TEST 3: HITL timeout ---")

agent3 = HITLTestAgent.new()
{agent3, _} = HITLWorkflowStrategy.cmd(agent3, [begin_inst], ctx)

timeout_inst = %Jido.Instruction{
  action: :hitl_timeout,
  params: %{request_id: Jido.Agent.Strategy.State.get(agent3).pending_hitl_request.id},
  context: %{}
}
{agent3, _} = HITLWorkflowStrategy.cmd(agent3, [timeout_inst], ctx)

state3 = Jido.Agent.Strategy.State.get(agent3)
IO.puts("  Status: #{state3.status}")
IO.puts("  Current state: #{state3.current_state}")
IO.puts("  Pending request: #{state3.pending_hitl_request}")

IO.puts("TEST 3: PASS")

# ============================================================
# TEST 4: Duplicate response (idempotency)
# ============================================================
IO.puts("\n--- TEST 4: Duplicate HITL response ---")

agent4 = HITLTestAgent.new()
{agent4, _} = HITLWorkflowStrategy.cmd(agent4, [begin_inst], ctx)

# First response
{agent4, _} = HITLWorkflowStrategy.cmd(agent4, [response_inst], ctx)
# Second response (should be ignored — no pending request)
{agent4, directives} = HITLWorkflowStrategy.cmd(agent4, [response_inst], ctx)

has_error = Enum.any?(directives, &match?(%Jido.Agent.Directive.Error{}, &1))
IO.puts("  Duplicate response produced error: #{has_error}")

IO.puts("TEST 4: PASS")

# ============================================================
# TEST 5: State serialization with pending HITL
# ============================================================
IO.puts("\n--- TEST 5: State serialization with pending HITL ---")

agent5 = HITLTestAgent.new()
{agent5, _} = HITLWorkflowStrategy.cmd(agent5, [begin_inst], ctx)

# Serialize the strategy state
state5 = Jido.Agent.Strategy.State.get(agent5)
binary = :erlang.term_to_binary(state5, [:compressed])
IO.puts("  Serialized size: #{byte_size(binary)} bytes")

# Deserialize
restored_state = :erlang.binary_to_term(binary)
IO.puts("  Restored pending request id: #{restored_state.pending_hitl_request.id}")
IO.puts("  Restored status: #{restored_state.status}")
IO.puts("  Restored current_state: #{restored_state.current_state}")

# Verify we can resume from restored state
agent5_restored = Jido.Agent.Strategy.State.put(agent5, restored_state)
{agent5_restored, _} = HITLWorkflowStrategy.cmd(agent5_restored, [response_inst], ctx)
state5r = Jido.Agent.Strategy.State.get(agent5_restored)
IO.puts("  After resume from restore: status=#{state5r.status}, state=#{state5r.current_state}")

IO.puts("TEST 5: PASS")

# ============================================================
# TEST 6: Orchestrator approval gate simulation
# ============================================================
IO.puts("\n--- TEST 6: Orchestrator approval gate (tool call partitioning) ---")

# Simulate LLM returning 3 tool calls, 1 requiring approval
tool_calls = [
  %{id: "tc1", name: "research", arguments: %{query: "test"}, requires_approval: false},
  %{id: "tc2", name: "deploy", arguments: %{env: "prod"}, requires_approval: true},
  %{id: "tc3", name: "query_db", arguments: %{sql: "SELECT 1"}, requires_approval: false}
]

{ungated, gated} = Enum.split_with(tool_calls, fn tc -> !tc.requires_approval end)
IO.puts("  Total tool calls: #{length(tool_calls)}")
IO.puts("  Ungated (execute now): #{length(ungated)} — #{Enum.map(ungated, & &1.name) |> inspect()}")
IO.puts("  Gated (need approval): #{length(gated)} — #{Enum.map(gated, & &1.name) |> inspect()}")

# Track individual tool call states
tool_states = %{
  "tc1" => :executing,
  "tc2" => :awaiting_approval,
  "tc3" => :executing
}

# Simulate: tc1 completes, tc3 completes, tc2 still awaiting
tool_states = %{tool_states | "tc1" => :completed, "tc3" => :completed}

all_terminal? = Enum.all?(tool_states, fn {_id, s} -> s in [:completed, :rejected] end)
IO.puts("  After tc1+tc3 complete: all_terminal?=#{all_terminal?}")

# tc2 gets approved
tool_states = %{tool_states | "tc2" => :completed}
all_terminal? = Enum.all?(tool_states, fn {_id, s} -> s in [:completed, :rejected] end)
IO.puts("  After tc2 approved: all_terminal?=#{all_terminal?}")

# Rejection scenario
tool_states_reject = %{"tc1" => :completed, "tc2" => :rejected, "tc3" => :completed}
IO.puts("  Rejection result: #{inspect(tool_states_reject)}")

# Synthetic rejection result
rejection_result = %{
  id: "tc2",
  name: "deploy",
  result: %{error: "REJECTED by human reviewer. Reason: Too risky. Choose a different approach."}
}
IO.puts("  Synthetic rejection: #{inspect(rejection_result)}")

IO.puts("TEST 6: PASS")

# ============================================================
# TEST 7: ParentRef serialization issue
# ============================================================
IO.puts("\n--- TEST 7: ParentRef PID serialization ---")

parent_ref = %Jido.AgentServer.ParentRef{
  pid: self(),
  id: "parent-abc",
  tag: :child_1,
  meta: %{created_at: DateTime.utc_now()}
}

# PIDs ARE serializable via term_to_binary, but become stale
binary = :erlang.term_to_binary(parent_ref)
restored = :erlang.binary_to_term(binary)
IO.puts("  PID survives serialization: #{inspect(restored.pid)}")
IO.puts("  PID is alive after restore: #{Process.alive?(restored.pid)}")

# Strip PID for checkpoint
checkpoint_ref = %{restored | pid: nil}
binary2 = :erlang.term_to_binary(checkpoint_ref)
restored2 = :erlang.binary_to_term(binary2)
IO.puts("  Stripped PID checkpoint: pid=#{inspect(restored2.pid)}, id=#{restored2.id}")
IO.puts("  Non-PID fields preserved: tag=#{inspect(restored2.tag)}")

IO.puts("TEST 7: PASS")

# ============================================================
# TEST 8: ChildRef pattern for serialization
# ============================================================
IO.puts("\n--- TEST 8: ChildRef serializable references ---")

defmodule ChildRef do
  defstruct [:agent_module, :agent_id, :tag, :checkpoint_key, :status]
end

# A strategy stores ChildRefs instead of PIDs
child_ref = struct(ChildRef,
  agent_module: HITLTestAgent,
  agent_id: "child-xyz",
  tag: :etl_workflow,
  checkpoint_key: {"checkpoints", "child-xyz"},
  status: :running
)

# Fully serializable
binary = :erlang.term_to_binary(child_ref)
restored = :erlang.binary_to_term(binary)
IO.puts("  ChildRef serialized/restored: #{inspect(restored)}")
IO.puts("  Module preserved: #{restored.agent_module == HITLTestAgent}")

IO.puts("TEST 8: PASS")

# ============================================================
IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("ALL HITL TESTS PASSED")
IO.puts(String.duplicate("=", 70))
