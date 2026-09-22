defmodule SymphonyElixir.Operator.View do
  @moduledoc "Allowlisted Russian operator presentation; no raw store or credential data reaches the browser."
  alias SymphonyElixir.DeliveryGate.{Budget, Command, StatusSync}
  alias SymphonyElixir.GitHubProjects.Delivery.QueueConfirmation
  alias SymphonyElixir.Operator.{Decision, Policy}

  @labels %{
    "pause" => "Приостановить работу",
    "problem" => "Обнаружена проблема",
    "cancel" => "Запросить отмену",
    "unpause" => "Снять операторскую паузу",
    "validate" => "Подтвердить ручную проверку dev",
    "validation_failed" => "Проверка dev не пройдена",
    "review_started" => "Начать review",
    "recheck_status" => "Повторно сверить статус доски",
    "confirm_queue" => "Подтвердить состояние Queue",
    "recovery" => "Назначить recovery",
    "resume" => "Продолжить ту же задачу",
    "review_resume" => "Вернуть PR на доработку",
    "extend_budget" => "Добавить бюджет",
    "finish_cancel" => "Завершить отмену"
  }
  @phases %{
    "reserved" => "Ожидает допуска",
    "working" => "Агент работает",
    "awaiting_ci" => "Ожидается CI",
    "awaiting_review" => "Ожидается review и merge",
    "awaiting_deployment" => "Ожидается deployment",
    "awaiting_validation" => "Нужна ручная проверка dev",
    "needs_human_decision" => "Нужно решение оператора",
    "cancelling" => "Отмена выполняется"
  }

  @spec label(String.t()) :: String.t()
  def label(action), do: Map.get(@labels, action, "Неизвестное действие")

  @spec form(map()) :: map()
  def form(context) do
    facts = if context.observation, do: context.observation.facts, else: %{}
    items = get_in(facts, ["project", "items"]) || []
    choices = items |> Enum.filter(&(&1["eligible"] == true and &1["state"] == context.settings.project.states["ready"])) |> Enum.map(& &1["item_id"])
    limits = get_in(context.gate.state, ["cycle", "budget", "limits"]) || %{}
    %{proof: Command.proof(facts["deployment"] || %{}), observed_at: context.observation && context.observation.observed_at, choices: choices, limits: limits, preview: nil, values: %{}}
  end

  @spec preview(map(), map()) :: map()
  def preview(form, params) do
    limits = if form.action == "recovery", do: %{}, else: form.limits
    values = Enum.map(~w(initial_minutes fix_minutes fixes ci_attempts retries_per_sha), &parse_number(params[&1]))

    totals =
      Enum.zip(~w(initial_ms fix_ms fixes ci_attempts retries_per_sha), values)
      |> Map.new(fn {key, value} -> {key, (limits[key] || 0) + value * if(key in ~w(initial_ms fix_ms), do: 60_000, else: 1)} end)

    form |> Map.put(:preview, totals) |> Map.put(:values, Map.drop(params, ~w(_target form_id)))
  end

  defp parse_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n in 0..1440 -> n
      _ -> 0
    end
  end

  defp parse_number(_), do: 0

  @spec project(map() | nil) :: map() | nil
  def project(nil), do: nil
  def project(%{gate: %{state: nil}}), do: unavailable("Состояние не проверено. Требуется восстановление store.")

  def project(%{gate: gate} = status) do
    state = gate.state
    cycle = state["cycle"]
    observation = status.observation
    facts = if observation, do: observation.facts, else: %{}
    deployment = facts["deployment"] || %{}
    reason = get_in(state, ["cycle", "block_reason"]) || hold_reason(state, status.reason)
    repo = facts["repo"]
    pr = facts["pr"] || %{}
    enabled = Map.get(status, :execution_enabled, false)
    runtime = Map.get(status, :runtime_readiness, %{ready: false, reasons: []})

    %{
      available: true,
      phase: phase(cycle),
      queue: queue_state(state["operator_pause"], enabled, runtime),
      cycle_id: get_in(state, ["cycle", "id"]),
      task: get_in(state, ["cycle", "task", "item_id"]),
      owner: get_in(state, ["cycle", "owner", "item_id"]),
      recovery: get_in(state, ["cycle", "recovery"]) != nil,
      branch: get_in(state, ["cycle", "work", "branch"]),
      repo: repo,
      worker_stopped: is_nil(status.worker) and Decision.quiet?(cycle) and not StatusSync.pending?(state),
      pr_url: github_url(repo, "/pull/", pr["number"]),
      pr_number: pr["number"],
      pr_state: pr["state"],
      sha: facts["dev_sha"],
      deployment: Map.take(deployment, ~w(sha result workflow_id run_id run_attempt environment_ready queue scheduler)),
      queue_confirmation: queue_confirmation(facts),
      run_url: github_url(repo, "/actions/runs/", deployment["run_id"]),
      ci: Map.take(facts["ci"] || %{}, ~w(result run_id run_attempt sha failure_kind)),
      observed_at: observation && observation.observed_at,
      age_ms: status.observation_age_ms,
      reason: runtime_reason(enabled, state, observation, reason),
      storage: Map.get(runtime, :storage, %{}),
      model_selection: model_selection(Map.get(runtime, :model, %{})),
      readiness: readiness(deployment, facts["manual_queue_confirmation"]),
      validation: validation(cycle, state),
      budget: budget(cycle),
      actions: actions(status),
      decisions: Enum.map(Map.get(status, :decisions, []), &decision/1),
      status_sync: Map.get(status, :status_sync, []),
      execution_enabled: enabled
    }
  end

  def project(_), do: unavailable("Controller недоступен. Действия временно запрещены.")

  defp queue_state(pause, _, _) when not is_nil(pause), do: "Пауза оператора"
  defp queue_state(_, false, _), do: "Запуск задач пока отключён"
  defp queue_state(_, _, %{ready: false, reasons: reasons}), do: "Допуск закрыт: " <> message(reasons)
  defp queue_state(_, _, _), do: "Controller запущен; допуск определяется delivery gate"

  defp model_selection(value) when is_map(value) do
    Map.new(~w(selected applied), fn key ->
      pair = Map.get(value, key)
      {key, if(is_map(pair), do: Map.take(pair, ~w(model effort)), else: nil)}
    end)
  end

  defp model_selection(_), do: %{}

  defp runtime_reason(true, _, _, nil), do: "Проверяем условия допуска"

  defp runtime_reason(true, state, observation, reason) do
    case current_reason(state, observation, reason) do
      "База dev подтверждена. Исполнение задач пока отключено." -> "База dev подтверждена. Проверяем допуск выбранной задачи."
      other -> other
    end
  end

  defp runtime_reason(_, state, observation, reason), do: current_reason(state, observation, reason)

  defp hold_reason(state, reason), do: if(Decision.held?(state), do: "operator_hold", else: reason)
  defp phase(nil), do: "Нет активной задачи"
  defp phase(cycle), do: Map.get(@phases, cycle["phase"], cycle["phase"])

  defp current_reason(%{"cycle" => nil, "baseline" => baseline} = state, observation, reason) when is_map(baseline) and not is_nil(observation) do
    if not Decision.held?(state) and Policy.healthy?(observation) and Command.proof(baseline) == Command.proof(observation.facts["deployment"]),
      do: "База dev подтверждена. Исполнение задач пока отключено.",
      else: message(reason)
  end

  defp current_reason(_, observation, "environment_not_ready") when not is_nil(observation) do
    if "resume_queue_before_dev_validation" in observation.reasons,
      do: message("resume_queue_before_dev_validation"),
      else: message(:environment_not_ready)
  end

  defp current_reason(_, _, reason), do: message(reason)

  @spec message(term()) :: String.t()
  def message(reason) when is_list(reason), do: Enum.map_join(reason, "; ", &message/1)
  def message(nil), do: "Ожидается проверка условий допуска"
  def message(:operator_context_changed), do: "Данные изменились. Обновите форму и проверьте актуальную версию."
  def message(:operator_form_expired), do: "Форма устарела. Откройте её заново."
  def message(:criteria_required), do: "Подтвердите все три проверки."
  def message(:operator_reason_required), do: "Добавьте комментарий о проверке или причине решения."
  def message(:invalid_operator_decision), do: "Проверьте заполнение формы. Для Queue нужны оба ресурса, обе галочки и комментарий."
  def message(:ready_allowed_item_required), do: "Нужна разрешённая карточка Ready for agent в текущем Project."
  def message(:owned_allowed_item_required), do: "Для продолжения нужна та же открытая разрешённая карточка. Полный профиль также принимает Needs human decision."
  def message(:positive_budget_required), do: "Укажите положительное добавление бюджета. Для recovery нужны время работы и CI."
  def message(:close_pr_or_validate_merged_dev), do: "Закройте ненужный PR в GitHub; после merge требуется проверка dev."
  def message(:environment_not_ready), do: "Среда ещё не готова. Проверьте deployment, Scheduler и Cloudflare Queue."
  def message(:work_unresolved), do: "Остановка или внешняя операция ещё не подтверждена."
  def message(:operator_read_rate_limited), do: "Слишком много повторных проверок. Подождите минуту; пауза и отмена доступны."
  def message("resume_queue_before_dev_validation"), do: "Деплой выполнен. Проверьте снятие паузы Queue и Scheduler в Cloudflare, затем подтвердите состояние Queue."
  def message("manual_dev_validation_required"), do: "Нужна ручная проверка dev"
  def message("operator_hold"), do: "Сохранена операторская пауза или сообщение о проблеме"
  def message("disk_space_low"), do: "Недостаточно места. Рабочие данные сохранены, новые задачи заблокированы."
  def message("codex_login_required"), do: "Нужен отдельный вход Codex на worker: runtime login."
  def message("model_selection_required"), do: "Выберите модель и усиление: runtime models, затем runtime select-model."
  def message("model_catalog_required"), do: "Получите список моделей и уровней рассуждений: runtime models."
  def message("model_catalog_refresh_required"), do: "Обновите список доступных моделей: остановите controller и выполните runtime models."
  def message("model_catalog_unavailable"), do: "Codex не подтвердил доступные модели. Задача не отправлена."
  def message("selected_model_unavailable"), do: "Выбранная модель недоступна. Автоматическая замена запрещена."
  def message("selected_effort_unavailable"), do: "Выбранный уровень рассуждений недоступен для этой модели."
  def message("model_application_mismatch"), do: "Codex не подтвердил выбранную модель и усиление. Задача не отправлена."
  def message("codex_model_rerouted"), do: "Codex сообщил о перенаправлении на другую модель. Работа остановлена, нужно решение оператора."
  def message("cycle_model_selection_changed"), do: "Модель или усиление отличаются от сохранённых для этой задачи. Восстановите прежнюю пару."
  def message("worker_runtime_unavailable"), do: "Нет подтверждения готовности изолированного worker."
  def message("worker_network_not_ready"), do: "Сетевая изоляция worker не подтверждена."
  def message("worker_reconciliation_required"), do: "Проверяем остановку прежнего worker."
  def message("worker_ownership_unknown"), do: "Привязка worker неизвестна; требуется проверка оператора."
  def message("worker_profile_mismatch"), do: "Образ worker не соответствует принятой ревизии проектного профиля."
  def message("worker_probe_failed"), do: "Подключение к Codex на worker не подтверждено. Проверьте runtime перед продолжением."
  def message("pilot_not_selected"), do: "Пилотная карточка не выбрана; запуск запрещён."
  def message("pilot_finished"), do: "Пилот завершён. Новый цикл автоматически не запускается."
  def message(reason) when is_atom(reason), do: reason |> Atom.to_string() |> message()
  def message(reason) when is_binary(reason), do: String.slice(reason, 0, 160)
  def message(_), do: "Нужно решение оператора"

  defp unavailable(reason), do: %{available: false, reason: reason}

  defp actions(status) do
    cycle = status.gate.state["cycle"]
    stopped = is_nil(status.worker) and Decision.quiet?(cycle)
    healthy = status.observation != nil and Policy.healthy?(status.observation)
    base = stopped and healthy and not status.restart_required
    unpause = unpause_available?(status)

    Enum.map(Decision.actions(), fn action ->
      enabled =
        enabled?(action, cycle, %{
          base: base,
          stopped: stopped,
          unpause: unpause,
          queue: stopped and not status.restart_required and QueueConfirmation.candidate?(status.observation),
          paused: status.gate.state["operator_pause"] != nil,
          sync: Map.get(status, :status_sync_enabled, false),
          pending: StatusSync.pending?(status.gate.state)
        })

      %{
        id: action,
        label: label(action),
        enabled: enabled,
        hint: if(enabled, do: "Сервер повторно проверит условия", else: "Недоступно в текущем состоянии; обновите данные и устраните блокировку")
      }
    end)
  end

  defp unpause_available?(status) do
    is_nil(status.worker) and Decision.stopped?(status.gate.state["cycle"]) and not status.restart_required and status.observation != nil
  end

  defp enabled?(action, _, _) when action in ~w(pause problem), do: true
  defp enabled?("cancel", %{"cancellation" => nil}, _), do: true
  defp enabled?("unpause", _, context), do: context.unpause and context.paused
  defp enabled?("confirm_queue", _, context), do: context.queue
  defp enabled?("validate", nil, context), do: context.base
  defp enabled?("validate", %{"phase" => phase}, context) when phase in ~w(needs_human_decision awaiting_review awaiting_validation cancelling), do: context.base
  defp enabled?("recovery", %{"phase" => "needs_human_decision", "recovery" => nil, "cancellation" => nil}, context), do: context.stopped
  defp enabled?("resume", %{"phase" => "needs_human_decision", "cancellation" => nil}, context), do: context.base
  defp enabled?("recheck_status", _, context), do: context.unpause and context.sync and context.pending
  defp enabled?("review_resume", %{"phase" => "awaiting_review"}, context), do: context.base
  defp enabled?("review_started", %{"phase" => "awaiting_review"}, context), do: context.base and context.sync
  defp enabled?("validation_failed", %{"phase" => "awaiting_validation"}, context), do: context.base and context.sync
  defp enabled?("extend_budget", cycle, context), do: context.base and cycle != nil
  defp enabled?("finish_cancel", %{"phase" => "cancelling"}, context), do: context.base
  defp enabled?(_, _, _), do: false

  defp readiness(%{"environment_ready" => true}), do: "Готовность подтверждена deployment evidence"
  defp readiness(%{"queue" => %{"reason" => "inherited_pause"}}), do: "Cloudflare Queue сохранила исходную паузу"
  defp readiness(_), do: "Готовность среды не подтверждена"
  defp readiness(deployment, nil), do: readiness(deployment)
  defp readiness(_, _), do: "Queue и Scheduler подтверждены оператором; автоматического чтения Cloudflare нет"
  defp queue_confirmation(facts), do: Map.take(facts["manual_queue_confirmation"] || %{}, ~w(actor reason confirmed_at_ms validated queue_resource scheduler_resource))
  defp validation(_, %{"environment_problem" => problem}) when not is_nil(problem), do: "Оператор сообщил о проблеме; положительного подтверждения нет"
  defp validation(nil, %{"baseline" => nil}), do: "Исходный dev ещё не подтверждён"
  defp validation(nil, _), do: "Сохранено подтверждение базы; актуальность проверяется перед допуском"
  defp validation(%{"validation" => %{"passed" => true}}, _), do: "Проверка записана; завершение ожидает сверки"
  defp validation(_, _), do: "Ожидается ручная проверка"

  defp budget(nil), do: nil

  defp budget(cycle) do
    budget = cycle["budget"]
    ci = Budget.latest_ci(budget)
    interval = budget["interval"] || %{}
    reserved = max((interval["reserved_ms"] || 0) - (interval["elapsed_ms"] || 0), 0)

    remaining =
      Map.new(~w(initial_ms fix_ms), fn key ->
        held = if interval["budget"] == key, do: reserved, else: 0
        {key, max(budget["limits"][key] - budget[key] - held, 0)}
      end)

    %{
      initial_ms: budget["initial_ms"],
      fix_ms: budget["fix_ms"],
      limits: budget["limits"],
      fixes: max(budget["fixes"], budget["fix_floor"]),
      ci_attempts: max(map_size(budget["ci"]), budget["ci_floor"]),
      reserved: budget["interval"] && reserved,
      remaining: remaining,
      fixes_remaining: max(budget["limits"]["fixes"] - max(budget["fixes"], budget["fix_floor"]), 0),
      ci_remaining: max(budget["limits"]["ci_attempts"] - max(map_size(budget["ci"]), budget["ci_floor"]), 0),
      uncertain: budget["accounting_uncertain"],
      last_ci: ci && Map.take(ci, ~w(result run_id run_attempt))
    }
  end

  defp decision(record) do
    args = record["args"]
    %{id: record["id"], revision: record["expected_revision"], action: label(args["kind"]), actor: args["actor"], reason: args["reason"], at_ms: record["at_ms"], proof: Command.proof(args["data"])}
  end

  defp github_url(repo, path, id) when is_binary(repo) and is_integer(id) and id > 0 do
    if Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, repo), do: "https://github.com/" <> repo <> path <> Integer.to_string(id)
  end

  defp github_url(_, _, _), do: nil
end
