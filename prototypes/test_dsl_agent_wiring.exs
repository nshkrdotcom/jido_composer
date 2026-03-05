# Prototype: DSL Macro & Strategy Wiring validation
# Run with: mix run prototypes/test_dsl_agent_wiring.exs
#
# Tests:
# 1. Strategy opts flow via `use Jido.Agent, strategy: {Mod, opts}`
# 2. Module type detection: Action vs Agent
# 3. cmd/3 receives instructions with atom actions
# 4. RunInstruction result_action routes result correctly
# 5. Jido.Action.Tool.to_tool/1 works on a test action

IO.puts("=" |> String.duplicate(70))
IO.puts("DSL MACRO & STRATEGY WIRING VALIDATION")
IO.puts("=" |> String.duplicate(70))

# ============================================================
# TEST 1: Strategy opts flow through init/2
# ============================================================
IO.puts("\n--- TEST 1: Strategy opts flow via use Jido.Agent ---")

defmodule OptsCapturingStrategy do
  use Jido.Agent.Strategy

  @impl true
  def init(agent, ctx) do
    opts = ctx[:strategy_opts] || []
    agent = Jido.Agent.Strategy.State.put(agent, %{
      module: __MODULE__,
      status: :idle,
      captured_opts: opts,
      custom_setting: Keyword.get(opts, :custom_setting, :not_set),
      max_retries: Keyword.get(opts, :max_retries, 0)
    })
    {agent, []}
  end

  @impl true
  def cmd(agent, instructions, ctx) do
    state = Jido.Agent.Strategy.State.get(agent)
    # Echo back the opts for verification
    IO.puts("    cmd/3 ctx.strategy_opts: #{inspect(ctx[:strategy_opts])}")
    IO.puts("    cmd/3 state.captured_opts: #{inspect(state.captured_opts)}")
    {agent, []}
  end

  @impl true
  def signal_routes(_ctx), do: []
end

defmodule AgentWithStrategyOpts do
  use Jido.Agent,
    name: "agent_with_opts",
    schema: [],
    strategy: {OptsCapturingStrategy, [custom_setting: :my_value, max_retries: 3]}
end

# Verify strategy/0 and strategy_opts/0
IO.puts("  strategy/0: #{inspect(AgentWithStrategyOpts.strategy())}")
IO.puts("  strategy_opts/0: #{inspect(AgentWithStrategyOpts.strategy_opts())}")

agent = AgentWithStrategyOpts.new()
state = Jido.Agent.Strategy.State.get(agent)
IO.puts("  init/2 captured custom_setting: #{inspect(state.custom_setting)}")
IO.puts("  init/2 captured max_retries: #{inspect(state.max_retries)}")
IO.puts("  init/2 captured_opts: #{inspect(state.captured_opts)}")

# Verify opts are correct
true = state.custom_setting == :my_value
true = state.max_retries == 3
true = state.captured_opts == [custom_setting: :my_value, max_retries: 3]
true = AgentWithStrategyOpts.strategy() == OptsCapturingStrategy
true = AgentWithStrategyOpts.strategy_opts() == [custom_setting: :my_value, max_retries: 3]

# Also verify cmd/3 receives opts
instruction = %Jido.Instruction{action: :test_action, params: %{}, context: %{}}
ctx = %{agent_module: AgentWithStrategyOpts, strategy_opts: AgentWithStrategyOpts.strategy_opts()}
{_agent, _directives} = OptsCapturingStrategy.cmd(agent, [instruction], ctx)

IO.puts("TEST 1: PASS")

# ============================================================
# TEST 2: Module type detection — Action vs Agent
# ============================================================
IO.puts("\n--- TEST 2: Module type detection ---")

defmodule DetectionTestAction do
  use Jido.Action,
    name: "detection_test",
    description: "Test action for type detection",
    schema: [
      input: [type: :string, required: true, doc: "Input value"]
    ]

  @impl true
  def run(params, _context), do: {:ok, %{echoed: params.input}}
end

defmodule DetectionTestAgent do
  use Jido.Agent,
    name: "detection_test_agent",
    schema: []
end

# Method 1: Check for @behaviour via function_exported?
# Actions define run/2, Agents don't
# Agents define cmd/2, Actions don't
is_action_by_run = function_exported?(DetectionTestAction, :run, 2)
is_agent_by_cmd = function_exported?(DetectionTestAgent, :cmd, 2)

IO.puts("  DetectionTestAction has run/2: #{is_action_by_run}")
IO.puts("  DetectionTestAgent has cmd/2: #{is_agent_by_cmd}")

# Method 2: Check specific functions unique to each
action_has_name = function_exported?(DetectionTestAction, :name, 0)
action_has_description = function_exported?(DetectionTestAction, :description, 0)
action_has_schema = function_exported?(DetectionTestAction, :schema, 0)
agent_has_strategy = function_exported?(DetectionTestAgent, :strategy, 0)
agent_has_new = function_exported?(DetectionTestAgent, :new, 0)

IO.puts("  Action has name/0: #{action_has_name}")
IO.puts("  Action has description/0: #{action_has_description}")
IO.puts("  Action has schema/0: #{action_has_schema}")
IO.puts("  Agent has strategy/0: #{agent_has_strategy}")
IO.puts("  Agent has new/0: #{agent_has_new}")

# Method 3: Check @behaviour attribute
# This requires compiled module introspection
action_behaviours = DetectionTestAction.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
agent_behaviours = DetectionTestAgent.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
IO.puts("  Action behaviours: #{inspect(action_behaviours)}")
IO.puts("  Agent behaviours: #{inspect(agent_behaviours)}")

is_action = Jido.Action in action_behaviours
is_agent = Jido.Agent in agent_behaviours
IO.puts("  DetectionTestAction is Jido.Action: #{is_action}")
IO.puts("  DetectionTestAgent is Jido.Agent: #{is_agent}")

# Recommended detection function
detect_type = fn mod ->
  cond do
    function_exported?(mod, :run, 2) and not function_exported?(mod, :cmd, 2) -> :action
    function_exported?(mod, :cmd, 2) and function_exported?(mod, :strategy, 0) -> :agent
    true -> :unknown
  end
end

IO.puts("  detect_type(DetectionTestAction) = #{detect_type.(DetectionTestAction)}")
IO.puts("  detect_type(DetectionTestAgent) = #{detect_type.(DetectionTestAgent)}")

true = detect_type.(DetectionTestAction) == :action
true = detect_type.(DetectionTestAgent) == :agent

IO.puts("TEST 2: PASS")

# ============================================================
# TEST 3: cmd/3 with atom actions (not just modules)
# ============================================================
IO.puts("\n--- TEST 3: cmd/3 with atom actions ---")

defmodule AtomActionStrategy do
  use Jido.Agent.Strategy

  @impl true
  def init(agent, _ctx) do
    agent = Jido.Agent.Strategy.State.put(agent, %{
      module: __MODULE__,
      status: :idle,
      received_actions: []
    })
    {agent, []}
  end

  @impl true
  def cmd(agent, instructions, _ctx) do
    actions = Enum.map(instructions, & &1.action)
    state = Jido.Agent.Strategy.State.get(agent)

    agent = Jido.Agent.Strategy.State.update(agent, fn s ->
      %{s | received_actions: s.received_actions ++ actions}
    end)
    {agent, []}
  end

  @impl true
  def signal_routes(_ctx), do: []
end

defmodule AtomActionAgent do
  use Jido.Agent,
    name: "atom_action_agent",
    schema: [],
    strategy: AtomActionStrategy
end

agent = AtomActionAgent.new()

# Send atom action via cmd/2
{agent, _directives} = AtomActionAgent.cmd(agent, :workflow_start)
{agent, _directives} = AtomActionAgent.cmd(agent, :step_result)
{agent, _directives} = AtomActionAgent.cmd(agent, {:custom_action, %{data: "hello"}})

state = Jido.Agent.Strategy.State.get(agent)
IO.puts("  Received actions: #{inspect(state.received_actions)}")

true = :workflow_start in state.received_actions
true = :step_result in state.received_actions
true = :custom_action in state.received_actions

IO.puts("TEST 3: PASS")

# ============================================================
# TEST 4: RunInstruction result_action routing
# ============================================================
IO.puts("\n--- TEST 4: RunInstruction result_action routing ---")

defmodule ResultRoutingAction do
  use Jido.Action,
    name: "result_routing",
    description: "Action that returns a result for routing",
    schema: []

  @impl true
  def run(_params, _context), do: {:ok, %{computed: 42, source: "test"}}
end

defmodule ResultRoutingStrategy do
  use Jido.Agent.Strategy

  @impl true
  def init(agent, _ctx) do
    agent = Jido.Agent.Strategy.State.put(agent, %{
      module: __MODULE__,
      status: :idle,
      step: :waiting,
      result_payload: nil
    })
    {agent, []}
  end

  @impl true
  def cmd(agent, instructions, _ctx) do
    instruction = List.first(instructions)
    action = instruction.action

    case action do
      :start ->
        # Emit RunInstruction that will route result back as :step_done
        inst = %Jido.Instruction{action: ResultRoutingAction, params: %{}, context: %{}}
        directive = %Jido.Agent.Directive.RunInstruction{
          instruction: inst,
          result_action: :step_done
        }
        agent = Jido.Agent.Strategy.State.update(agent, fn s ->
          %{s | status: :running, step: :executing}
        end)
        {agent, [directive]}

      :step_done ->
        # This gets called with the result payload from RunInstruction
        payload = instruction.params
        IO.puts("    Result action received payload keys: #{inspect(Map.keys(payload))}")
        IO.puts("    Payload status: #{inspect(payload[:status])}")
        IO.puts("    Payload result: #{inspect(payload[:result])}")
        IO.puts("    Payload instruction: #{inspect(payload[:instruction] != nil)}")

        agent = Jido.Agent.Strategy.State.update(agent, fn s ->
          %{s | status: :success, step: :done, result_payload: payload}
        end)
        {agent, []}
    end
  end

  @impl true
  def signal_routes(_ctx), do: []
end

# Simulate the RunInstruction result routing flow
# (This tests the strategy side - the AgentServer side was validated in round 1)
defmodule ResultRoutingAgent do
  use Jido.Agent,
    name: "result_routing_agent",
    schema: [],
    strategy: ResultRoutingStrategy
end

agent = ResultRoutingAgent.new()

# Step 1: Start — should emit RunInstruction
{agent, directives} = ResultRoutingAgent.cmd(agent, :start)
IO.puts("  After :start — directives: #{length(directives)}")
directive = List.first(directives)
IO.puts("  Directive type: #{inspect(directive.__struct__)}")
IO.puts("  result_action: #{inspect(directive.result_action)}")

true = directive.__struct__ == Jido.Agent.Directive.RunInstruction
true = directive.result_action == :step_done

# Step 2: Simulate what AgentServer does — execute the action and route result
# The AgentServer calls: agent_module.cmd(agent, {result_action, execution_payload})
execution_payload = %{
  status: :ok,
  result: %{computed: 42, source: "test"},
  effects: [],
  instruction: directive.instruction,
  meta: %{}
}
{agent, _} = ResultRoutingAgent.cmd(agent, {:step_done, execution_payload})

state = Jido.Agent.Strategy.State.get(agent)
IO.puts("  Final status: #{state.status}")
IO.puts("  Final step: #{state.step}")

true = state.status == :success
true = state.step == :done
true = state.result_payload != nil

IO.puts("TEST 4: PASS")

# ============================================================
# TEST 5: Jido.Action.Tool.to_tool/1 works
# ============================================================
IO.puts("\n--- TEST 5: Jido.Action.Tool.to_tool/1 ---")

defmodule ToolTestAction do
  use Jido.Action,
    name: "search_documents",
    description: "Search for documents by query and optional filters",
    schema: [
      query: [type: :string, required: true, doc: "Search query string"],
      max_results: [type: :integer, doc: "Maximum number of results to return"],
      format: [type: {:in, [:json, :text, :markdown]}, doc: "Output format"]
    ]

  @impl true
  def run(params, _context) do
    {:ok, %{results: ["doc1", "doc2"], query: params.query}}
  end
end

tool = Jido.Action.Tool.to_tool(ToolTestAction)
IO.puts("  Tool name: #{tool.name}")
IO.puts("  Tool description: #{tool.description}")
IO.puts("  Tool has function: #{is_function(tool.function, 2)}")
IO.puts("  Tool schema: #{inspect(tool.parameters_schema)}")

# Verify schema structure
schema = tool.parameters_schema
IO.puts("  Schema type: #{schema["type"]}")
IO.puts("  Schema properties keys: #{inspect(Map.keys(schema["properties"]))}")
IO.puts("  Schema required: #{inspect(schema["required"])}")

# Check individual property schemas
query_schema = schema["properties"]["query"]
IO.puts("  query type: #{query_schema["type"]}")

max_results_schema = schema["properties"]["max_results"]
IO.puts("  max_results type: #{max_results_schema["type"]}")

format_schema = schema["properties"]["format"]
IO.puts("  format enum: #{inspect(format_schema["enum"])}")

true = tool.name == "search_documents"
true = schema["type"] == "object"
true = "query" in schema["required"]
true = query_schema["type"] == "string"
true = max_results_schema["type"] == "integer"
true = is_list(format_schema["enum"])

# Test with strict mode
tool_strict = Jido.Action.Tool.to_tool(ToolTestAction, strict: true)
strict_schema = tool_strict.parameters_schema
IO.puts("  Strict mode additionalProperties: #{strict_schema["additionalProperties"]}")
true = strict_schema["additionalProperties"] == false

# Test tool execution
{:ok, result_json} = tool.function.(%{"query" => "test"}, %{})
result = Jason.decode!(result_json)
IO.puts("  Tool execution result: #{inspect(result)}")
true = result["query"] == "test"

IO.puts("TEST 5: PASS")

# ============================================================
IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("ALL DSL WIRING TESTS PASSED")
IO.puts(String.duplicate("=", 70))
