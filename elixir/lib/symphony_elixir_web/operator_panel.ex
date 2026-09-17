defmodule SymphonyElixirWeb.OperatorPanel do
  @moduledoc "Operator panel embedded in the existing dashboard."
  use Phoenix.Component
  alias SymphonyElixir.Operator.View

  attr(:model, :map, required: true)
  attr(:form, :map, default: nil)
  attr(:error, :string, default: nil)
  attr(:notice, :string, default: nil)
  attr(:busy, :boolean, default: false)
  attr(:demo, :boolean, default: false)

  @spec panel(map()) :: Phoenix.LiveView.Rendered.t()
  def panel(assigns) do
    ~H"""
    <section id="operator-panel" class="section-card operator-panel" lang="ru">
      <p class="eyebrow">Symphony · Панель оператора</p>
      <h2>Управление задачей и проверка dev</h2>
      <p :if={@demo} class="operator-warning">Демонстрация — реальные задачи не выполняются</p>
      <p :if={not Map.get(@model, :execution_enabled, false)}>Исполнение задач отключено; доступна инспекция.</p>
      <p :if={Map.get(@model, :execution_enabled, false)}>Controller запущен в изолированном режиме. Разрешён один выбранный пилот.</p>
      <div :if={Map.has_key?(@model, :model_selection)}>
        <p :for={key <- ["selected", "applied"]}>
          <%= if key == "selected", do: "Выбрано", else: "Подтверждено Codex для последней сессии" %>:
          <%= if pair = @model.model_selection[key] do %>
            <code><%= pair["model"] %></code> · усиление <code><%= pair["effort"] %></code>
          <% else %>
            <%= if key == "selected", do: "модель и усиление не выбраны", else: "сессия ещё не подтверждена" %>
          <% end %>
        </p>
      </div>
      <p :for={{location, disk} <- Map.get(@model, :storage, %{})} class={if disk["status"] in ["warning", "blocked"], do: "operator-warning"}>
        <%= if location == "controller_disk", do: "Controller", else: "Worker" %>: свободно <%= div(disk["free_bytes"] || 0, 1_073_741_824) %> GiB · <%= disk["status"] %>
      </p>
      <div class="operator-toolbar">
        <button phx-click="operator_refresh" disabled={@busy}>Обновить данные</button>
        <form method="post" action="/operator/logout"><input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} /><button type="submit">Выйти</button></form>
      </div>
      <p role="status" aria-live="polite"><%= @notice %></p>
      <p :if={@error} role="alert" class="operator-error"><%= @error %></p>
      <p :if={@busy} role="status">Проверяем актуальное состояние. Отмена и пауза остаются доступны.</p>
      <p><strong>Причина:</strong> <%= @model.reason %></p>
      <%= if @model.available do %>
        <p>Репозиторий: <code><%= @model.repo || "Ожидается сверка" %></code></p>
        <div class="operator-grid">
          <section><h3>Очередь задач Symphony</h3><p><%= @model.queue %></p><p><%= @model.phase %></p>
            <p>Задача: <code><%= @model.task || "—" %></code></p><p :if={@model.recovery}>Recovery; исходный владелец: <code><%= @model.owner %></code></p>
            <p>Ветка: <code><%= @model.branch || "—" %></code></p>
            <p><%= if @model.worker_stopped, do: "Активного worker нет, незавершённых операций нет", else: "Worker или внешняя операция ещё не подтверждены как завершённые" %></p>
            <a :if={@model.pr_url} href={@model.pr_url} target="_blank" rel="noopener noreferrer">PR #<%= @model.pr_number %> · <%= @model.pr_state %></a>
          </section>
          <section><h3>CI и deployment</h3><p>CI: <%= @model.ci["result"] || "Нет данных" %></p>
            <p>Deployment: <strong><%= @model.deployment["result"] || "Не подтверждён" %></strong></p>
            <p>Dev: <code><%= @model.sha || "—" %></code></p>
            <a :if={@model.run_url} href={@model.run_url} target="_blank" rel="noopener noreferrer">Открыть deployment · попытка <%= @model.deployment["run_attempt"] %></a>
            <p>Повтор CI без изменения кода запускается вручную в GitHub: Re-run jobs.</p>
          </section>
          <section><h3>Среда и ручная проверка</h3><p><%= @model.readiness %></p><p><%= @model.validation %></p>
            <p>Queue по отчёту деплоя: <%= get_in(@model.deployment, ["queue", "state"]) || "Нет данных" %></p>
            <p>Scheduler по отчёту деплоя: <%= @model.deployment["scheduler"] || "Нет данных" %></p>
            <div :if={@model.queue_confirmation != %{}}>
              <p>Ручное подтверждение: <%= @model.queue_confirmation["actor"] %> · <%= DateTime.from_unix!(@model.queue_confirmation["confirmed_at_ms"], :millisecond) |> DateTime.to_iso8601() %>.</p>
              <p>Queue: <%= @model.queue_confirmation["queue_resource"] %>; Scheduler: <%= @model.queue_confirmation["scheduler_resource"] %>.</p>
              <p><%= if @model.queue_confirmation["validated"], do: "Принято вместе с ручной проверкой dev для этого деплоя.", else: "В течение 30 минут после подтверждения Queue сохраните ручную проверку dev; иначе проверьте Queue заново." %></p>
            </div>
            <p>Последняя сверка: <%= @model.observed_at || "Ожидается" %></p>
            <p :if={@model.age_ms && @model.age_ms >= 60_000} class="operator-warning">Наблюдение старше минуты. Перед решением нужны свежие данные.</p>
          </section>
        </div>
        <section :if={@model.budget}><h3>Бюджеты</h3>
          <p>Первоначальная работа: <%= minutes(@model.budget.initial_ms) %> / <%= minutes(@model.budget.limits["initial_ms"]) %> мин.</p>
          <p>Исправления: <%= minutes(@model.budget.fix_ms) %> / <%= minutes(@model.budget.limits["fix_ms"]) %> мин.; циклы <%= @model.budget.fixes %> / <%= @model.budget.limits["fixes"] %>.</p>
          <p>CI: <%= @model.budget.ci_attempts %> / <%= @model.budget.limits["ci_attempts"] %>; повторов на SHA не более <%= @model.budget.limits["retries_per_sha"] %>.</p>
          <p>Свободный остаток вне резерва: работа <%= minutes(@model.budget.remaining["initial_ms"]) %> мин., исправления <%= minutes(@model.budget.remaining["fix_ms"]) %> мин.; циклы исправления <%= @model.budget.fixes_remaining %>, CI-попытки <%= @model.budget.ci_remaining %>.</p>
          <p :if={@model.budget.reserved}>Есть незакрытый рабочий интервал; резерв <%= minutes(@model.budget.reserved) %> мин.</p>
          <p :if={@model.budget.uncertain}>Расход после сбоя учтён консервативно.</p>
          <p>Ожидание GitHub и оператора не расходует активное время после подтверждённой остановки worker.</p>
        </section>
        <div class="operator-actions">
          <button :for={action <- @model.actions} phx-click="operator_prepare" phx-value-action={action.id}
            disabled={not action.enabled or (@busy and action.id not in ["cancel", "pause", "problem"])} title={action.hint}><%= action.label %></button>
        </div>
        <form :if={@form} id="operator-form" phx-submit="operator_submit" phx-change="operator_preview" class="operator-form">
          <h3><%= View.label(@form.action) %></h3>
          <p>Решение относится к версии состояния <%= @form.version.revision %>. Перед записью сервер повторит проверку.</p>
          <p>Dev: <code><%= @form.proof["sha"] || "Нет подтверждённых данных" %></code><br />Deployment run <%= @form.proof["run_id"] || "—" %>, попытка <%= @form.proof["run_attempt"] || "—" %>.</p>
          <p>Источник: последняя сверка observer с GitHub и deployment evidence. Получено: <%= @form.observed_at || "данных пока нет" %>. В демо используются тестовые наблюдения.</p>
          <input type="hidden" name="form_id" value={@form.id} />
          <p :if={@form.action == "cancel"}>Будет запрошена остановка. PR, ветка и deployment автоматически не удаляются и не откатываются.</p>
          <p :if={@form.action == "review_resume"}>Сначала верните карточку в Ready for agent на доске. Ветка и открытый PR сохранятся.</p>
          <p :if={@form.action == "problem"}>Очередь останется закрытой. Recovery назначается отдельно.</p>
          <fieldset :if={@form.action == "confirm_queue"}><legend>Проверка dev-ресурсов в Cloudflare</legend>
            <p>Самостоятельно снимите унаследованную паузу Queue в Cloudflare и проверьте Scheduler. Эта форма сохраняет ваше свидетельство; Symphony не меняет Cloudflare.</p>
            <label>Название или ID dev Queue<input name="queue_resource" required maxlength="256" value={@form.values["queue_resource"]} /></label>
            <label>Название или ID dev Scheduler<input name="scheduler_resource" required maxlength="256" value={@form.values["scheduler_resource"]} /></label>
            <label><input type="checkbox" name="criteria[]" value="queue_active" checked={"queue_active" in Map.get(@form.values, "criteria", [])} /> Queue активна, доставка разрешена</label>
            <label><input type="checkbox" name="criteria[]" value="scheduler_configured" checked={"scheduler_configured" in Map.get(@form.values, "criteria", [])} /> Scheduler настроен для dev</label>
            <p>Затем отдельно проверьте приложение и сохраните ручную проверку dev в течение 30 минут. Очередь задач пока останется закрытой.</p>
          </fieldset>
          <fieldset :if={@form.action == "validate"}><legend>Выполненные проверки</legend>
            <label><input type="checkbox" name="criteria[]" value="app" checked={"app" in Map.get(@form.values, "criteria", [])} /> Приложение и API доступны</label>
            <label><input type="checkbox" name="criteria[]" value="scenario" checked={"scenario" in Map.get(@form.values, "criteria", [])} /> Контрольный сценарий с тестовыми данными выполнен</label>
            <label><input type="checkbox" name="criteria[]" value="services" checked={"services" in Map.get(@form.values, "criteria", [])} /> Scheduler, Queue и доставка проверены</label>
          </fieldset>
          <label :if={@form.action == "recovery"}>Разрешённая recovery-карточка
            <select name="item_id" required><option value="">Выберите существующую задачу</option><option :for={id <- @form.choices} value={id} selected={@form.values["item_id"] == id}><%= id %></option></select>
          </label>
          <fieldset :if={@form.action in ["extend_budget", "review_resume", "recovery"]}><legend>Явный бюджет: минуты и количество попыток</legend>
            <label>Первоначальная работа, мин.<input name="initial_minutes" type="number" min="0" max="1440" value={Map.get(@form.values, "initial_minutes", "0")} /></label>
            <label>Исправления, мин.<input name="fix_minutes" type="number" min="0" max="1440" value={Map.get(@form.values, "fix_minutes", "0")} /></label>
            <label>Циклы исправления<input name="fixes" type="number" min="0" max="100" value={Map.get(@form.values, "fixes", "0")} /></label>
            <label>CI-попытки<input name="ci_attempts" type="number" min="0" max="100" value={Map.get(@form.values, "ci_attempts", "0")} /></label>
            <label>Повторы на SHA<input name="retries_per_sha" type="number" min="0" max="100" value={Map.get(@form.values, "retries_per_sha", "0")} /></label>
            <p>Для recovery это отдельные лимиты; для доработки и расширения — добавление к прежним лимитам. Расход не обнуляется.</p>
            <p :if={@form.preview} role="status">Итоговые лимиты: работа <%= minutes(@form.preview["initial_ms"]) %> мин., исправления <%= minutes(@form.preview["fix_ms"]) %> мин., циклы <%= @form.preview["fixes"] %>, CI <%= @form.preview["ci_attempts"] %>, повторы на SHA <%= @form.preview["retries_per_sha"] %>.</p>
          </fieldset>
          <label for="operator-reason">Что проверено или почему требуется действие</label>
          <textarea id="operator-reason" name="reason" required maxlength="2048" rows="3"><%= @form.values["reason"] %></textarea>
          <button type="submit" disabled={@busy and @form.action not in ["cancel", "pause", "problem"]}>Сохранить решение</button>
          <button type="button" phx-click="operator_close_form">Закрыть форму</button>
        </form>
        <details><summary>Восстановление после неопределённого результата</summary>
          <p>Сначала подтвердите остановку внешних процессов и результат отправленных операций. Выход SSH не доказывает остановку worker.</p>
          <p>Сброс store, ручное признание публикации успешной и возврат неопределённых попыток через панель запрещены. Производственная проверка остановки подключается в PR-11.</p>
        </details>
        <h3>Журнал решений</h3>
        <ol class="operator-audit"><li :for={entry <- Enum.reverse(@model.decisions)}><strong><%= entry.action %></strong> · <%= entry.actor %> · <%= DateTime.from_unix!(entry.at_ms, :millisecond) |> DateTime.to_iso8601() %><p><%= entry.reason %></p>
          <details><summary>Сохранённое решение · версия <%= entry.revision %></summary><p>Dev: <code><%= entry.proof["sha"] || "Действие без подтверждения deployment" %></code>; run <%= entry.proof["run_id"] || "—" %>, попытка <%= entry.proof["run_attempt"] || "—" %>.</p></details>
        </li></ol>
      <% end %>
    </section>
    """
  end

  defp minutes(value), do: Float.round(value / 60_000, 1)
end
