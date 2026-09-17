# План адаптера GitHub Projects для EmotionStat

**Подготовка подключения deployment evidence:** [инструкции controller и дашборда](github_projects_setup/deployment-evidence-integration.md) находятся в Symphony. Текущая рабочая папка — `D:/symphony`; прежний путь `D:/fork/_symphony/symphony` в ранних записях ниже сохранён как история. Формат отчёта и поведение deployment workflow документируются в `EmotionStat/app`.

Обновлено: 2026-09-17. **PR-02–PR-10 приняты; PR-11 подготовлен локально** в `agent/feat/portable-worker-runtime` от `main` (`df918b9`). Реализованы переносимые config/launcher, изолированный Podman worker, ограниченный SSH, watchdog, остановка и Git bundle transport. [Контракт и инструкция PR-11](../../runtime/README.md), [отчёт проверок](github_projects_setup/pr11-validation.md). Исполнение реальных Projects остаётся отключено до PR-13; профиль и hooks — PR-12. Push и merge выполняет владелица. PR-01 отложен до итогового обновления базы знаний. Нумерация этапов отличается от номеров GitHub PR; старые записи ниже сохраняют историю.

Для валидации очередности работ использовать [поэтапный план PR](github_projects_pr_rollout_plan.md). Этот документ сохраняет подробный технический контракт. Часть чтения адаптера реализована в [PR #1](https://github.com/nataliastaselko8-spec/symphony/pull/1) (этап PR-02), слитом владелицей в main 2026-09-15; merge commit `00bc204c7002f9c027b1f62d742fe143adfb2e2f`. Все четыре решения владелицы подтверждены: WSL2 на этом компьютере; отдельное GitHub App, принадлежащее EmotionStat; сама владелица как единственный оператор review/merge, ручной проверки dev и назначения recovery; fork [nataliastaselko8-spec/symphony](https://github.com/nataliastaselko8-spec/symphony). Checkout fork подключён к `D:/fork/_symphony/symphony`, ветка `main` отслеживает `origin/main`, документы сохранены. App создан и установлен, read-only доступ к Project подтверждён. Полная готовность worker WSL2 и будущий доступ к operator UI ещё проверяются при подготовке.

Цель: подключить Symphony к GitHub Project **EmotionStat / Delivery / 1**, чтобы очередь и состояние работы определялись карточками проекта. Первый проверяемый результат — чтение реальной очереди в режиме `dry_run`, следующий — одна разрешённая задача из `EmotionStat/app`, доведённая до PR в `dev`. Полный пилот проверяет также ожидание ручного merge, деплоя и подтверждения работоспособности `dev` перед допуском следующей задачи.

**Очередность по решению владелицы 2026-09-15:** начать с PR-02 в форке Symphony; knowledge-base пока не изменять. Предварительный PR-01 отложен, его объём объединяется с итоговым PR-15. Решения и вопросы по ходу реализации фиксируются в двух планах форка и соответствующих кодовых PR; в базу знаний переносятся проверенные итоги после реализации/пилота либо записи причины его остановки. Документация поведения и конфигурации в изменяемом кодовом репозитории обновляется в том же PR.

Этот документ — рабочий план изменения Symphony. Он не заменяет канонические решения EmotionStat и не означает запуск автоматизации. Связанные открытые пункты knowledge-base: **OPS-002** — процесс Delivery и его автоматизация; **ENG-008** — состояние runner и наблюдаемость.

### Выполненный этап PR-02

**Результат реализации 2026-09-15:** подготовлен [draft PR #1](https://github.com/nataliastaselko8-spec/symphony/pull/1) в личном форке; этап плана — PR-02. Ветка `agent/feat/github-projects-inspection`, commit `9b223bc12f936e3da3a84bbe3016b56028e9c51a`, base `main`. Merge не выполнялся.

Реализованы paginated Project/schema/issue-context reader, проверка field/option IDs, точный item/repo scope, причины исключения и конечный JSON `--dry-run`. Обычные CLI, application/Mix startup и reload блокируют исполнение `github_projects`; runtime/hook/workspace side effects проверены. Refresh трактует `NOT_FOUND` как отсутствие только после полного inventory, включая архив. Пример профиля и инструкция — [github_projects.md](github_projects.md) и [inspection WORKFLOW](examples/github_projects.WORKFLOW.md); они используют синтетические значения.

Проверено в исходном WSL `Ubuntu` под controller `nataselko`: `make all` PASS (342 tests, 0 failures, 6 skipped; coverage 100%; specs/Credo/Dialyzer PASS), штатный PR body validator PASS, Linux x86_64 Burrito build и smoke реальных escript/Burrito entrypoints PASS. Для сборки Zig cache размещён в Linux `/tmp`; в Git закреплены LF для Elixir, dashboard snapshots и шаблона PR. Локальные полные отчёты — `elixir/tmp/pr-02-make-all.log` и `elixir/tmp/pr-02-linux-build.log`; в коммит не входят. Пакет — `elixir/burrito_out/symphony_linux_x86_64`, также локальный.

**GitHub CI подтверждён 2026-09-15:** владелица включила workflows в форке. Для существующего draft PR #1 выполнено краткое закрытие/повторное открытие, чтобы создать событие `pull_request.reopened`. На commit `9b223bc12f936e3da3a84bbe3016b56028e9c51a` успешно завершились [make-all](https://github.com/nataliastaselko8-spec/symphony/actions/runs/34976625624) и [pr-description-lint](https://github.com/nataliastaselko8-spec/symphony/actions/runs/34976625699). Релизный workflow не запускался. PR остаётся открытым черновиком; merge не выполнялся.

**Ограничения:** live-чтение EmotionStat/Delivery не выполнялось; создание/установка App и O3 остаются неподтверждёнными. Код PR-02 использует заранее выданный token, renewal относится к PR-03. Проверки не подтверждают готовность worker O2 или запуск задач. Hex сообщает advisories в уже закреплённых зависимостях; lockfile не изменён, до live rollout требуется отдельная проверка и обновление зависимостей по результатам. Knowledge-base, agent-runner и app в этом этапе не изменялись. Рабочие планы и файлы настройки EmotionStat не включены в публичный кодовый PR.

## 1. Объём первой версии

- Новый тип трекера `github_projects`; существующий `github` продолжает читать issues репозитория.
- Один организационный Project, один разрешённый репозиторий `EmotionStat/app`, один экземпляр runner, `agent.max_concurrent_agents: 1`.
- Исполняемые карточки связаны с обычными открытыми issues. PR, черновики, архивированные и недоступные карточки не запускаются.
- Новая работа допускается только при `Status = Ready for agent` и `Agent allowed = yes`.
- `Agent working` допускает продолжение начатой работы при тех же условиях доступа.
- На репозиторий допускается один незавершённый цикл: задача → PR → human review/merge → деплой `dev` → проверка работоспособности. Создание PR и освобождение Codex worker не открывают очередь следующей обычной задачи. При сбое допускается только явно разрешённое восстановление внутри текущего цикла.
- Проверка dev в MVP — `validation.mode: manual`: после успешного deployment и обязательных finalizers уполномоченный оператор проверяет приложение и фиксирует результат. Автоматических post-deploy smoke tests пока нет; один зелёный Actions run не открывает очередь.
- Для каждой новой задачи создаётся отдельная рабочая ветка от свежеполученного `origin/dev`. Агент пушит только ветку этой задачи и создаёт PR с базой `dev`. Прямой push в `dev` и `main` запрещён; изменения попадают в `dev` через проверенный PR, merge выполняется существующим процессом человека.
- Проверки, отчёт и передача PR входят в результат задачи. `Done` остаётся состоянием после необходимых проверок проекта, а не синонимом создания или слияния PR.

За рамками этой серии: несколько рабочих репозиториев, выполнение черновиков, несколько экземпляров runner с распределёнными блокировками, обработка webhooks, автоматическое выполнение merge и deployment/recovery операций. Их добавление требует отдельного решения. В MVP раннер наблюдает за результатами этих операций через polling; сами операции остаются в существующем процессе человека и GitHub Actions.

## 2. Основания и границы достоверности

Проверены локальный код Symphony, каркас `D:/agent-runner`, документы knowledge-base и предоставленный скриншот Delivery. Из приватной доски в этой сессии не получены актуальные API-данные: реальные node IDs, типы полей, опции и права токена проверяются при первом чтении.

Локальные источники:

- [Пример конфигурации runner](/D:/agent-runner/config/runner.example.yaml) — один агент, `dry_run`, явное разрешение на исполнение. Это пример, не реализованные настройки Symphony.
- [Концепция GitHub и runner](</D:/work/EmotionStat/knowledge-base/70_Engineering/Development/Agent-Native GitHub and Cloudflare Concept.md>) — один Delivery, отдельный приватный исполнитель, ручной первый rollout.
- [План настройки, фаза 4](</D:/work/EmotionStat/knowledge-base/70_Engineering/Deployment/GitHub Cloudflare Deployment Setup Plan.md:160>) — поля, статусы, представления и записанная конфигурация автоматизаций доски.
- [Agent Development Workflow](</D:/work/EmotionStat/knowledge-base/70_Engineering/Development/Agent Development Workflow.md>) и [Agent PR Policy](</D:/work/EmotionStat/knowledge-base/70_Engineering/Development/Agent PR Policy.md>) — допуск к работе, проверки, ветки и PR в `dev`.
- [GitHub Cloudflare Deployment Flow](</D:/work/EmotionStat/knowledge-base/70_Engineering/Deployment/GitHub Cloudflare Deployment Flow.md>) — записанный development workflow, частичные последствия сбоя, восстановление Scheduler/Queue и границы проверки успешного деплоя. Фактический workflow приложения и его результаты проверяются до live-пилота.
- [Фактический development workflow приложения](/D:/EmotionStat_app/app/.github/workflows/deploy-development.yml) — локально перепроверен 2026-09-15: `push dev`/`workflow_dispatch`, `verify` до deployment, без отдельного `pull_request` CI и post-deploy smoke tests. Соответствие локального checkout текущему удалённому `dev` проверяется при preflight.
- [Action Register](</D:/work/EmotionStat/knowledge-base/00_Project Map/Action Register.md>) — OPS-002 и ENG-008.

Расхождение о размещении `WORKFLOW.md` устранено в knowledge-base 2026-09-14 по указанию владельца: Agent Development Workflow закрепляет канонические правила в базе знаний, правила продукта — в `app/AGENTS.md`, README и конфигурации GitHub, исполняемый файл Symphony — в **agent-runner**. Создание и настройка `agent-runner/WORKFLOW.md` остаются открытым пунктом фазы 10 плана настройки и OPS-002; сам файл ещё не создан.

Пример runner разрешает `app` и `knowledge-base`, но записанная конфигурация Delivery подключает только `app`. MVP использует `app`; автоматического расширения на knowledge-base нет.

Базовые ветки разных репозиториев не смешивать. Правило каждой продуктовой задачи «fresh `origin/dev` → task branch → PR в `dev`» относится к `EmotionStat/app`. Локальные `agent-runner` и `knowledge-base` используют `main`; их служебные изменения также проходят через отдельную ветку и PR в проверенную default branch. По указанию владелицы дальнейшая работа Symphony ведётся в `D:/fork/_symphony/symphony`: 2026-09-15 подключён выбранный публичный fork `nataliastaselko8-spec/symphony`, его parent/source — `openai/symphony`, default branch — `main`. Эти сведения подтверждены [GitHub API](https://api.github.com/repos/nataliastaselko8-spec/symphony). Локальный `origin` — `https://github.com/nataliastaselko8-spec/symphony.git`, `upstream` — `https://github.com/openai/symphony.git`, default push remote — `origin`, ветка `main` отслеживает `origin/main`. Проверенный HEAD при подключении — `e0ccc83720a42a600a53b61c5f8d3e518bebe1db`; оба плана и шесть UI-файлов сохранены. Symphony PR направляются в личный fork с базой `main`; права публикации подтверждены при push PR-02 и создании draft PR #1 в личном форке. Ранее проверенный `D:/symphony` не является рабочей папкой этой серии.

## 3. Разделение реализации

| Место | Ответственность |
| --- | --- |
| `D:/fork/_symphony/symphony` | Адаптер, API-клиент, нормализация карточек, инструменты агента, допуск новых задач, наблюдение за PR/деплоем, сохранение цикла и восстановление, проверка конфигурации, режим инспекции и тесты |
| `D:/agent-runner` | Версия Symphony; профиль `D:/agent-runner/WORKFLOW.md`; запуск `D:/agent-runner/scripts/launch.sh`; preflight `D:/agent-runner/scripts/preflight.sh`; hooks в `D:/agent-runner/scripts/hooks/`; настройки ожидания и подтверждения готовности dev, каталоги исполнения, состояния и журналов |
| `EmotionStat/app` | Код задачи, собственный `AGENTS.md`, команды проверки, рабочая ветка и PR; CI до merge и проверяемые результаты deployment workflow |
| `EmotionStat/knowledge-base` | Утверждённые правила и решения; фиксация принятого mapping и результатов пилота |

Переиспользовать существующие `Tracker.Issue`, `dispatchable`, `native_ref`, `Tracker.bind_agent_tools`, изоляцию workspace, retries и reconciliation. Второй scheduler внутри agent-runner не нужен.

Одной правки `WORKFLOW.md` или `runner.example.yaml` недостаточно: текущий лимит агентов считает работающие процессы, а после `PR ready` процесс освобождается. Требуется исполняемый механизм допуска в Symphony. Общий оркестратор отвечает за допуск и единственное владение циклом; чтение GitHub PR/Actions и интерпретация результатов остаются в интеграции GitHub. Для остальных трекеров механизм выключен по умолчанию.

Предполагаемые файлы Symphony, пути от корня репозитория:

| Файл | Изменение |
| --- | --- |
| `elixir/lib/symphony_elixir/github_projects/adapter.ex` | Реализация Tracker, проверка настроек, регистрация инструментов |
| `elixir/lib/symphony_elixir/github_projects/client.ex` | GraphQL, discovery полей, чтение карточек, нормализация, проверка ответов |
| `elixir/lib/symphony_elixir/github_projects/agent_tool.ex` | Ограниченные операции с текущей карточкой, issue и PR |
| `elixir/lib/symphony_elixir/github_projects/delivery.ex` | Чтение PR, актуального dev SHA, запусков и попыток deployment workflow; проверка свидетельства готовности окружения |
| Небольшой GitHub credential provider | Обновление installation tokens выбранного отдельного GitHub App для EmotionStat на controller; контролируемая ошибка истечения/отзыва или refresh. Scope не меняется при обновлении credentials |
| `elixir/lib/symphony_elixir/orchestrator.ex` и небольшой модуль `delivery_gate.ex` | Проверка допуска перед dispatch/retry, резервирование цикла на repo, ожидание без Codex worker, исключение для восстановления |
| Небольшой store состояния цикла | Предлагаемый MVP — versioned JSON snapshot с единственным писателем, атомарной заменой и проверяемым восстановлением вне workspace; не новая БД платформы |
| `elixir/lib/symphony_elixir/agent_runner.ex` и `workspace.ex` | Явная пауза работающей обычной задачи по решению цикла; безопасная передача контекста issue/repo/branch/expected base SHA при подготовке workspace |
| `elixir/lib/symphony_elixir/tracker.ex` | Регистрация `github_projects`; узкая проверка допустимости reload |
| `elixir/lib/symphony_elixir/workflow_store.ex` | Отклонение несовместимого reload с сохранением последней корректной конфигурации |
| `elixir/lib/symphony_elixir/config/schema.ex` | Предлагаемый контракт `validation.mode: manual` и проверка его согласованности с политикой цикла |
| `elixir/lib/symphony_elixir/cli.ex` и отдельный модуль инспекции | Конечный read-only запуск до старта оркестратора |
| `elixir/lib/symphony_elixir_web/router.ex`, `endpoint.ex`, `live/dashboard_live.ex`, `presenter.ex` и конфигурация endpoint | Операторская авторизация, защищённые session/Origin/CSRF, форма ручной проверки, назначение recovery и свежая атомарная запись результата |
| `elixir/test/symphony_elixir/` | Тесты адаптера, инструментов, CLI и жизненного цикла |

Общий HTTP/auth-код GitHub переиспользовать в пределах существующих контрактов. Нормализатор GitHub Issues не переиспользовать целиком: у него другие ID и смысл `state`. Не создавать универсальную платформу HTTP-клиентов ради нового адаптера.

Ранние PR дают инспекцию и тестируемые модули. До интеграции полного цикла, scoped tools и операторского управления выполнение нового provider должно явно отклоняться во всех runtime entrypoints, включая прямой запуск OTP-приложения. Read-only инспекция проверяет только свой контракт чтения и не требует ещё не реализованного исполнительного пути. Сборка reader не является разрешением запустить агентную обработку доски.

## 4. Предлагаемая конфигурация

Ниже проект нового контракта, а не готовая к запуску конфигурация. `tracker.kind: github_projects`, ключи его `provider` и раздел `validation` предстоит реализовать. `agent.max_concurrent_agents` и `workspace.root` уже поддерживаются Symphony.

```yaml
tracker:
  kind: github_projects
  provider:
    organization: EmotionStat
    project_number: 1
    repo: EmotionStat/app
    # Для пилота: item_ids с единственным реальным node ID выбранной карточки.
    # При отсутствии item_ids действует весь разрешённый scope проекта/repo.
    token: $GITHUB_TOKEN # Заранее выданный read-scoped installation token App для PR-02; автоматическое обновление добавляется в PR-03.
    fields:
      status: Status
      agent_allowed: Agent allowed
    agent_allowed_value: "yes"
    states:
      ready: Ready for agent
      working: Agent working
      blocked: Needs human decision
      handoff: PR ready
    context_fields:
      - Area
      - Risk
      - Environment impact
      - Acceptance command
      - Preview URL
      - Decision owner
  active_states:
    - Ready for agent
    - Agent working
  terminal_states:
    - Done

agent:
  max_concurrent_agents: 1

validation:
  mode: manual

workspace:
  root: /absolute/path/to/agent-workspaces # Заполняется под выбранный runtime в профиле runner.
```

`provider.states` задаёт роли переходов инструментов; `active_states` и `terminal_states` определяют существующую политику scheduler. Валидация проверяет их согласованность: ready/working активны, blocked/handoff не активны и не терминальны, наборы не пересекаются.

Дополнительно реализовать конфигурацию ожидания полного цикла. Это отдельный контракт допуска, не новое значение `active_states`:

| Настройка профиля | Требование MVP |
| --- | --- |
| Репозиторий / базовая ветка | `EmotionStat/app` / `dev`, согласованы с tracker и PR tools |
| Число незавершённых циклов | `1`, независимо от `agent.max_concurrent_agents` |
| Deployment workflow | `.github/workflows/deploy-development.yml`; проверить и закрепить его API ID, ветку и разрешённые события `push`/`workflow_dispatch` |
| Область deployment | Проверенный набор development Environments/обязательных заданий из workflow; один зелёный job не означает готовность всего окружения |
| Подтверждение готовности | `validation.mode: manual`; авторизованная запись ручной проверки приложения/сценария и требуемого состояния Scheduler/Queue, связанная с repo, dev SHA, версией цикла и workflow run/attempt |
| Polling и предел ожидания | Интервал, backoff и timeout; истечение ожидания создаёт блокирующую причину, но не открывает очередь |
| Состояние цикла | Постоянный controller-only путь вне workspace; для MVP предлагается versioned JSON snapshot с единственным писателем и атомарной записью |

Политика ожидания, workflow/environment mapping, режим/критерии validation, операторская авторизация и путь состояния входят в restart-only контракт. Профиль исполнения EmotionStat не запускается с выключенным ожиданием или неопределённым способом проверки результата. В MVP принимается явно настроенный `manual`; автоматические post-deploy smoke tests не являются предпосылкой этого режима. Минимальный формат snapshot и процедуры восстановления фиксируются в PR-06 и документации runtime, затем переносятся в ENG-008 при итоговом PR-15; работающее сохранение состояния обязательно уже для пилота. Окончательный исполнимый профиль готовится в PR-12 по rollout-плану.

Позже отдельным изменением добавить явный `validation.mode: automatic` с настроенными smoke-проверками и проверяемыми результатами. Отсутствие, ошибка или неуспех автоматической проверки никогда не переключают режим в `manual` сами: очередь остаётся закрытой. Смена режима требует операторского изменения restart-only конфигурации и новой проверки состояния; результаты разных режимов не подменяют друг друга.

Имена полей переводятся в реальные IDs после чтения схемы. Обязательны `Status` и `Agent allowed`: оба single-select, опция разрешения определяется по проверенной схеме. Отсутствие, неправильный тип или неоднозначность обязательного поля — ошибка конфигурации. Неизвестное значение разрешения у конкретной карточки — отказ в запуске. `context_fields` опциональны: отсутствующее/пустое значение или неподдерживаемый тип сопровождается диагностикой и не блокирует очередь. Контекст с неоднозначным именем пропускается с диагностикой; нельзя молча подставлять значение другого поля.

Опциональный `provider.item_ids` задаёт дополнительный фильтр конкретных карточек. Для пилота он изначально содержит ровно один ID, полученный при discovery; фильтр одинаково применяется к чтению очереди, refresh, cleanup и инструментам. Инспекция отмечает остальные карточки как `outside_item_scope`. Изменение фильтра входит в restart-only контракт. Recovery не обходит этот фильтр: при необходимости владелец добавляет конкретную карточку восстановления через stop → config/preflight → start с сохранением текущего цикла. Отдельная сверка незавершённой работы, PR и состояния deployment охватывает весь настроенный repo: фильтр исполнения не должен скрывать чужую `Agent working`, открытый PR или изменение `dev` другим участником.

**Переносимость, уточнение владелицы 2026-09-17:** общие launcher/preflight/setup, worker image и transport входят в публичный fork Symphony в PR-11 (`runtime/`); `EmotionStat/agent-runner` в PR-12 содержит проектный `WORKFLOW.template.md` и hooks. Личные WSL distro/accounts, host UID/GID, пути, порты и ссылки на credentials находятся в local config вне git каждого разработчика. Configure формирует исполняемый WORKFLOW по объявленным параметрам; launcher передаёт его абсолютный путь и не зависит от cwd. `runner.example.yaml` не является конфигурацией движка; второй набор трактовок tracker/delivery не создаётся. Подробности и проверки другой установки — [план PR-11](github_projects_setup/pr11-execution-plan.md).

Один назначенный controller исполняет задачи проекта; остальные установки используются для настройки и чтения — подтверждено владелицей. Локальный flock не защищает несколько независимых компьютеров: их одновременное исполнение не входит в этот профиль. Private key рабочего App, operator credentials и store не распространяются с fork/шаблоном. Другим разработчикам нужны права на частные репозитории и отдельно разрешённая read-only identity для живой инспекции.

Владелец подтвердил runtime первой приёмки: **WSL2 на этом компьютере**. Controller и отдельный worker настраиваются в Linux внутри WSL2; проверяются возможности среды, а не совпадение имени distro с машиной владелицы. Hooks требуют `sh`, запуск Codex — `bash`. Пути определяются local config и передаются как данные, без предположения о диске D или username. Нативный Windows и прочие платформы не считаются поддержанными по одной переносимости путей. Строки PowerShell нельзя напрямую вставлять в `sh -lc` hooks. Личные значения в истории подготовки ниже описывают только проведённые проверки и не входят в общие defaults.

Проверка подготовки от 2026-09-15 подтвердила worker tooling, ChatGPT auth и SSH в исходном distro `Ubuntu` под uid 1002, но выявила доступ на запись к Windows home и включённый WSLInterop. Исходная Ubuntu нужна владельцу и для других задач. Создан отдельный WSL2 distro `Ubuntu-26.04`: после рестарта проверены отсутствие Windows drive mounts и отключённый interop; настроен обычный вход под новым `symphony-worker` uid 2002, без sudo/docker. Прежние инструменты и авторизация ещё не перенесены.

**Изоляция O2 ещё не готова:** в новом distro остаются общие WSL/WSLg пути и графические сокеты. Предложен rootless Podman внутри этого distro с отдельными namespaces и минимальными volumes; Podman 5.7.0 уже установлен, под uid 2002 проверены `rootless=true` и UID/GID mappings. Без изменения режима mount `/` успешно выполнен первый запуск временного `ubuntu:26.04` без сети и подключённых папок, с read-only root, отключёнными capabilities и no-new-privileges: получен `CONTAINER_START_OK`. В этом временном контейнере также проверены разные namespace IDs, невидимость перечисленных host/WSL/socket путей, нулевой CapEff, NoNewPrivs=1 и Seccomp=2. Рабочий контейнер, его SSH/volumes/сеть и окончательная изоляция ещё не настроены. Нативная nft socket/cgroup проверка не прошла; совместимый механизм `iptables-nft -m cgroup --path` проверен [локальным тестом](github_projects_setup/check_worker_cgroup_network.py): `SUMMARY PASS` для IPv4/IPv6, отказ только внутри тестовой группы, сохранение соединений вне неё под тем же UID, восстановление после удаления правил и успешная очистка. Этот результат относится к тестовым процессам; размещение настоящего pasta и сетевые ограничения рабочего контейнера/SSH/Codex ещё предстоит проверить. Фактический статус и версии записаны в [плане PR](github_projects_pr_rollout_plan.md). PR-11 должен проверить отсутствие обхода через Windows mounts/interop, общие WSL/WSLg/Docker и сетевые host endpoints, startup-файлы и дочерние процессы, включая после рестарта. Отдельная Linux account, SSH, distro или контейнер сами по себе не доказывают эту границу. До её подтверждения agent/hooks для задач не запускаются. Это ограничение исполнения живых задач, а не начала разработки адаптера: завершение O2 не является условием PR-02–PR-10. Подготовка и приёмка рабочего контейнера, сети, SSH и поведения после рестарта относятся к PR-11/PR-13 и должны завершиться до пилота PR-14; сборка и тесты каждого PR сохраняют собственные требования.

Для постоянного раннера владелица подтвердила **отдельное GitHub App, принадлежащее EmotionStat**, с установкой только для `EmotionStat/app`. Создание и установка ещё не подтверждены. O3a — регистрация/установка владельцем и передача материалов по [инструкции](github_projects_setup/github_app_owner_setup.md); O3b — подключение для чтения после PR-03; O3c — финальная проверка scoped writes и worker credentials после PR-09 в рамках PR-11/PR-12. Первый live dry-run O4 выполняется после PR-03/O3b; PR-02 до этого разрабатывается и принимается на синтетических fixtures. Installation token истекает через час, поэтому PR-03 реализует credential provider с автоматическим обновлением на controller. Статический read token в примере выше нужен для ранней инспекции и не заменяет этот механизм. Приватный App key не передаётся worker; tools привязываются к неизменному scope и ссылке на provider, а не навсегда к значению истекающего токена. Fallback на личный или служебный PAT не входит в выбранный профиль: истечение, отзыв установки или неуспешный refresh закрывают новый допуск, а не расширяют права. [Installation tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app).

## 5. Чтение и нормализация

### 5.1. API

Использовать GraphQL Projects V2: один запрос может вернуть карточку, поля и связанную issue, а node IDs подходят для пакетной сверки. REST Projects тоже существует; GraphQL выбран ради этих свойств, а не из-за отсутствия REST.

1. Найти `organization(login) → projectV2(number)` и ID проекта.
2. Прочитать поля и опции с полной пагинацией; проверить ожидаемые типы и названия.
3. Прочитать страницы `items` с `id`, `project.id`, `isArchived`, `content` и нужными значениями полей.
4. Для issue получить ID, номер, репозиторий, название, body, URL, open/closed, labels, assignees и timestamps.
5. Нормализовать и применить одинаковые правила при чтении очереди и обновлении по ID.

Connection-пагинация обязательна для items, fields и используемых labels/assignees. Значения настроенных полей карточки читать через `fieldValueByName` после discovery и сверять возвращённый `field.id` с найденным ID: поиск по имени возвращает первое совпадение. При использовании `fieldValues` обходить все его страницы. Нельзя молча ограничить очередь первой сотней карточек. Для `fetch_issues_by_ids` использовать `nodes(ids)` ограниченными пакетами и проверять принадлежность каждой карточки настроенному проекту и репозиторию. [Схема Projects](https://docs.github.com/en/graphql/reference/projects), [пагинация](https://docs.github.com/en/graphql/guides/using-pagination-in-the-graphql-api), [nodes](https://docs.github.com/en/graphql/reference/meta).

Список items по умолчанию исключает архив. Активный polling может исключать архив, но чтение по ID должно распознавать `isArchived`. Для инспекции `dry_run` и чтения `Done` при startup cleanup явно использовать `archivedStates: [ARCHIVED, NOT_ARCHIVED]`. Отсутствие карточки в обычной очереди не доказывает её удаления.

### 5.2. Модель

| Поле Symphony | Источник / правило |
| --- | --- |
| `id` | Глобальный node ID Project item; не номер issue |
| `identifier` | Детерминированный безопасный ключ из ID карточки, уникальный в scope и устойчивый к переименованию issue; проверить отсутствие коллизий после sanitization |
| `title`, `description`, `url` | Связанная issue |
| `state` | Значение Project `Status`; open/closed issue хранится отдельно |
| `dispatchable` | Видимая неархивная карточка с открытой issue из настроенного repo и `Agent allowed = yes` |
| `labels`, `assignee_id` | Нормализованные данные issue; поле допуска не превращать в искусственный label |
| `priority` | `nil` в MVP: поле `Risk` не подменяет приоритет |
| `native_ref` | Project/item/issue IDs, repo, номер issue, field/option IDs и явно выбранный контекст карточки |

`created_at`/`updated_at` брать из timestamps issue с существующим разбором дат; `blocked_by` оставить пустым, если нет проверяемого источника зависимостей. Не выводить зависимости из названий колонок.

В `native_ref` включать только необходимые JSON-совместимые несекретные значения. Существующий PromptBuilder уже передаёт структуру агенту; копировать полный сырой API-ответ в prompt не нужно. Метаданные сохранять под явным ключом `project_fields`.

`Acceptance command` передавать как данные задачи. Не подставлять его непосредственно в shell hooks. Агент сверяет команду с правилами репозитория и выполняет проверки в workspace. Acceptance criteria остаются в body issue; их отсутствие требует handoff человеку до реализации.

Разделить читаемость и допуск: карточки `Done`, закрытые issues и `Agent allowed = no` должны оставаться различимыми при сверке по ID. Нельзя отфильтровать их так, что scheduler примет изменение допуска за ошибку API.

Незаполненный `Status` не заменять на выдуманное состояние: нормализованный `Issue.state` должен быть непустым. В инспекции показать `missing_status`, в очереди такую карточку не запускать. Для уже работающей карточки отсутствие корректного статуса возвращает ошибку refresh; действует существующая семантика ошибок ниже. Для гарантированной остановки через очередной успешный refresh предусмотрены валидный неактивный статус или отзыв допуска, а не очистка поля Status.

### 5.3. Ошибки

HTTP 200 не гарантирует успех GraphQL. В MVP непустой `errors`, оборванная пагинация, некорректный envelope, transport/auth/rate-limit error означают ошибку **всей операции**, а не успешный частичный список. Не логировать токены и полные тела приватных задач. Учитывать доступный `Retry-After`/rate-limit metadata при повторных запросах; не вводить бесконечный цикл внутри client. [Ограничения GraphQL](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api).

Сохраняется текущая семантика Symphony: ошибка refresh не запускает новую задачу, но уже работающий агент при ошибке фоновой reconciliation остаётся работать по последнему известному состоянию. Отзыв разрешения останавливает его после успешного обновления, а не мгновенно. Недоступность всего проекта — ошибка; подтверждённое отсутствие отдельной карточки при полном успешном ответе — missing item.

Если `nodes(ids)` возвращает ошибку отдельного узла, не принимать его частичный ответ за доказательство удаления. Подтвердить отсутствие отдельным полным успешным чтением IDs карточек настроенного проекта, включая архив. Только подтверждённо отсутствующие IDs можно опустить; для присутствующих элементов нужны успешные данные. Если контрольное чтение неполное или недоступен весь проект, сохранить ошибку операции. Redacted content и потерю доступа к issue не называть удалением; показать отдельную диагностику, не создавать новый запуск и не разрешать инструменту запись по устаревшему допуску.

## 6. Статусы, повторный запуск и reload

| Статус / событие | Поведение |
| --- | --- |
| `Backlog` | Не запускать |
| `Ready for agent` + разрешение | Новая работа только после проверки допуска по циклу repo; агент сначала выполняет операцию начала работы |
| `Agent working` + разрешение | Продолжение существующего workspace/ветки/PR; допускается восстановление после рестарта |
| `Needs human decision` | Остановить работу, сохранить workspace и причину в issue |
| `PR ready`, `Human review`, `Dev validation`, `Ready for production` | Остановить обычную реализацию, сохранить workspace |
| `Done` | Остановить worker; cleanup только после проверки сохранённого цикла и правил сохранения работы ниже |
| Разрешение отозвано, issue закрыта, карточка архивирована | Не запускать / остановить после успешной сверки; сохранить фактический статус |
| Карточка удалена или вышла из scope | Остановить после подтверждённого отсутствия; сохранить workspace |
| API временно недоступен | Вернуть ошибку; сохранить существующую политику retry/reconciliation |

Терминальное состояние имеет приоритет для остановки worker, но не является разрешением удалить его работу. Для github_projects startup, running, blocked и retry cleanup сначала проверяют загруженный и сверенный store: workspace владельца незавершённого цикла или recovery сохраняется даже при Done, отзыве разрешения или архиве. При неизвестном/повреждённом store очистка запрещена. Удаление возможно после зафиксированного завершения цикла либо явного решения оператора с сохранением нужной работы; исторический workspace с неизвестным владением передаётся на сверку. Это изменение PR-08; существующий безусловный terminal cleanup других trackers не меняется.

**Владение задачей.** `Agent working` — состояние процесса, не распределённая блокировка. Перевод статуса не имеет compare-and-set. `max_concurrent_agents: 1` действует внутри одного Symphony. В MVP один авторитетный runner обслуживает этот scope; launcher предотвращает второй локальный запуск. Перед первым запуском проверить все уже имеющиеся `Agent working` и убедиться, что их не исполняет другой runner. Между разными хостами исключение обеспечивается организационно; распределённый lease в эту версию не входит.

Сейчас Symphony может подхватить любую подходящую карточку `Agent working`; это не доказательство предыдущего владения. Новая проверка допуска сначала восстанавливает сохранённый цикл и разрешает только его работу или явно назначенное recovery. Посторонняя `Agent working` блокирует автоматический старт до сверки владения, а не присваивается без проверки. Workspace, комментарий-отчёт, ветка и PR помогают восстановить работу; сохранение Codex conversation между процессами не обещается. Существующая сортировка применяется только к карточкам, прошедшим проверку допуска.

Продолжать только открытый PR. Если предыдущий PR закрыт или merged, новая допустимая попытка начинается от актуального `dev` в новой ветке; старый PR не открывается заново автоматически. Сначала применяются условия цикла ниже: merged PR означает ожидание deployment, а не автоматический повтор реализации. Если критерии новой работы не определены, требуется human decision. При удалении и повторном добавлении issue создаётся новый item ID и новый workspace; существующий открытый PR всё равно искать по ID связанной issue, отчёту и repo/head, чтобы не создать дубликат.

### 6.1. Допуск следующей задачи после готовности dev

```text
проверенный актуальный dev
  → задача A → ветка A → PR A → review → ручной merge в dev
  → ожидание deployment этого dev SHA → ручная проверка dev оператором
      → успех и dev по-прежнему на проверенном SHA: разрешить задачу B
      → сбой или неизвестный результат: обычная очередь закрыта
          → согласованное восстановление → повторный deployment/validation
```

Резервирование цикла выполняется до запуска первой задачи и сохраняется до подтверждённой готовности `dev`. Worker может завершиться при `PR ready`, возвращаться для исправлений в том же открытом PR и вновь завершаться. Ожидание review/merge/deploy выполняет polling раннера без активной Codex-сессии. `PR ready`, `Human review` и `Dev validation` остаются неактивными статусами. Освобождение цикла не выставляет `Done` и не требует ожидать production release.

Глобальную занятость repo нельзя записывать в `Issue.dispatchable`: это поле также используется для остановки уже работающего агента. Нужна отдельная проверка допуска перед новым dispatch и retry. Она различает новую обычную задачу, продолжение владельца цикла и назначенное восстановление. Все три пути сохраняют проверки scope, статуса и `Agent allowed`; восстановление не получает исключений из прав доступа.

Проверки только перед dispatch/retry недостаточно: уже работающая обычная задача сейчас проверяет лишь статус и routability. Поэтому решение цикла должно иметь отдельный путь управляемой паузы worker с сохранением workspace и владельца; recovery запускается после подтверждённой остановки этого worker. Не менять `Issue.dispatchable` ради такой паузы. Модель цикла и существующий runtime supervisor согласуют остановку/восстановление, чтобы падение владельца состояния не оставляло независимого исполнителя без контроля.

Перед открытием очереди проверить последовательно:

1. PR текущего цикла действительно merged в `dev`; сохранить PR ID, head ветки и SHA результата merge. Закрытый без merge PR требует явного решения о повторе или отмене цикла, автоматического освобождения нет.
2. Получить текущий SHA `dev` и найти ожидаемый workflow для этого SHA. Сверять repo, workflow ID/path, ветку, событие, `head_sha`, `run_id`, `run_attempt`, `status` и `conclusion`; учитывать обязательные задания и development Environments. Старый зелёный запуск, PR CI или успех другого workflow не подходят. Если `dev` уже изменился, прежнего merge SHA недостаточно: проверять deployment и validation нового head. Поля запусков и фильтры описаны в [REST API workflow runs](https://docs.github.com/en/rest/actions/workflow-runs).
3. Дождаться `status=completed`, `conclusion=success` актуального deployment и успешного выполнения обязательных finalizers/заданий. Pending, failure, cancellation, skipped/neutral, timeout, отсутствие запуска или недоступный API не означают успех. Новый rerun инвалидирует прежнее подтверждение: привязать результат к актуальной попытке, дождаться её завершения и повторить ручную проверку.
4. В режиме `manual` получить положительный результат ручной проверки уполномоченного оператора для того же repo, dev SHA, цикла и workflow run/attempt по §6.4. Успех Actions — необходимое, но недостаточное условие. Без такой записи состояние остаётся `awaiting_dev_validation`; произвольный комментарий, поле карточки или заявление исполняющего агента не открывает очередь.
5. Перед следующей задачей снова успешно fetch `origin/dev` и сверить SHA с подтверждённым deployment/validation. При несовпадении вернуться к ожиданию. На первом запуске без предыдущего цикла такая же проверка устанавливает исходную готовность `dev`; отсутствие данных не считается готовностью.

**Контракт deployment для наблюдателя.** В отдельном app PR закрепить явное машиночитаемое свидетельство выполнения deployment: версия формата, repo/ref/deployed SHA, workflow/run/attempt, результаты обязательных jobs/finalizers и признак допуска к ручной проверке. Оно не является smoke-тестом и не утверждает работоспособность приложения. Сверять свидетельство с API текущего запуска и проверенным workflow; одного имени job или `conclusion=success` недостаточно при произвольном checkout, `continue-on-error` или пропусках обязательных этапов.

Не искать «любой зелёный run» и не ограничивать запросы только успешными результатами. Для одного SHA могут существовать несколько запусков и повторных попыток; новое ожидание/ошибка отменяет прежнюю готовность. Перед validation учитывать релевантные development-запуски и других SHA: rerun старого workflow сохраняет прежние SHA/ref и не должен перезаписать уже проверенную среду. App PR проверяет сериализацию, запрет устаревших изменений и принадлежность восстановительных действий нужной попытке; неизвестное или перекрывающееся выполнение сохраняет блокировку. Полнота чтения и порядок выбора свидетельства — часть тестируемого контракта, достижение API-лимита результатов не считается полной историей. [Workflow runs](https://docs.github.com/en/rest/actions/workflow-runs), [семантика rerun](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs).

Для MVP предложен полный повтор deployment актуального dev как поддерживаемый способ rerun. Частичный rerun не признаётся подтверждённым deployment без доказательства полного обязательного набора в нужной попытке: очередь остаётся закрытой с понятной причиной, предлагается полный актуальный запуск. Jobs читать для конкретного `run_id`/`run_attempt`, не смешивая неявно результаты разных попыток. Изменять существующий deployment-процесс сверх необходимого контракта только отдельным проверяемым app PR. [Jobs конкретной попытки](https://docs.github.com/en/rest/actions/workflow-jobs).

Освобождение также требует отсутствия работающего worker и незавершённого recovery PR. Если окружение восстановилось разрешённым rerun, пока готовилось исправление, сначала явно завершить или отменить это исправление и сверить его PR; зелёный deployment не допускает вторую задачу параллельно оставшейся работе. Если основная задача была приостановлена ещё до merge, проверки готовности из пунктов 2–5 разрешают возобновить её внутри того же занятого цикла, но не пропускают пункт 1 ради запуска следующей задачи. Неожиданное переписывание истории `dev`, из которой исчез результат merge текущего цикла, требует решения оператора даже при успешном deployment нового head.

По текущему канону EmotionStat сбой может оставить применённые миграции, частично обновлённые компоненты, отключённый Scheduler и Queue на паузе. Повторный успешный деплой не снимает паузу Queue, унаследованную от предыдущего сбоя. Поэтому в MVP оператор вручную проверяет приложение и применимый пользовательский сценарий, фактическое требуемое состояние Scheduler/Queue и при необходимости результат операторского возобновления с проверкой доставки. Критерии фиксируются до пилота в плане форка и исполняемом профиле с учётом [deployment flow](</D:/work/EmotionStat/knowledge-base/70_Engineering/Deployment/GitHub Cloudflare Deployment Flow.md>); автоматический rollback миграций, включение Scheduler или снятие паузы Queue в адаптер не добавляются.

Блокировка раннера ограничивает его очередь, но не запрещает merge другим участникам GitHub. Человеческий процесс должен также сериализовать изменения `dev` на время deployment; фактические branch rules и обязательные PR checks проверяются отдельно. Перед публикацией/обновлением PR повторно проверять состояние цикла и `dev`. При стороннем изменении и ещё не подтверждённой готовности `dev` приостановить дальнейшую публикацию обычной задачи, сохранив работу. Явно назначенное recovery может публиковать свою ветку и создавать/обновлять свой PR при сломанном dev после проверки владения, scope, допуска и актуального dev SHA; требовать от него уже здорового окружения означало бы заблокировать само исправление. После восстановления синхронизировать ветку обычной задачи с актуальной `dev` и повторить проверки. Между API-проверкой и удалённым действием нет общей транзакции: защита от устаревшей базы при merge должна действовать на стороне GitHub. Эта политика уменьшает пересечение задач, но не обещает отсутствие любых конфликтов.

### 6.2. Ошибка после merge и восстановление

- Не открывать обычную очередь. Сохранить стадию сбоя, SHA, run/attempt, ссылку на лог и причину ожидания; не запускать агента просто для ожидания.
- Человек определяет способ восстановления: повторить deployment при подтверждённой временной ошибке инфраструктуры или назначить конкретную issue на исправление. В MVP раннер наблюдает за повторным запуском Actions; сам rerun/deploy не выполняет.
- Карточка исправления должна иметь явную связь с текущим циклом, блокирующим результатом deployment или ручной validation и соответствующими run/attempt/SHA, `Agent allowed = yes`, активный допустимый статус и входить в настроенный scope. Неуспешная ручная проверка может относиться к зелёному Actions run; не требовать `conclusion=failure` для такого назначения. Назначение делает уполномоченный оператор через проверяемую запись управления раннером. Агент не назначает себе recovery, не выставляет разрешение и не создаёт recovery issue автоматически. Одновременно разрешено только одно такое исправление внутри занятого цикла.
- Для исправления после merge создать **новую ветку от свежего текущего `origin/dev` и новый PR в `dev`**. Это единственное исключение из требования уже здорового dev при начале новой ветки: recovery работает с текущим сломанным состоянием. Прямой push в `dev`/`main` по-прежнему запрещён; review и merge выполняются человеком.
- Новый merged PR или разрешённый rerun ведёт обратно к ожиданию deployment и validation. Повторная ошибка сохраняет блокировку; следующий recovery назначается явно. Успешное восстановление может завершить исходный цикл без ожидания production-статуса, только если основной PR уже merged и нет незавершённого исправления. Если основная задача остановлена до merge, сохранить её владение циклом и возобновить её; следующая обычная задача остаётся заблокированной. Явная отмена выполняется по процедуре §6.3.
- Если другая задача уже выполнялась при обнаружении сбоя или при подключении раннера, сохранить её изменения/workspace, приостановить исполнение и дальнейшую публикацию. Восстановление получает допуск после остановки этого worker; после готовности dev сохранённая задача проходит повторную сверку базы и проверки. Не удалять коммиты и не делать автоматический reset.

### 6.3. Сохранение цикла и восстановление раннера

Состояние цикла хранить независимо от процессов Codex и каталогов задач. Минимальные данные: версия формата, версия состояния цикла и scope конфигурации, repo/ветка, ID цикла и основной item/issue, текущая стадия, рабочая ветка/PR, base/merge/current-dev/validated SHA, workflow/run/attempt, режим validation и запись результата с критериями, evidence, подтверждённым actor и серверным временем, назначенный recovery, приостановленная работа, причина блокировки и timestamps. Секреты, полный body issue и необработанные deployment logs в store не помещать.

Предлагаемый минимальный store — versioned JSON snapshot под доверенной учётной записью controller. Один процесс владеет всеми переходами; snapshot содержит версию состояния и данные идемпотентности. Сохранение выполняется через временный файл, flush и атомарную замену на выбранном runtime; crash-consistency и восстановление проверяются на этом runtime. Резервирование фиксируется до dispatch, освобождение — только после проверок готовности. Ошибка записи запрещает новый dispatch. После crash сначала загрузить store и сверить PR, dev и Actions с GitHub, затем решать о продолжении; старое локальное значение «готово» само по себе не открывает очередь. Неопределённый результат внешней операции разрешается чтением GitHub, без слепого повторения PR или запуска второй задачи. Логи полезны для диагностики, но не подменяют авторитетный snapshot; downgrade с несовместимым форматом не создаёт пустое состояние.

Утрата/повреждение ранее существовавшего store, несовместимый scope и неоднозначное владение требуют восстановления состояния оператором при закрытой очереди. Первый запуск явно проходит bootstrap: сверка незавершённых задач/PR и готовности dev. Отсутствующий файл нельзя трактовать как автоматически свободный repo. Остановка процесса, удаление карточки, отзыв допуска, закрытие issue или cleanup `Done` не освобождают цикл и не удаляют его запись. Отмена до merge требует явного решения и повторной проверки исходного dev; после merge сначала необходима подтверждённая готовность окружения.

**Reload.** Сейчас scheduler читает новые настройки, а инструменты уже запущенной сессии используют привязанные старые настройки. Поэтому смена tracker kind, организации, проекта, repo, mapping полей/переходов, workspace root и контракта ожидания цикла во время работы должна реально отклоняться, а не только запрещаться текстом документации. Restart не отменяет занятого цикла; изменение scope требует явной сверки/переноса состояния, а не создания пустого store.

Добавить узкую проверку reload до принятия нового состояния WorkflowStore: для текущего или нового `github_projects` сравнить контракт запуска; при несовместимости сохранить последнюю корректную конфигурацию и вернуть `restart_required`. Провайдерскую часть сравнения держать в адаптере через необязательный callback Tracker, общий вызов — в Config/WorkflowStore. Не менять политику других адаптеров. Изменение scope выполняется stop → новая конфигурация → preflight → start. Выбранный GitHub App provider обновляет истекающий token без изменения bound scope; смена App/installation/repo/permissions требует повторного preflight/restart. Не логировать сравниваемые секреты.

### 6.4. Ручная проверка dev и интерфейс оператора

В MVP владелец проекта или назначенный им оператор подтверждает фактическую проверку dev. Панель — дополнение существующего dashboard Symphony; описанные серверные операции предстоит реализовать. Текущий интерактивный макет только показывает сценарий и не сохраняет подтверждение в настоящем runner.

1. После успешного актуального deployment и обязательных finalizers показать отдельные состояния «Deployment успешен» и «Ожидается ручная проверка dev». Кнопка **«Подтвердить ручную проверку dev»** открывает форму с repo, dev SHA, исходной задачей/PR, workflow run/attempt и ожидаемой версией цикла.
2. Оператор проверяет приложение, применимый сценарий и заданные для этого профиля критерии Scheduler/Queue. В форме фиксирует результаты критериев, общий результат **«Пройдена» / «Не пройдена»** и обязательный комментарий о том, что проверено; при наличии добавляет ссылку на evidence. Отметки заранее не проставляются. Положительный результат требует выполнения всех обязательных критериев; допустимая неприменимость определяется профилем, а не произвольным снятием требований в форме.
3. Действие **«Записать результат»** передаёт ожидаемые cycle ID/version, repo/ветку/dev SHA, workflow ID, run ID/attempt и результаты формы. Сервер определяет actor из авторизованной операторской сессии и время сам; значения actor/time из клиента не являются доказательством полномочий.
4. Непосредственно перед атомарной записью сервер заново проверяет авторизацию, версию/стадию цикла, актуальный dev SHA и нужный deployment/run/attempt с успешными finalizers. Смена SHA/run/attempt, изменение цикла, неопределённый ответ API или конфликт параллельной записи отклоняют устаревшее подтверждение и требуют обновить данные и повторить проверку. Проверка версии и сохранение результата выполняются через единственного владельца store; ошибка записи не открывает очередь. Повтор одного принятого запроса идемпотентен и не перезаписывает более новый результат.
5. Запись связывает `mode=manual`, repo/ветку/dev SHA, cycle ID/version, workflow ID/run ID/attempt, подтверждённого actor, серверное время, результаты критериев, общий result и evidence (обязательный комментарий, дополнительные ссылки при наличии). Отрицательный результат сохраняет блокировку и причину; recovery issue не создаётся и не назначается автоматически. После устранения проблемы новое подтверждение требует повторной ручной проверки и свежей сверки.
6. Положительная запись разрешает только следующий допустимый переход цикла по §6.1: если основной PR ещё не merged, возобновить владельца в том же цикле, не задачу B; если merged, закрыть цикл лишь при выполнении остальных условий, включая отсутствие незавершённого recovery. Отдельной кнопки безусловного «Продолжить очередь» нет. Последующая смена dev SHA или rerun делает прежний результат неприменимым; сервер снова удерживает очередь до нового актуального подтверждения.

Доступ к подтверждению проверяется сервером и операторским каналом, а не только видимостью кнопки. Исполняющий агент не получает инструмент подтверждения и не может самоутвердить dev через CLI, control endpoint или прямую запись store. Если CLI/сервер и агент работают под одной OS-учёткой с одинаковым доступом к управляющему каналу или файлу состояния, это ограничение не обеспечено: требуется отдельный операторский контекст либо защищённый канал с недоступными агенту полномочиями и запретом обходной записи. Эта граница должна быть реализована и проверена до live-пилота; макет интерфейса её не обеспечивает.

Единственный оператор MVP — сама владелица проекта, подтвердившая это решение; её operator principal и серверный human actor отделены от GitHub App bot. Она выполняет review/merge в GitHub, ручную проверку dev и разрешение/назначение recovery через защищённый операторский канал. Выбор оператора не доказывает фактические GitHub-права и доступ к панели: они проверяются в O3/O6 до live-пилота.

В текущем dashboard операторской авторизации нет; конфигурация endpoint содержит статический `secret_key_base` и выключенный `check_origin`. Изменение формы должно включать настоящую серверную аутентификацию выбранного оператора, уникальный deployment secret, защиту Origin/CSRF и session, а не только новый обработчик кнопки. Предлагаемый профиль использует существующий `worker.ssh_hosts`: controller хранит snapshot/operator credentials, Codex и hooks работают под отдельной worker OS account внутри проверенной границы исполнения. В WSL2 такая account сама по себе не обеспечивает изоляцию; дополнительные требования и отрицательная проверка текущего окружения описаны выше и в PR-11. Отсутствие доступа worker к controller/store/операторским секретам проверяется до исполнения; доступ только через loopback сам по себе не доказывает личность оператора.

### 6.5. Согласованные бюджеты пилота и повторы — 2026-09-16

**Решение владелицы зафиксировано; в PR-06 реализованы хранение, счётчики и резервирование.** [PR-08](delivery_runtime.md) подключает внутренний lifecycle, измерение времени и отзыв допуска; обычный Projects startup остаётся закрытым. Реальные повторы Actions и панель оператора относятся к PR-09/10, доказанная остановка SSH/Podman — к PR-11. Это отдельные бюджеты controller для `github_projects`, а не переименование `max_turns`/транспортных retries. В исполняемом профиле значения ниже действуют совместно: достижение любого применимого лимита прекращает автоматические попытки, сохраняет работу и удерживает цикл репозитория.

| Этап / ограничение | Лимит пилота | Правило учёта |
| --- | --- | --- |
| Первоначальное выполнение задачи | 60 минут рабочего времени | Изучение кода, реализация, локальные команды/тесты и подготовка PR. Отдельный бюджет от последующих исправлений |
| Исправления после провала PR CI | Ещё 60 минут рабочего времени суммарно; не более 2 циклов исправления | Диагностика → изменение → локальная проверка → публикация → результат CI. Число циклов не равно числу коммитов |
| Повторы PR CI при подтверждённом временном инфраструктурном сбое | Не более 2 повторов на одном SHA, задержки 1 и 3 минуты | Повторяется весь согласованный PR workflow без изменения кода; неопределённая причина не считается временным сбоем |
| Общий бюджет PR CI | Не более 6 запусков/попыток в одном автоматическом цикле задачи | Включает первый запуск, проверки новых версий кода и инфраструктурные повторы. Один запуск — весь набор проверок, не каждый job/тест. Verify после merge и deployment сюда не входят |
| Основной job `verify` | 20 минут на запуск | По сообщению владелицы нормальная длительность 4–5 минут; заменить текущие 45 минут при реализации PR-04. Timeout не означает успех |
| Ожидание GitHub Actions | Не расходует рабочее время агента | Worker приостановлен/завершён, controller наблюдает за CI без активной Codex-сессии. Неизвестный результат сохраняет блокировку |
| Ожидание review или решения оператора | Без автоматического срока отмены задачи | Работа и цикл сохраняются; новую обычную задачу не выдавать |

Рабочее время — длительность активного исполнения worker, включая локальные команды и тесты, а не CPU-время и не оценка времени «размышлений» модели. Чтобы ожидание Actions/оператора не расходовалось, runtime должен фактически приостановить исполнение и зафиксировать фазу ожидания; свободный текст агента «жду» сам по себе счётчик не останавливает.

Автоматический максимум исходного выполнения плюс исправлений — 120 минут рабочего времени. Неиспользованные минуты не переносятся между бюджетами: исчерпание первоначальных 60 минут не разрешает автоматически потратить бюджет исправлений. Это не обещание завершения задачи за два календарных часа: ожидания учитываются отдельно. Изменения по замечаниям review требуют явного разрешения оператора продолжить с дополнительным бюджетом; автоматического обнуления нет.

При успехе попытки №6 PR можно передать на review; если успеха нет, попытка №7 требует решения оператора. Устойчивое падение теста требует исправления кода, а не повторных запусков того же SHA. Ошибки прав/секретов, неоднозначные требования и отмена запуска оператором не вызывают автоматических повторов. Отмена старого запуска из-за нового коммита не является инфраструктурным сбоем и не должна порождать rerun. Предыдущая начатая попытка остаётся учтённой; новая версия кода не обнуляет общий бюджет.

Счётчики привязаны к сохранённому циклу задачи на controller, а не к процессу Codex, SHA или локальной ветке. Рестарт/reload, новая сессия, коммит, возврат из review и автоматическое переподключение не сбрасывают их. Перед выдачей новой попытки controller атомарно резервирует бюджет. Наблюдение повторного события GitHub с теми же run ID/attempt не списывает бюджет повторно; потерянный ответ публикации/rerun сначала сверяется с GitHub и не вызывает слепой повтор. Операции человека нельзя ограничить этим счётчиком: внешний ручной запуск наблюдается и фиксируется, но не выдаёт агенту дополнительный бюджет автоматически.

При исчерпании лимита controller прекращает автоматическую работу, сохраняет workspace/коммиты/PR и причину остановки, показывает `Needs human decision`. Цикл репозитория остаётся занят. Дополнительное время/попытки выдаёт только оператор с причиной и журналом решения. Восстановление из неизвестного состояния учёта оставляет очередь закрытой; недопустимо трактовать потерянные счётчики как нулевые. Реализация должна учитывать активное время после аварии без выдачи заново уже использованного бюджета; проверить сохранение прогресса учёта и сверку оставшегося worker.

Текущее App имеет Actions read: автоматические reruns ещё недоступны. До отдельного согласования Actions write для controller и реализации ограниченной операции повтор выполняет оператор. Worker прав записи в Actions не получает. Автоматический повтор deployment и самостоятельное разрешение recovery запрещены; эти операции требуют отдельного решения оператора и не покрываются бюджетом PR CI.

**Распределение реализации:** PR-04 — общий `verify` до merge и перед deployment, таймаут 20 минут; PR-06 — постоянные бюджеты, счётчики и резервирование; PR-07 — идентификация SHA/run/attempt и сверка результатов; PR-08 — учёт времени, пауза/остановка и пределы циклов исправления; PR-09 — ограниченные операции публикации/повтора, без слепого воспроизведения; PR-10 — отображение расходов и явное добавление бюджета оператором. Проверки реализации включают границы 60/60 минут, 2 исправления, 2 повтора на SHA, 6 CI-попыток, ожидание без worker, отмены, повторные события и перезапуск без сброса.

## 7. Операции агента и передача PR

Адаптер предоставляет ограниченный набор операций: прочитать контекст текущей задачи; создать/обновить комментарий-отчёт; начать работу; подготовить/обновить PR; передать PR; зафиксировать блокирующее решение.

Использовать уже передаваемый `opts[:issue]` и `native_ref`. Project/item/repo определяются из контекста сессии; агент не получает возможность указать произвольную чужую карточку. Перед записью перечитать карточку, проверить scope, актуальный допуск и допустимый исходный статус.

Разрешённые переходы агента:

- `Ready for agent` → `Agent working`;
- `Agent working` → `PR ready`;
- `Agent working` → `Needs human decision`;
- повтор уже подтверждённого перехода возвращает идемпотентный результат без повторных побочных действий.

Агент не меняет `Agent allowed`, не возвращает сам себе задачу из review и не выставляет `Done`. Возврат человеком в `Ready for agent` ведёт к поиску существующего PR по задаче/ветке, а не к созданию дубликата.

Изменения single-select выполняются по IDs через `updateProjectV2ItemFieldValue`; read-before-write уменьшает риск устаревшего действия, но не является транзакционной блокировкой. [Управление Projects](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects).

### Ветка каждой задачи и запрет прямого push

Обязательная последовательность для новой задачи:

```text
актуальный origin/dev
  → отдельная agent/<type>/<issue-id>-<short-title>
  → изменения, коммиты и проверки в этой ветке
  → push только этой ветки
  → PR: head = ветка задачи, base = dev
  → CI и human review
  → merge PR в dev по процессу человека
```

1. Перед созданием новой рабочей ветки проверить допуск по циклу, убедиться, что `origin` указывает на настроенный репозиторий, выполнить успешный fetch `dev` и зафиксировать полученный SHA. Для обычной задачи этот SHA должен совпадать с подтверждённым готовым deployment; явно назначенное recovery может начинаться от текущего сломанного dev. Начальная точка новой ветки должна совпадать с полученным SHA. Не использовать устаревшую локальную `dev`, `main`, default branch или ветку другой задачи. Если `dev` отсутствует или fetch не выполнен, остановиться без подстановки другой базы.
2. Создать уникальную ветку `agent/<type>/<issue-id>-<short-title>` в изолированном workspace. Не настраивать для неё upstream на `origin/dev`; после публикации upstream может указывать только на соответствующую удалённую ветку задачи. Коммиты выполняются в рабочей ветке, а не в локальной `dev` или `main`.
3. Перед каждым push проверить ожидаемый remote, текущую ветку и её принадлежность задаче. Указывать назначение явно: `HEAD:refs/heads/<ветка-задачи>`. Не определять назначение по `push.default` или случайному upstream. Операции обновления `refs/heads/dev` и `refs/heads/main` запрещены при любой форме команды, включая явный refspec и force; массовые `--all`/`--mirror` не являются допустимой публикацией задачи.
4. При создании и обновлении PR проверять `head` — ветка текущей задачи, `base` — строго `dev`. Создание PR не является push в `dev`. Агент не обновляет защищённую ветку через GitHub API, merge endpoint или обход branch rules.
5. Если при открытом PR dev продвинулся, продолжение допускается правилами текущего цикла. После fetch изменения актуального dev включаются обычным merge в ту же task branch, без rebase/reset/force push и второго PR. Конфликты разрешаются в scope задачи либо передаются оператору с сохранением работы. Перед публикацией повторяются необходимые проверки и PR CI; обновление dev снова требует сверки. Обычная задача использует подтверждённый здоровый dev, явно назначенное recovery сохраняет исключение для текущего сломанного dev.
6. Retry, перезапуск и исправления после review продолжают **ту же ветку и открытый PR этой задачи**. Не выполнять создание новой ветки или reset к `dev` при каждом `before_run`. Если локальный workspace утрачен, восстановить проверенную удалённую ветку задачи. Для другой задачи или новой попытки после closed/merged PR снова получить актуальный `origin/dev` и создать отдельную ветку, сохранив прежнюю историю.

Распределение ответственности: подготовка ветки — runner/hooks, проверка назначения публикации и PR — инструменты и workflow, запрет прямого обновления `dev`/`main` — также GitHub branch rules без bypass у runner. Обновление полей Project не обеспечивает соблюдение git-правил. До пилота проверить фактическую защиту веток; предусловия в prompt не заменяют её.

Сейчас hooks получают cwd, но не issue/native_ref и не проверенный base SHA. До написания EmotionStat hooks добавить минимальный контракт подготовки workspace: сгенерированный несекретный JSON-контекст с item/issue/repo, видом попытки, рабочей веткой, ожидаемым base SHA и ID цикла; передавать путь явно, одинаково для local/SSH execution. Текст issue и `Acceptance command` не интерполировать в shell. Controller хранит авторитетные значения и проверяет результат; изменяемый worker файл контекста не становится источником разрешения или основанием открыть очередь.

### Завершение без преждевременной остановки

По локальному плану доска переводит item в `PR ready`, когда к issue привязан PR. Это необходимо перепроверить при rollout: следующий poll Symphony может остановить worker сразу после привязки.

Для MVP сохранить действующую автоматизацию и сделать привязку завершающим действием:

1. Завершить код и обязательные проверки.
2. Подготовить полный текст PR: результаты проверок, ограничения и необходимые ссылки.
3. Сохранить комментарий-отчёт и выполнить push только рабочей ветки текущей задачи с явным назначением; при повторном запуске сначала найти существующий открытый PR. Прямой push в `dev` не является частью handoff.
4. Выполнить финальную операцию создания/обновления и привязки PR в `dev` с уже готовым отчётом. Не оставлять обязательных изменений после действия, способного перевести карточку в `PR ready`.
5. Если автоматизация не перевела статус, операция может установить `PR ready`, предварительно повторно проверив статус и допуск. Если статус уже изменён человеком на другой, не перезаписывать его.

При неопределённом ответе создания PR сначала искать созданный PR по repo/head/task, а не повторять создание вслепую. Частичное завершение отражается в комментарии/логах и следующей инспекции. Остановка worker после успешной финальной записи допустима: результат должен уже находиться в GitHub.

Привязку issue↔PR проверять отдельным readback. На `Closes #N` нельзя полагаться, если `dev` не default branch: GitHub в таком случае игнорирует closing keywords и не создаёт связь. Использовать проверенный явный linking API (в текущей схеме — `addCloseIssueReferences`) с подходящими правами либо согласованный операторский способ привязки, проверив фактическую автоматизацию Project. Не обещать переход `PR ready` только по наличию текста в PR. [Правила linking](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue), [схема Issues](https://docs.github.com/en/graphql/reference/issues).

Отдельный обязательный сценарий пилота — исправление уже существующего PR после возврата из review: проверить, не срабатывает ли автоматический переход раньше завершения новых проверок. Если нельзя обеспечить финальную привязку при действующих автоматизациях, до live-пилота требуется согласованное изменение этой автоматизации. `PR ready` не добавлять в активные состояния для обхода проблемы.

### Права

Настроенный токен должен читать проект и приватную issue; для записей нужны соответствующие права Projects, issue comments и PR. Read-only preflight проверяет чтение, а не доказывает возможность всех последующих mutations.

Наблюдению за циклом нужен read-доступ к PR, refs, Actions runs/jobs и выбранному источнику validation; чтение Actions для fine-grained токена требует `Actions: read`. Права на rerun, deployment или изменение Cloudflare для этого не нужны. Проверить полноту чтения private repo в preflight. [Права чтения workflow runs](https://docs.github.com/en/rest/actions/workflow-runs).

Не выдавать новому адаптеру произвольный GraphQL и не считать нынешний неограниченный `github_api` защитой от merge. Инструменты ограничить операциями и текущим repo; target branch PR — `dev`, запрещены merge/deploy и изменение защищённых refs. Права git push проверяются отдельно от прав инструмента.

Токен с `Contents: write` может иметь техническую возможность merge. Защита обеспечивается также GitHub branch rules, отсутствием bypass и production credentials. Это проверяется до пилота; запрет в prompt сам по себе не обеспечивает границу. [Права GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app), [права merge endpoint](https://docs.github.com/en/rest/pulls/pulls#merge-a-pull-request).

Controller API credential с правами записи в Project никогда не передаётся worker: иначе агент сможет обойти scoped tools и самостоятельно выставить `Agent allowed=yes`. Для git worker получает отдельный ограниченный credential только нужного app repo с минимальным `Contents`-доступом, без Projects, Actions-write и операторских прав; либо публикация выполняется через узкую controller-операцию. Способ выбрать и проверить в PR credentials/runtime. Для GitHub App обновление такого git credential также должно работать после многочасового ожидания; приватный ключ и широкий controller token остаются недоступны worker. Branch rules дополнительно ограничивают защищённые refs при любом способе публикации.

## 8. Настоящий dry_run и наблюдаемость

Предлагаемый интерфейс: `symphony --dry-run <WORKFLOW.md>`; точный контракт добавляется с тестами CLI. Команда однократно читает очередь и завершается. Обычный запуск сохраняет текущие требования CLI.

Путь инспекции должен завершаться **без вызова `start_runtime` и без старта runtime supervisor/Orchestrator**. В escript решение принимается до `Application.ensure_all_started(:symphony_elixir)`; в Burrito OTP application уже входит в CLI bootstrap, поэтому нельзя требовать, чтобы приложение вообще не стартовало. Текущий Orchestrator выполняет cleanup сразу при старте: запускать его, а затем запрещать dispatch недостаточно. Успешная инспекция возвращает отдельный конечный результат и exit 0, не переходит в обычный `CLI.wait_for_shutdown`.

Путь инспекции: `Workflow.load(path)` → `Schema.parse` → `Config.validate_settings` → явный вызов read-only клиента с переданными settings. Стартуют только необходимые HTTP-зависимости. Никаких Codex-сессий, hooks, checkout, cleanup, фонового polling или mutations Project/issues/PR/deployment.

PR-02 использует заранее выданный read token. При добавлении GitHub App в PR-03 допустима отдельная конечная выдача read-scoped installation token на controller: это auth-запрос, а не изменение доски. Он не запускает runtime, периодический refresh или запись store. Запрет предметных mutations не равен запрету HTTP POST: и GraphQL queries, и выдача токена используют POST. Тестировать разрешённые операции по их контракту, отдельно от mutation transport записи карточек/PR.

Вывод: project/repo; проверенные поля; карточки, которые будут взяты; карточки, которые будут пропущены; причины `not_ready`, `agent_not_allowed`, `wrong_repository`, `unsupported_item_type`, `archived`, `issue_closed`, `missing_status`. `Agent working` показывать отдельной категорией восстановления. При неполном чтении — ошибка с ненулевым exit code, а не успешная пустая очередь. Не выводить токен или полный body issue.

Инспекция также читает snapshot цикла и PR/dev/Actions/validation без изменения store и показывает `repo_cycle_busy`, `awaiting_merge`, `awaiting_deploy`, `awaiting_dev_validation`, `dev_unhealthy`, `recovery_required` или `state_reconciliation_required`. Для `mode=manual` отдельно показывать ожидающую, принятую, отрицательную или устаревшую ручную проверку и её SHA/run/attempt, actor/время при наличии. При отсутствии подтверждённого состояния нельзя заявлять, что карточка будет запущена: показать отдельно соответствие полям доски и фактический допуск. Dry run не выполняет bootstrap, резервирование или освобождение цикла и не записывает результаты validation.

Для пилота использовать существующие журналы и status/snapshot Symphony. Добавить project/item/issue context, решение о допуске, переход, причину остановки, ссылку на PR, текущий цикл, ожидаемый dev SHA, run/attempt, режим и результат validation с actor/временем. Постоянное хранение цикла обязательно по §6.3; предложенный минимальный versioned JSON формат и эксплуатационные процедуры зафиксировать в соответствующих кодовых PR, затем отразить в ENG-008 при итоговом PR-15. Форму §6.4 добавить в существующий dashboard вместе с защищённым серверным обработчиком; отдельный dashboard, общая БД платформы и новый backend наблюдаемости для этого не требуются.

## 9. Этапы реализации и критерии завершения

Порядок PR, зависимости, состав изменений и проверка владельцем заданы в [подробном rollout-плане](github_projects_pr_rollout_plan.md). Таблица ниже группирует возможности для проверки полноты; номера строк не задают порядок merge. В частности, исполнительные инструменты включаются только после готовности постоянного цикла и допуска scheduler. Настройки GitHub и разрешение live-пилота выделены в rollout-плане в отдельные операторские шаги.

| Этап | Результат | Проверяемый критерий |
| --- | --- | --- |
| 1. Контракт и discovery | Схема provider, `validation.mode: manual`, snapshot полей, fixtures и запрет несовместимого reload | Валидная конфигурация принимается; отсутствующие поля/опции и неоднозначный mapping отклоняются; scope и режим validation не меняются у работающего runtime |
| 2. Читающий адаптер | `fetch_issues_by_states`, `fetch_issues_by_ids`, нормализация и ошибки | Одинаковая политика допуска при poll и refresh; корректная пагинация, архив и IDs; прежний GitHub adapter работает как раньше |
| 3. Read-only CLI | Настоящий `dry_run` и понятные причины отбора | Команда показывает ожидаемую очередь и завершается; ни одного запуска runtime, hook, изменения workspace или API mutation |
| 4. Инструменты и lifecycle | Начало работы, отчёт, PR, handoff, восстановление | Допуск нельзя обойти через tool; повтор не создаёт дубликатов; отзыв допуска/смена статуса останавливает работу; финальная привязка PR не теряет результат |
| 5. Цикл repo и состояние | Отдельная проверка допуска, постоянный store, startup/reload/recovery | Ожидание review/merge удерживает цикл без worker; review retry разрешён только владельцу; restart/ошибки/cleanup не открывают очередь; атомарность и восстановление проверены |
| 6. Наблюдение за dev, ручная проверка и recovery | Чтение PR/Actions, форма существующего dashboard, авторизованная атомарная запись проверки для SHA/cycle version/run/attempt, назначенное исправление | Успех Actions без положительного ручного результата не открывает очередь; stale/отрицательное подтверждение не даёт допуск; агент не может самоутвердить dev; разрешённое recovery проходит через новую ветку/PR |
| 7. Профиль EmotionStat и проверки приложения | Версия Symphony, WORKFLOW/hooks/launcher в agent-runner; проверенные GitHub rules, PR CI, ручные критерии приложения/Scheduler/Queue и операторский доступ | Один экземпляр, один агент и один цикл; обычная задача стартует от свежего вручную проверенного dev SHA; push только в ветку задачи, PR строго в `dev`; прямые обновления `dev`/`main` отклоняются; store и `validation.mode: manual` настроены |
| 8. Единственная pilot issue: исполнение и review | Одна небольшая issue, ограниченная `provider.item_ids` | Ready → Working → PR ready; остальные задачи не запускаются; проверки/отчёт доступны; после возврата используется тот же открытый PR; проверен restart в ожидании review |
| 9. Та же pilot issue: завершение полного цикла | Наблюдение за ручным merge и development workflow, ручная проверка оператором через панель | Merge и зелёный Actions не открывают очередь; проверены критерии и актуальные SHA/cycle version/run/attempt; записаны actor/время/result/evidence; положительный результат допускает только положенный переход, отрицательный сохраняет блокировку без автоматического recovery |

Возможности 1–3 дают отдельный полезный результат без запуска разработки по задачам. Возможности 4–7 добавляют и проверяют исполнение полного цикла; до их готовности live-исполнение EmotionStat не включается. Доработки общего адаптера и продуктовая задача пилота находятся в разных PR.

Лимит параллелизма не ограничивает общее число запусков. Пилот начинает с единственного `item_ids`; при handoff worker завершается, а раннер продолжает наблюдать. Допустима контролируемая остановка/перезапуск launcher для проверки сохранения цикла. После принятого положительного ручного результата dev validation и соответствующего завершения цикла остановить пилот; допуск следующей обычной задачи проверяется в тестах и read-only инспекции, а её live-запуск относится к следующему rollout. При необходимости recovery явно расширить список конкретным ID без потери занятого цикла. Сбой deployment моделировать в тестах или согласованном изолированном окружении, не ломать общий dev ради проверки плана.

По текущему deployment canon `verify` выполняется после попадания коммита в `dev`. До пилота сверить фактический код workflow и настроить применимые CI-проверки на PR до merge, без deployment credentials; закрепить их как обязательные в GitHub. Это отдельная доработка `EmotionStat/app`/GitHub, уменьшающая число ошибок после merge. Она не заменяет ожидание deployment и проверку работоспособности среды.

## 10. Обязательные проверки реализации

1. **Допуск:** yes/no/пустое/неизвестное значение; ready/working/прочие статусы; другой repo; закрытая issue; PR/черновик/redacted; опциональные required labels; `item_ids` не допускает другую карточку даже после завершения первой.
2. **API:** больше одной страницы карточек/полей/labels; HTTP 200 + errors; ошибка на поздней странице; timeout/auth/rate limit; missing node; чужой Project ID; архив; одинаковые номера issues в разных репозиториях.
3. **Lifecycle:** отзыв допуска перед dispatch, во время выполнения и на retry; удаление/архивирование карточки и подтверждение missing после per-node error; переход в nonactive; Done cleanup после разрешённого завершения, сохранение workspace при Done внутри незавершённого цикла и неизвестном store; сохранение workspace при handoff; restart и восстановление открытого PR; новая попытка после closed/merged; повторное добавление issue в проект.
4. **Инструменты:** подмена IDs/repo; недопустимый переход; изменение Agent allowed; запрещённые merge/ref/deploy действия; повторные запросы; неизвестный результат создания PR; смена статуса человеком между запросами.
5. **Handoff:** автоматический PR ready при привязке; остановка в момент финального запроса; существующий PR после review; отсутствие обязательных записей после финального перехода.
6. **Конфигурация:** несовместимый reload действительно отклонён; последняя корректная конфигурация сохранена; привязанные инструменты не переходят в новый scope; смена токена не выводится в лог; старые адаптеры не изменили поведение.
7. **dry_run:** доказать отсутствием вызовов/процессов, что runtime supervisor, Orchestrator, hooks, Codex, workspace create/remove и предметный mutation transport не запущены. Отдельно разрешена конечная auth-выдача read token по §8; она не меняет Project/issue/PR/deployment или store. Проверить исполняемую упаковку, конечный exit и отсутствие фонового refresh, а не только вызов функции в unit-тесте.
8. **Runner:** повторный локальный запуск отклоняется; рабочий каталог не выходит за root, включая symlink/junction; hooks работают в выбранном runtime; branch protections и фактические права проверены на безопасном сценарии.
9. **Ветки и публикация:** открытый PR обновляется merge актуального dev в ту же task branch без потери коммитов/второго PR, конфликты и повторная проверка покрыты; две последовательные задачи получают разные ветки от `origin/dev`, заново полученного для каждой задачи; стартовый HEAD совпадает с зафиксированным SHA; fetch failure/отсутствие `dev` не приводит к fallback; upstream новой ветки не указывает на `origin/dev`; push в `dev`/`main`, `HEAD:dev`, force/mirror, чужая ветка или remote и неправильная база PR отклоняются. Retry сохраняет коммиты и тот же открытый PR; новая попытка после closed/merged начинается от свежего `origin/dev`. Проверки запрещённых записей выполняются на изолированном тестовом remote, а фактические GitHub branch rules и отсутствие bypass проверяются до пилота без пробной записи в живую `dev`.
10. **Цикл repo:** задача A в review при свободном worker блокирует B; возврат A из review продолжает тот же PR. Merge без готовности dev не открывает очередь. Только корректный deployment и validation текущего SHA дают следующий допуск; `Done`, архив, удаление карточки, закрытие issue/PR без merge и ошибки API не освобождают цикл автоматически. Фильтр пилота не скрывает чужую незавершённую работу из сверки repo.
11. **Deployment и validation:** pending/failed/cancelled/skipped/neutral/timeout/missing run, неправильные workflow/ветка/окружение/SHA, поздняя ошибка пагинации и неуспешный finalizer оставляют очередь закрытой. Старый зелёный run или предыдущая попытка после начала rerun не подходят. `dev` изменился перед fetch/dispatch или публикацией — применить повторную проверку и приостановку. В MVP зелёный workflow без принятого ручного результата, с непроверенным обязательным критерием или унаследованной паузой Queue не открывает очередь; отсутствие автоматических smoke tests не подменяет обязательную ручную проверку.
12. **Recovery:** только явно назначенная карточка с собственным разрешением и внутри item scope проходит занятый цикл; произвольная задача со словом recovery не проходит. Назначение возможно после отрицательной ручной validation даже при успешном Actions run, но сам отрицательный результат его не создаёт. После merge исходной задачи создаётся новая ветка от текущей dev и новый PR; исправление вправе выполнить push своей ветки и PR handoff при сломанном dev, обычная B остаётся в ожидании. Успешное исправление или разрешённый rerun закрывают исходный цикл только после validation и завершения/явной отмены оставшегося recovery. Если основной PR ещё не merged, восстановление возобновляет его задачу в том же цикле, не допускает B. Повторный сбой, отзыв разрешения и невозможность recovery сохраняют блокировку; приостановленная работа сохраняет коммиты.
13. **Состояние и crash:** restart до/после spawn, после неопределённого создания PR, в review, после merge, во время deployment/recovery и при освобождении цикла не теряет владельца и не дублирует работу. Ошибка записи, повреждённый/утраченный store и несовместимый scope не означают свободный repo. Workspace cleanup не удаляет запись цикла. Dry run не создаёт/чинит store, не резервирует и не освобождает цикл. Остальные адаптеры при выключенной политике сохраняют прежнее поведение.
14. **Ручная проверка и панель:** после completed/success deployment и finalizers сохраняется ожидание оператора. Обязательные критерии, результат и комментарий записываются с repo/dev SHA, cycle ID/version, workflow/run/attempt, серверными actor/временем и evidence. Смена версии цикла/SHA/run/attempt, потеря авторизации и API unknown между открытием формы и подтверждением отклоняют запись. Ошибка store и повтор запроса не дают двойного освобождения или перезаписи нового результата. Отрицательный результат сохраняет блокировку и не создаёт/назначает recovery. Положительный результат при основном PR до merge возобновляет только владельца; после merge применяется полный gate. Агент не может подтвердить dev через UI, CLI, endpoint или файл состояния; клиентская подмена actor/time не проходит. Restart сохраняет запись, но новая попытка deployment или новый SHA требуют повторной проверки.
15. **Режим validation:** MVP явно принимает `manual`; смена режима/критериев требует restart. При будущем добавлении `automatic` отдельно доказать, что отсутствующие/неуспешные smoke-проверки и ошибки чтения результата не переключают режим на manual и не используют старое ручное подтверждение. До реализации automatic такая конфигурация отклоняется как неподдерживаемая.
16. **Credentials и изоляция:** ожидание review дольше часа и последующий retry работают с обновлённым installation token без смены scope; ошибки обновления/отзыв не дают новый допуск. Ключ App, controller API token с Projects-write, операторская сессия и store недоступны worker-пользователю через файловую систему, env и SSH forwarding. Отдельный git credential не позволяет изменить Project/Agent allowed; его обновление не выдаёт более широкие права. GitHub rules запрещают runner обновлять защищённые refs, включая API merge; наличие токена в git не становится таким разрешением.
17. **Контекст hooks и приостановка:** local/SSH получают одинаковый JSON-контракт; кавычки, переводы строк и shell-синтаксис из issue не исполняются. Новый сбой dev при уже работающей задаче останавливает её worker с сохранением ветки/коммитов и владельца. Recovery не запускается одновременно с приостановленным worker; после восстановления продолжается положенная задача.
18. **Проверки приложения и свидетельство deployment:** PR CI работает без deployment secrets и даёт стабильный обязательный check. Пропуск обязательной проверки не превращает aggregate check в успех. Свидетельство deployment проверяется для фактического SHA, текущих run/attempt и полного набора jobs/finalizers. Запуск старого SHA, неполный rerun и неполная история API не позволяют принять старую готовность dev. Эти сценарии проверяются в соответствующих app PR и тестах наблюдателя.

Во время разработки — targeted tests; перед передачей — `make all`, `mix specs.check`, `git diff --check` согласно `elixir/AGENTS.md`. Для stateful изменений провести независимое adversarial review. Live E2E — opt-in на выбранной тестовой issue; не создавать тестовые задачи и не менять настоящую доску обычным запуском тестов.

Обновить `elixir/README.md`, примеры WORKFLOW и `SPEC.md` там, где добавляются контракт адаптера, inspection CLI, допуск по циклу, ручная validation и операторская панель, сохранение состояния и ограничения reload. Главный README менять только при изменении описания возможностей. В agent-runner сохранить runtime-конфигурацию и инструкции bootstrap, ручной проверки dev, назначения recovery, паузы/возобновления и восстановления store. Канонические решения и результаты пилота перенести в knowledge-base через существующие OPS-002/ENG-008 при итоговом PR-15; сейчас базу знаний не изменять.

## 11. Что уточняется до live-пилота

- Реальная схема и IDs приватной доски, опции `yes`/`no`, видимость нужных issue и существующие `Agent working`.
- Создание и установка выбранного GitHub App владельца EmotionStat, реальные App/installation ID, права Projects/repo, ограниченная git authentication, branch rules и отсутствие bypass/production credentials.
- Готовность выбранного WSL2/дистрибутива и абсолютный Linux workspace root; совместимость hooks, git, Codex и изоляция controller/worker.
- Фактическое поведение привязки нового и существующего PR; подтверждение финального порядка handoff.
- Фактический deployment workflow ID/path, набор development Environments и обязательных jobs; read-доступ к PR/Actions и установленный PR CI до merge.
- Для MVP — точные критерии ручной проверки приложения/сценария и Scheduler/Queue, обязательное содержание комментария/evidence, авторизованный операторский канал и проверка полномочий подтверждающего; формат записи привязывается к repo/dev SHA, cycle version и workflow run/attempt. Разработка автоматических post-deploy smoke tests остаётся отдельным последующим этапом, а не условием ручного режима.
- Путь и эксплуатационная проверка предложенного versioned JSON store; процедура bootstrap, назначения recovery/отмены цикла и восстановления после потери состояния. Формат фиксируется в PR реализации store до исполнения первой задачи; запись ENG-008 обновляется позднее в итоговом PR-15.
- Первая небольшая issue с acceptance criteria и применимыми командами проверки.

Эти проверки не мешают подготовить и протестировать адаптер на fixtures и реализовать read-only инспекцию после принятия плана. В качестве минимального постоянного store предложен versioned JSON snapshot с одним writer; PR реализации должен подтвердить его атомарность на выбранном runtime. Action Register остаётся в knowledge-base. Неподтверждённые решения и operator steps перечислены в rollout-плане; подготовка этих документов сама по себе не включает раннер.

## Выполнение PR-03 — 2026-09-15

По команде владелицы PR-03 выполняется от обновлённой `main` (`00bc204c7002f9c027b1f62d742fe143adfb2e2f`) в ветке `agent/feat/github-app-credentials`; публикация предназначена только для личного форка с base `main`.

O3a: через App JWT проверены App `emotionstat-agent-runner`, owner `EmotionStat`, соответствующая активная installation и права `organization_projects:write`, `actions:read`, `contents:write`, `issues:write`, `metadata:read`, `pull_requests:write`; режим установки `selected`. Публичный fingerprint переданного ключа совпал. Копия PEM установлена только на controller (`Ubuntu`, `nataselko`) в `/home/nataselko/.config/symphony/github-app/private-key.pem` с mode 0600, credential directory 0700. Приватный inspection workflow подготовлен рядом вне checkout. Содержимое ключа, JWT и токены в документы/репозиторий не записываются.

Выдача read-scoped installation token новым кодом и конечное чтение Project подтверждены ниже; общие локальные проверки и публикация PR-03 завершены, результаты приведены ниже. Рабочие задачи, hooks и Codex не запускаются. Knowledge-base, app и agent-runner в этом PR не изменяются. Полная worker isolation остаётся отдельным обязательным условием PR-11/пилота.

### O3b / конечная живая инспекция — PASS

Новый escript с PR-03 получил installation token с точным read-profile и ограничением `EmotionStat/app`; Issuer проверил identity установки, возвращённые permissions и единственный repo до использования токена. Конечный `--dry-run` прочитал Project `EmotionStat / Delivery / 1` и завершился с кодом 0: `execution_enabled=false`, `eligible=0`, `excluded=0`, `total=0`, `diagnostics=[]`. На момент проверки доска пуста; обработка непустых/неподходящих карточек покрывается синтетическими тестами PR-02/03, но не подтверждена этой живой проверкой.

Приватный отчёт сохранён на controller рядом с приватным inspection workflow, вне git. Выполнялись только App authentication и чтение GitHub; workers/hooks/агентские задачи и предметные mutations не запускались. Это подтверждает доступ к целевому repo и ограничение конкретного выданного токена; полный список других repo, выбранных владельцем при установке App, из такого суженного токена не выводится. Локальные планы и приватные настройки не входят в публичный PR.

### Реализация, проверки и публикация PR-03

[Draft PR #2](https://github.com/nataliastaselko8-spec/symphony/pull/2), commit `8475ecd471b441ba6d160762d4ab9f81d0a1c20c`, base `nataliastaselko8-spec/symphony:main`. Реализованы immutable App reference, проверка installation identity/repo/permissions, refresh per request с expiry margin 60 секунд, объединение одновременного refresh, fail-closed/backoff, условная инвалидизация после 401 без replay и редактирование OTP diagnostics. Настройки статического токена сохранены отдельно; fallback из App режима отсутствует.

Профиль Projects inspection запрашивает только `organization_projects/issues/contents/metadata:read`; legacy GitHub tool profile — `issues/pull_requests:write`, `contents/metadata:read`. Отдельный внутренний профиль `contents_write` содержит только `contents:write` и `metadata:read`; его доставка worker/push broker ещё не реализованы, выбор остаётся до зависимых push hooks. App имеет более широкие grants для будущих этапов, но они не выдаются read-инспекции.

Финальный последовательный `make all`: 369 tests, 0 failures, 6 skipped, coverage 100%, Credo/specs.check/Dialyzer PASS. Порог coverage не снижался, исключения модулей не добавлялись. Предшествующий прогон во время параллельной сборки Burrito дал единичный сбой старой проверки таймера (20 мс за границей допуска); без параллельной сборки полный прогон прошёл, допуск теста не менялся. Существующий lockfile продолжает сообщать security advisories; обновление зависимостей остаётся отдельной работой до live runtime.

Собран Linux x86_64 Burrito. Финальные escript и Burrito оба выполнили реальную read-only App inspection с exit 0 и отклонили обычный Projects runtime startup с exit 1 на синтетическом guard profile. Реальная доска пуста. Ключ, токены, приватный workflow и отчёты не входят в коммит; scanner публичного diff не нашёл фактические App IDs/ключевые пути. Эти локальные планы также не опубликованы. App, agent-runner, knowledge-base и upstream Symphony не изменялись.

GitHub Actions PR-03: [make-all](https://github.com/nataliastaselko8-spec/symphony/actions/runs/34984733857) и [pr-description-lint](https://github.com/nataliastaselko8-spec/symphony/actions/runs/34984733888) завершились success на commit 8475ecd471b441ba6d160762d4ab9f81d0a1c20c. Make-all завершён 2026-09-15 14:59:20 UTC. PR остаётся draft, merge выполняет владелица после своей валидации.
