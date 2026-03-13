## 1. Core Implementation

- [x] 1.1 Update `run_orch_directives/3` base case (empty `[]` clause) in `lib/jido/composer/orchestrator/dsl.ex`: thread `agent` into `{:ok, agent, unwrap_result(strat.result)}` for `:completed` and `{:suspended, agent, suspension}` for awaiting statuses
- [x] 1.2 Update `__query_sync_loop__/3` in `lib/jido/composer/orchestrator/dsl.ex`: match `{:ok, agent, result}` → return `{:ok, agent, result}`, match `{:suspend, agent, directive}` → return `{:suspended, agent, directive.suspension}`
- [x] 1.3 Update generated `query_sync/3` typespec in `dsl.ex` to `{:ok, Jido.Agent.t(), term()} | {:suspended, Jido.Agent.t(), Jido.Composer.Suspension.t()} | {:error, term()}`

## 2. Internal Callers

- [x] 2.1 Update `AgentNode.run/3` in `lib/jido/composer/node/agent_node.ex` line 93: change `{:ok, result}` to `{:ok, _agent, result}`
- [x] 2.2 Update `Node.execute_child_sync/2` in `lib/jido/composer/node.ex` line 89: change `query_sync` result match from `{:ok, result}` pattern to `{:ok, _agent, result}` (the function already returns `{:ok, result}` to its callers, just discard the agent)

## 3. Tests

- [x] 3.1 Update `test/jido/composer/orchestrator/dsl_test.exs`: change `{:ok, "The answer is 42"}` → `{:ok, _agent, "The answer is 42"}` (line 123), `{:ok, "Workflow ran successfully."}` → `{:ok, _agent, "Workflow ran successfully."}` (line 168), `{:ok, %{summary: ...}}` → `{:ok, _agent, %{summary: ...}}` (line 274)
- [x] 3.2 Update `test/jido/composer/orchestrator/dsl_test.exs` suspension tests: change `{:error, {:suspended, suspension}}` → `{:suspended, _agent, suspension}` (lines 340, 375)
- [x] 3.3 Update `test/jido/composer/orchestrator/configure_test.exs`: change all `{:ok, "..."}` → `{:ok, _agent, "..."}` (lines 240, 259, 272, 291, 325)
- [x] 3.4 Update `test/jido/composer/review_issues_test.exs`: change `{:ok, "Validation result: retry needed"}` → `{:ok, _agent, "Validation result: retry needed"}` (line 74), `{:ok, "done"}` → `{:ok, _agent, "done"}` (line 296)
- [x] 3.5 Run `mix test` and verify all tests pass

## 4. Documentation

- [x] 4.1 Update `docs/design/interface.md`: change `query_sync` return type in Generated Functions table
- [x] 4.2 Update `docs/design/orchestrator/README.md`: change `query_sync` return type in Generated Functions table and example on line 174
- [x] 4.3 Update `guides/orchestrators.md`: change all `{:ok, answer}` patterns to `{:ok, _agent, answer}` (lines 108, 132, 138, 195, 242, 290)
- [x] 4.4 Update `guides/getting-started.md`: change `{:ok, answer}` → `{:ok, _agent, answer}` (line 158)
- [x] 4.5 Update `guides/testing.md`: change `{:ok, answer}` → `{:ok, _agent, answer}` (line 41)
- [x] 4.6 Update `README.md`: change `{:ok, answer}` → `{:ok, _agent, answer}` (line 195)
- [x] 4.7 Update `lib/jido/composer/orchestrator.ex` and `lib/jido_composer.ex` docstring examples
- [x] 4.8 Update `lib/jido/composer/orchestrator/configure.ex` docstring example (line 28)

## 5. Livebooks

- [x] 5.1 Update `livebooks/04_llm_orchestrator.livemd`: change `{:ok, answer}` → `{:ok, _agent, answer}` (lines 188, 266, 440)
- [x] 5.2 Update `livebooks/06_observability.livemd`: change `{:ok, answer}` → `{:ok, _agent, answer}` (line 263)

## 6. Validation

- [x] 6.1 Run `mix precommit` and verify clean pass
