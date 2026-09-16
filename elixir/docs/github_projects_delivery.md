# Наблюдение за delivery в GitHub — PR-07

PR-07 добавляет конечное чтение Project, PR, `dev` и GitHub Actions. Команда возвращает
JSON и завершается. Она не запускает worker, hooks, scheduler или delivery store,
не публикует код, не повторяет CI и не снимает паузу Queue.

Исходный [план PR-07](github_projects_setup/pr07-execution-plan.md) и
[модель PR-06](delivery_cycle.md) описывают следующий этап подключения.
Обычное исполнение `tracker.kind: github_projects` по-прежнему запрещено при startup,
CLI и reload. Успешный отчёт не является разрешением на следующую задачу.

## Запуск на controller

Используется **Ubuntu / nataselko**, где находятся credentials App. Worker Ubuntu-26.04
для этой команды не нужен. В controller-профиле существующего Project inspection
добавьте секцию ниже. Файл должен находиться вне checkout и worker workspace.

```yaml
delivery:
  state_path: /home/nataselko/.local/state/symphony/delivery.json
  base_branch: dev
  observer:
    contract_commit: <полный SHA принятого коммита app>
    contract_sha256: <SHA-256 исходных байтов deployment-evidence-contract.json>
```

`state_path` проверяется как часть конфигурации, но диагностическая команда его
не открывает и не создаёт. Источник обязательных проверок — явно закреплённый commit.
Автоматического перехода на «последний контракт из dev» нет.

В этой рабочей среде создан отдельный приватный профиль
`/home/nataselko/.config/symphony/github-app/delivery-inspection.WORKFLOW.md`.
Запуск из PowerShell:

```powershell
wsl -d Ubuntu -u nataselko --cd /mnt/d/symphony/elixir --exec bash -lc 'mise exec -- mix github_projects.delivery.inspect --workflow /home/nataselko/.config/symphony/github-app/delivery-inspection.WORKFLOW.md'
```

Если зависимости ещё не установлены в выбранном build/deps каталоге, сначала
выполните `mise exec -- mix setup` из той же папки в Ubuntu. Диагностика не запускает
основной интерфейс Symphony. Панель оператора подключается в PR-10.

| Код завершения | Значение |
| --- | --- |
| `0` | Полное наблюдение; осталась ручная проверка dev |
| `1` | Неверные настройки либо чтение/проверка неполны |
| `2` | Полное наблюдение подтверждает дополнительное ожидание или блокировку |

Все варианты сохраняют `execution_enabled=false`, `next_task_allowed=false` и
`manual_validation=pending`. `complete=true` означает полноту наблюдения, а не успех:
оно может подтверждать упавший или ещё выполняющийся workflow.

## Настройки и права

Обязательны валидный `github_projects` профиль и отдельная GitHub App. Для Project
используется существующий профиль `projects_read`; для REST delivery — новый
`delivery_read`: **Actions, Pull requests, Contents, Metadata — read** в одном repo.
Профили имеют разные ключи кэша. Auth-обмен installation token выполняется на controller;
он не является предметной mutation. PAT для этого observer не предусмотрен.

Параметры `delivery.observer`, кроме двух обязательных отпечатков:

| Ключ | Значение по умолчанию |
| --- | --- |
| `deployment_workflow` | `.github/workflows/deploy-development.yml` |
| `pr_workflow` | `.github/workflows/pr-ci.yml` |
| `verify_workflow` | `.github/workflows/verify.yml` |
| `contract_path` | `.github/scripts/deployment-evidence-contract.json` |
| `producer_path` | `.github/scripts/deployment-evidence.py` |
| `ci_gate_path` | `.github/scripts/ci-gate.py` |
| `environment` | `development` |

Имена ключей закрыты. Поддерживается base `dev`. Пути ограничены файлами `.github/workflows`
и `.github/scripts`; произвольного GET-инструмента нет. IDs repo/workflows берутся из API.
Все шесть исходных файлов читаются из принятого commit. Для проверяемой версии кода их
байты должны совпасть. Новая версия producer или проверок требует review и обновления pin.

Настройки observer входят в restart-only fingerprint PR-06. Добавление секции меняет
scope существующего store; старое состояние не сбрасывается и не мигрирует автоматически.
В PR-07 отсутствие секции сохраняло fingerprint PR-06. PR-08 дополнительно версионирует
runtime-контракт и фильтры: [правила подключения и несовместимого store](delivery_runtime.md).
Inspection этому не мешает, поскольку store не читает.

## Как проверяются факты

- Project читается полностью, включая архив, без `item_ids`. Проверяются сохранённые
  item/issue и ветка, а не заголовок PR. Working/blocked/handoff и review/dev-validation
  карточки без владельца сохраняют блокировку. Чужой открытый PR автоматически не присваивается.
- PR связывается с сохранённым номером и repo/head/base. Отсутствие association даёт
  `task_pr_not_bound` или `pr_association_requires_operator`. Создание этой связи до handoff
  относится к PR-09; observer не угадывает её по названию ветки или `Closes`.
- Для открытого PR различаются source head, текущая base и тестируемый merge commit.
  Проверяется `referenced_workflows` reusable verify, его `refs/pull/<n>/merge`, SHA и
  родители merge commit `[dev, feature head]`. Другой base/head, неполные metadata или
  неподтверждённый test merge исключают зелёный результат. GitHub `run.head_sha` не
  выдаётся за SHA синтетического merge.
- После merge проверяется merge SHA из PR API и его ancestry в текущей dev, включая
  squash/rebase. Старый pre-merge CI после merge помечается `not_applicable_after_merge`;
  решение о среде основывается на deployment, а сохранённые run IDs всё равно сверяются.
- Все runs deployment workflow перечисляются без фильтра SHA/возраста. Выбор учитывает
  время выполнения последней попытки, а не ID/дату создания старого run. Незавершённые
  и перекрывающиеся попытки блокируют готовность. Историческая попытка исключается из
  влияния только если завершилась раньше начала выбранного полного успешного deployment.
- Jobs читаются для конкретного `run_id/run_attempt`. Для успеха нужны все jobs контракта
  и job публикации evidence. Имена steps сопоставляются с закреплённым YAML; нужны
  успешные обязательные `outcome/conclusion`, а skipped/neutral успехом не считаются.
- Workflow приложения использует несколько статических GitHub Environments:
  `development`, `development-containers`, `development-postgres` и другие `development-*`.
  Их имена проверяются по закреплённому YAML. Динамические expressions и другая группа
  окружений не поддерживаются. `environment.status` в JSON — готовность, а не имя Environment.
- Проверяются точное имя и metadata артефакта, доступность, фактический размер и SHA-256
  **байтов ZIP**. JSON v1 проверяется независимо от положительного флага producer.
  IDs отчёта должны быть строгими десятичными строками; дубликаты JSON-ключей запрещены.
- В конце повторно читаются dev, Project, PR и полные указатели runs. Изменение даёт
  `observation_changed`. GitHub не предоставляет общей транзакции: PR-08/PR-10 должны
  повторять сверку непосредственно перед исполнением и решением оператора.

## Ограничения чтения

REST API version: `2022-11-28`. Один запрос — до 30 секунд, весь проход — до 5 минут,
коллекция — до 100 страниц по 100 элементов. Ошибка поздней страницы, повтор IDs,
изменение total count или предел истории аннулируют положительный результат.
Только один повтор GET при транспортном сбое/502/503/504; это не попытка CI.
Rate limit возвращает `retry_after_seconds`; observer сам не запускает новый проход.
403 без признаков rate limit остаётся ошибкой доступа, а не «пустым repo».

Максимум ZIP — 5 MiB, распакованного JSON — 2 MiB. Архив содержит один обычный файл
`development-evidence.json`, без извлечения на диск. ZIP64, несколько файлов, symlink,
другой путь, лишние записи, неверный CRC и превышение при распаковке отклоняются.
Redirect API разрешён только на HTTPS `productionresults*.blob.core.windows.net`,
проверенный в живой приёмке; Authorization туда не передаётся. Другой storage host
или второй redirect требуют обновления reader. Signed URL и ответы API в отчёт не входят.

## Контракт для следующих PR

Внутренний вызов: `Delivery.observe(config, context: DeliveryGate.status(controller), ...)`.
Контекст должен поступать из доверенного controller; CLI не принимает произвольный
JSON состояния от worker. Без контекста команда наблюдает общую среду.

`Observation.validate/3` сверяет scope, epoch/revision и отпечаток состояния. Старый
ответ после отмены, restart, restore или смены настроек отклоняется. `commands/3`
возвращает только кандидаты `observe_ci`, `merged`, `deployment`; сама ничего не пишет.
PR-08 обязан повторно проверить контекст, допустимость перехода и GitHub факты перед
каждой записью. Кандидаты не являются готовым исполняемым batch.

CI связывается с reservation только при уже сохранённом точном run/attempt/SHA.
Ручной или ещё не привязанный run имеет `origin=external`; reader не создаёт ему
автоматическую reservation. Повторное наблюдение не расходует бюджет. Существующие
60+60 минут, 2 исправления, 6 CI-попыток и 2 повтора на SHA остаются в PR-06.

Отмена имеет приоритет и сохраняется при merge/deployment. Recovery сохраняет исходного
owner; merge его PR во время recovery помечается отдельной причиной. Ни `Done`, ни
закрытие/удаление карточки, ни отсутствие jobs не освобождают цикл.

Queue/Scheduler подтверждаются **на момент отчёта deployment** (`observed_at`,
`readiness_is_live=false`). Унаследованная пауза означает success deployment и
`resume_queue_before_dev_validation`. Артефакт не обновляется после ручного снятия паузы.
Новое доверенное чтение Cloudflare, operator auth/UI и завершение ручной проверки
остаются последующими этапами до PR-10/пилота. Токен Cloudflare этому PR не требуется.

## Проверка реализации

Тесты используют синтетические контракты, настоящий ZIP/JSON parser, Req adapter и
временный Linux store PR-06. Исходники приватного приложения и credentials в fixtures
не копируются. Проверяются отмена/restart, повтор observations, разные SHA/attempts,
частичные jobs, изменённая политика, опасные архивы и отсутствие побочных действий.

Живая read-only приёмка 2026-09-16: Project Delivery прочитан; перечислены 126 runs;
deployment `35095177024`, attempt `1`, artifact `10446890300` прошёл сверку digest,
receipts и jobs. Dev SHA: `a880e7811742458ac5492023ebfa882cc0a3d4a1`.
Принятый контракт: SHA-256 `b3a384c8502fa4b1593167c8c38d4c9ac90f36587bca8269a4cb41c9f878fba1`.
Результат: deployment success, Queue active, Scheduler configured на момент отчёта,
ручная проверка pending. Новых Actions runs, GitHub mutations и worker не запускалось.
Новая Mix-команда с приватным controller-профилем завершилась с кодом `0` и
`complete=true`, `execution_enabled=false`, `next_task_allowed=false`.

Полный `make all`: 445 Elixir tests, 0 failures, 6 skipped, 100% измеряемого покрытия;
8 Python store/crash tests, format, specs, Credo и Dialyzer пройдены. Существующий
lockfile продолжает выдавать предупреждения Hex о зависимостях; их обновление
не входит в PR-07 и остаётся отдельной работой до включения live runtime.
