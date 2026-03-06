defmodule Jido.Composer.Directive.FanOutBranchTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Directive.FanOutBranch

  describe "struct" do
    test "creates FanOutBranch with instruction (ActionNode branch)" do
      instruction = %Jido.Instruction{
        action: Jido.Composer.TestActions.AddAction,
        params: %{value: 1.0, amount: 2.0}
      }

      branch = %FanOutBranch{
        fan_out_id: "abc123",
        branch_name: :validate,
        instruction: instruction,
        result_action: :fan_out_branch_result
      }

      assert branch.fan_out_id == "abc123"
      assert branch.branch_name == :validate
      assert branch.instruction == instruction
      assert branch.spawn_agent == nil
    end

    test "creates FanOutBranch with spawn_agent (AgentNode branch)" do
      spawn_info = %{
        agent: Jido.Composer.TestAgents.TestWorkflowAgent,
        opts: %{context: %{source: "test"}}
      }

      branch = %FanOutBranch{
        fan_out_id: "abc123",
        branch_name: :analyze,
        spawn_agent: spawn_info,
        result_action: :fan_out_branch_result
      }

      assert branch.fan_out_id == "abc123"
      assert branch.branch_name == :analyze
      assert branch.instruction == nil
      assert branch.spawn_agent == spawn_info
    end

    test "instruction and spawn_agent are mutually exclusive by convention" do
      instruction = %Jido.Instruction{
        action: Jido.Composer.TestActions.AddAction,
        params: %{}
      }

      spawn_info = %{agent: Jido.Composer.TestAgents.TestWorkflowAgent, opts: %{}}

      # While the struct doesn't enforce this at construction time,
      # the strategy only sets one or the other
      branch_with_instruction = %FanOutBranch{
        fan_out_id: "abc123",
        branch_name: :test,
        instruction: instruction
      }

      branch_with_spawn = %FanOutBranch{
        fan_out_id: "abc123",
        branch_name: :test,
        spawn_agent: spawn_info
      }

      assert branch_with_instruction.instruction
      assert is_nil(branch_with_instruction.spawn_agent)
      assert branch_with_spawn.spawn_agent
      assert is_nil(branch_with_spawn.instruction)
    end
  end
end
