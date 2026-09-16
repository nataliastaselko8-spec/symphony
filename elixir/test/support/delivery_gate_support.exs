defmodule SymphonyElixir.DeliveryGateSupport do
  alias SymphonyElixir.DeliveryGate.State

  def sha(letter \\ "a"), do: String.duplicate(letter, 40)
  def proof(letter \\ "a", attempt \\ 1), do: %{"sha" => sha(letter), "workflow_id" => 10, "run_id" => 20, "run_attempt" => attempt}
  def operator, do: %{"actor" => "operator-example", "reason" => "Reviewed current repository and environment"}
  def validation(letter \\ "a", attempt \\ 1), do: Map.merge(proof(letter, attempt), Map.merge(operator(), %{"criteria" => ["Queue active", "Application checked"]}))
  def task, do: %{"cycle_id" => "cycle-A", "item_id" => "item-A", "issue_id" => "issue-A", "branch" => "agent/task-a", "sha" => sha()}

  def apply!(state, action, args \\ %{}) do
    {:ok, state} = State.apply_command(state, action, args)
    state
  end

  def initial, do: State.new() |> apply!("bootstrap", validation()) |> apply!("reserve", task())
  def ci_request(id \\ "ci-1", letter \\ "b", retry \\ false), do: %{"reservation_id" => id, "sha" => sha(letter), "retry" => retry, "reason" => "Known transient service failure"}
  def ci_result(id \\ "ci-1", result \\ "success", attempt \\ 1), do: %{"reservation_id" => id, "run_id" => 100, "run_attempt" => attempt, "result" => result}

  def reviewed do
    initial()
    |> apply!("reserve_ci", ci_request())
    |> apply!("observe_ci", ci_result())
    |> apply!("handoff", %{"pr_number" => 7, "sha" => sha("b")})
  end

  def merged, do: reviewed() |> apply!("merged", %{"pr_number" => 7, "sha" => sha("c")})
  def deployment(letter \\ "c", attempt \\ 1), do: Map.merge(proof(letter, attempt), %{"result" => "success", "environment_ready" => true})
  def passed(letter \\ "c", attempt \\ 1), do: Map.put(validation(letter, attempt), "passed", true)
  def ready, do: merged() |> apply!("deployment", deployment()) |> apply!("validate_dev", passed())

  def recovery do
    Map.merge(operator(), %{
      "item_id" => "item-R",
      "issue_id" => "issue-R",
      "branch" => "agent/recovery-r",
      "sha" => sha("c"),
      "initial_ms" => 60_000,
      "fix_ms" => 60_000,
      "fixes" => 1,
      "ci_attempts" => 3,
      "retries_per_sha" => 1
    })
  end
end
