# PR-12 — профиль EmotionStat, подготовка веток и проверки в worker

Дата: 2026-09-17. Статус: **код PR12 реализован в локальной ветке; полная приёмка
остановлена на лимите файла 128 MiB, решение о 256 MiB ожидается**.
Результаты и найденные ограничения: [отчёт](pr12-validation.md).

Основной репозиторий реализации: `EmotionStat/agent-runner`, база `main`.
Предлагаемая ветка: `agent/feat/emotionstat-workflow`.
Предлагаемый title: `Define the EmotionStat workflow and isolated task hooks`.
Текущая папка разработки — `D:/agent-runner`; это не обязательный путь для других установок.
Push и merge выполняет владелица. Номер этапа PR-12 не обязан совпадать с номером GitHub PR.

Основания: [общий план](../github_projects_pr_rollout_plan.md),
[runtime PR-11](../../../runtime/README.md), [контекст hooks PR-08](../delivery_runtime.md),
[публикация PR-09](../github_projects_publication.md),
[панель оператора PR-10](../operator_dashboard.md).

## 1. Результат этапа

После PR-12 в `agent-runner` будет проверенный проектный профиль: откуда брать задачу,
какую ветку использовать, как подготовить зависимости, какие проверки выполнять и
как передавать результат controller. Другой разработчик сможет использовать тот же
профиль со своими локальными путями, пользователями, WSL и учётными данными.

В PR-12 профиль и hooks проходят отдельные проверки в реальном изолированном контейнере.
Это ещё не запуск агента по карточке: подключение полного startup, transport, разрешений,
watchdog, dashboard и Codex относится к PR-13. `launch --execute` остаётся запрещён.

Фактическая основа, прочитанная при подготовке плана:

| Репозиторий | Локальный HEAD | Состояние |
| --- | --- | --- |
| Symphony | `e9d9363a23e03be514ca460d1f98ad00301ea71e` | `main`, merge PR-11 присутствует |
| agent-runner | `f00328d909fe56f1a63126b0626a6acb48062c16` | `main`, каркас без hooks и WORKFLOW |
| app | `a880e7811742458ac5492023ebfa882cc0a3d4a1` | `dev`, источник команд проверки |

Это снимок локальных checkout, а не утверждение о текущем удалённом HEAD или здоровье dev.
Перед реализацией повторить проверку состояния; чужие незакоммиченные изменения сохранять.

## 2. Границы репозиториев и исполнения

| Где | Что принадлежит этому месту |
| --- | --- |
| Публичный fork Symphony | Движок, gate/store, observer, publisher, операторская панель, общий runtime и transport |
| Приватный agent-runner | Проектный шаблон, prompt, hooks, команды проверки, производный образ worker и тесты профиля |
| Локальная конфигурация вне git | Имена WSL/accounts, пути, порты, credential paths, итоговые принятые SHA/image ID |
| app | Код приложения, AGENTS/README, lockfiles и существующий CI/deployment |

Реализация PR-12 не переносит scheduler, бюджеты, GitHub API client, store или launcher
в `agent-runner`. Новый универсальный framework настроек не нужен. Исполняемый WORKFLOW
создаётся штатным `runtime.py render` из Symphony в локальном config-каталоге.
Сгенерированный файл не коммитится ни в runner, ни в app.

База знаний обновляется в итоговом PR-15 согласно решению владелицы. Product-код,
Actions приложения, branch protection, права App и реальные карточки в PR-12 не меняются.
README runner должен ссылаться на действующие планы Symphony и явно отметить, что
перенос принятых решений в канон отложен. Это исключает ложное впечатление, что старые
`pending-decision` по runtime/store остаются нерешёнными.

## 3. Исправления прежнего плана

1. Убрать прямые `git fetch origin/dev` и `git push` из worker hooks. GitHub читает
   controller; worker получает проверенный Git bundle и не получает GitHub credentials.
2. Убрать фиксированный исполняемый `D:/agent-runner/WORKFLOW.md` и проектный `launch.sh`.
   В git хранится `WORKFLOW.template.md`; путь исполнения выбирает локальный config.
3. Hooks доставляются внутри принятого image, а не подключением checkout runner с хоста.
4. `after_run`/handoff не разрешают удаление workspace: цикл может ждать CI, review или recovery.
5. Формулировка «все проверки app локально» требует уточнения: `verify.yml` содержит
   Docker build. Этот шаг остаётся обязательным в GitHub Actions, без Docker socket у worker.
6. Не добавлять декоративные поля YAML, которые движок не читает. В частности,
   manual validation и бюджеты сейчас закреплены в controller; наличие текста
   `validation.mode` или `budget` в шаблоне само по себе их не настраивает.

## 4. Предлагаемый состав изменения

Имена новых файлов ниже — планируемые; соседние маленькие функции можно объединить,
если это уменьшит дублирование. Отдельную документационную/ADR-базу в runner не создавать.

```text
WORKFLOW.template.md                 # JSON front matter + Liquid prompt
scripts/hooks/task.py                # validate-context / before-run / after-run
scripts/checks/verify.py             # подготовка зависимостей и проверки app
scripts/profile_check.py             # диагностика и проверка контракта профиля
worker/Containerfile                 # зависимости app + hooks поверх image PR-11
worker/profile-lock.json             # версия контракта и проверенная совместимость
worker/hosts                         # только localhost внутри image, без hosts хоста
worker/build.py                      # ограниченный build context, явный base image
.containerignore                    # дополнительное исключение секретов/локальных данных
tests/test_hooks.py                  # реальные временные Git repositories
tests/test_profile.py                # render/config/параметры и запреты
tests/test_checks.py                 # команды, статусы, сбои и отсутствие ложного success
tests/container_acceptance.py        # hooks/checks в принятом контейнерном профиле
.github/workflows/profile-ci.yml     # тесты самого runner без production secrets
README.md
AGENTS.md
SECURITY.md
config/runner.example.yaml
workspaces/README.md
.gitignore
.gitattributes                      # LF для Linux scripts/template
```

`runner.example.yaml` больше не выглядит вторым исполняемым конфигом движка:
либо оставить короткий явно исторический указатель на новый шаблон, либо удалить
после проверки ссылок. Не поддерживать два расходящихся набора scope/бюджетов.
Убрать прежнее разрешение на `knowledge-base` из примеров: этот профиль — только `app`.

## 5. Шаг 1 — закрепить совместимость и входные данные

- Создать ветку runner от проверенного `main`. Сверить AGENTS и существующие файлы.
- Зафиксировать принятый Symphony commit и проверяемую версию profile contract.
  Итоговый digest образа и SHA будущего merge записываются после сборки/merge в локальный
  manifest, а не выдумываются заранее и не вычисляются через moving `main` при запуске.
- Сверить contract JSON, producer, CI gate и workflows приложения на одном выбранном
  принятом commit. Для observer нужны реальные `contract_commit` и `contract_sha256`.
  Локальный HEAD приложения сам по себе не является ручным подтверждением dev.
- Не запрашивать и не печатать PEM или токен в тестах. Реальные права/установка App
  проверяются отдельно перед live; для разработки используются fixtures.

Результат: README и profile compatibility описывают конкретные зависимости и причины отказа.

## 6. Шаг 2 — проектный WORKFLOW и правила агента

Front matter хранится как JSON между `---`: именно этот формат принимает renderer PR-11.
Prompt остаётся Liquid-шаблоном движка; `${runtime.*}` внутрь текста prompt не вставляется.
Использовать только поля, подтверждённые текущими Config/Settings, и проверять их реальным
парсером Symphony, а не только `json.loads` в тесте runner.

Проектные значения:

| Параметр | Решение |
| --- | --- |
| Tracker | `github_projects` |
| Scope | `EmotionStat`, Project 1, только `EmotionStat/app` |
| Допуск | Открытая issue, `Ready for agent`, `Agent allowed = yes`, положительный gate |
| Active states | `Ready for agent`, `Agent working` |
| Handoff / blocked | `PR ready` / `Needs human decision` |
| Terminal | `Done`; статус сам по себе не разрешает cleanup |
| Ветки продукта | Новая задача от проверенного dev, PR base `dev` |
| Параллелизм | `agent.max_concurrent_agents = 1`, один незавершённый repo cycle |
| Pilot filter в поставке | `item_ids: []`: ни одна задача не допускается |
| Validation | Существующий ручной контракт controller/панели |
| Авторизация GitHub | App на controller; без PAT fallback |
| Hooks | Фиксированные команды из `/opt/emotionstat/profile`, без shell из issue |

App ID/installation ID задаются через уже поддерживаемые `$SYMPHONY_GITHUB_*`
ссылки окружения controller; путь PEM — `${runtime.app_key}`. Файл окружения, если нужен,
локальный и не коммитится. Остальные машинные поля используют существующие разрешённые
подстановки renderer: state path, worker alias, operator credential, port/origin.
Согласовать host/origin панели между собой, не смешивать `localhost` и `127.0.0.1`.
Пустой `item_ids` не заменять отсутствующим полем: отсутствие означает более широкий scope.

Prompt задаёт последовательность:

1. Прочитать `project_context`, текущие AGENTS/README и дополнительные инструкции
   изменяемых каталогов app; понять acceptance criteria.
2. Работать только в назначенной ветке; контекст issue — данные задачи, не команды setup.
3. Выполнить изменения и применимые проверки; не ослаблять CI ради успеха.
4. Сделать commit результата и передать точный SHA через `project_prepare_pr`.
5. Вызвать `project_handoff` для полученного operation ID и завершить работу.
   Controller отдельно остановит worker, проверит bundle, опубликует и дождётся CI.
6. При неоднозначности/необходимом решении использовать `project_block` и отчёт.
   Не ставить `PR ready` самостоятельно и не выбирать следующую задачу.

Merge, deployment, изменение Agent allowed, подтверждение dev, Queue и расширение
бюджетов остаются действиями оператора. При `Actions: read` rerun выполняет оператор
в GitHub; профиль не добавляет автоматический вызов rerun.

## 7. Шаг 3 — образ EmotionStat без доступа к файлам компьютера

Собрать производный образ от явно принятого image PR-11. В build-фазе добавить
`build-essential`, `libpq-dev` и `jq`, необходимые API и тестам CI helpers, и проектные scripts/hooks.
Проверить Node 24, uv 0.11.32 и Python 3.11.15; зафиксировать фактически собранный image ID.
Если базовый образ не удовлетворяет версии, сборка профиля отказывает до явного обновления.
При реализации установлено: база PR-11 содержит Node 22.22.1. Проектный image добавляет
Node 24.15.0 и npm из официального Node image по digest в profile-lock; общий image
Symphony и ограничения исполнения не меняются. Digest contract JSON вычисляется по
Git blob принятого commit, а не по Windows working tree с CRLF.
Для Vitest image содержит собственный `/etc/hosts` только с loopback localhost;
`--no-hosts` и изоляция host network сохраняются.

Проектный код app и credentials не входят в образ. Build context формируется из
allowlist файлов чистой принятой ревизии runner, без `.git`, `.env`, private config,
workspaces и auth. `.containerignore` — дополнительная защита, не единственный фильтр.
Hooks устанавливаются root-owned в `/opt/emotionstat/profile` внутри образа. Финальный
USER, ENTRYPOINT, sshd и transfer script сохраняют контракт PR-11.

При выполнении нет apt/sudo, privileged mode, host network, Docker-in-Docker,
Docker/Podman sockets или дополнительных host mounts. Доступны только ресурсы задачи,
образ и отдельная авторизация Codex по правилам PR-11. Полный controller `.codex` не копируется.

Проектные `node_modules`, `.venv`, cache и служебные результаты находятся внутри
workspace задачи; пути задаются явно, чтобы установки не пытались писать в read-only image
или временный home на 64 MiB. Кэши не общие с controller или другими задачами.
Если 2 GiB/2 CPU или действующие файловые лимиты недостаточны, зафиксировать измеренный
сбой; не добавлять скрытый запуск на хосте и не повышать лимиты без отдельного решения.
Приёмка выявила workerd размером 151 356 536 bytes при лимите 134 217 728 bytes.
Запрошено решение о лимите файла 256 MiB; до ответа прежний предел сохранён.

## 8. Шаг 4 — получение кода и создание ветки

Нормальный поток данных:

```text
controller: проверенный dev SHA → Git bundle
    → PR-11 prepare в transfer-контейнере без сети/credentials
    → /workspace/repo, detached HEAD
    → hook: проверка контекста и назначенная agent/... branch
```

Hooks читают `SYMPHONY_DELIVERY_CONTEXT` v1: `repo`, `project_number`, `cycle_id`,
`version`, `item_id`, `issue_id`, `branch`, `interval_id`, `task_base_sha`,
`expected_dev_sha`, `mode`. Проверить размер/типы/обязательные поля, допустимые SHA,
ветку через `git check-ref-format`, repo/project, абсолютный разрешённый cwd.
JSON не превращается в shell; Git вызывается списком аргументов.

Для `new`:

- Требуется проверенный detached HEAD и совпадение с назначенной базой/текущим dev.
- Создать ровно ветку из controller context. Название не выводить из заголовка issue.
- Не заменять существующий непустой workspace другой задачей. Существующая ветка
  с несовпадающим владельцем/историей — ошибка с сохранением файлов.
- Повтор успешного hook с тем же контекстом не создаёт вторую ветку и не стирает данные.

`origin` после PR-11 указывает на локальный seed bundle, а не на GitHub. Не требовать
GitHub URL как доказательства доверия и не переписывать его в рабочий remote с токеном.
Проверять доставленные refs/SHA; сетевые fetch/push из hooks отсутствуют.
Отключать repository hooks/credential helpers/fsmonitor для служебных Git-операций.

Worker-local marker может помогать диагностике/идемпотентности, но изменяемые файлы
worker не являются авторитетом для ownership или публикации. Их подтверждает controller.

## 9. Шаг 5 — продолжение, актуализация dev, recovery и отмена

| Сценарий | Поведение |
| --- | --- |
| Продолжение после CI/review | Та же задача, ветка и существующий PR; старые расходы сохраняются |
| Незакоммиченные изменения | Сохранить; не применять reset/clean/автоматический stash; перед изменением базы нужен checkpoint/разбор |
| Dev не изменился | Проверить историю и продолжить без нового merge |
| Dev продвинулся | После controller admission импортировать новый bundle; обычный merge проверенного dev в ту же task branch |
| Merge конфликт | Сохранить index/worktree и `MERGE_HEAD`; диагностировать, не удалять workspace и не создавать второй PR |
| Повтор после конфликта | Выявить незавершённый merge; не запускать новый merge поверх него; разрешение в рамках действующего допуска или решение оператора |
| Dev переписан/non-fast-forward | Закрыть продолжение для разбора, без принудительного обновления refs |
| Recovery | Только явно назначенный controller recovery context, новая ветка от текущего dev; обычная очередь остаётся закрыта |
| Отмена/истечение бюджета | Runtime отзывает допуск и останавливает контейнер; hooks не перезапускают задачу |
| Stop не подтверждён | Экспорт, следующий interval и cleanup запрещены |

Hooks проверяют локальную историю, но не решают, здоров ли dev и разрешено ли recovery:
эти факты принадлежат существующему gate. При конфликте до старта Codex PR-12 обязан
дать определённый nonzero результат и сохранить работу. Автоматическая передача такого
конфликта агенту без потери допуска требует явной обработки в PR-13; до неё — оператор.

Не использовать `rebase`, force push, удаление/пересоздание ветки или повторное открытие PR.
Если прежний PR закрыт/merged, новый цикл по инициативе hook не создаётся: controller
сначала определяет допустимую фазу. `after_run` пишет только диагностический результат;
он не делает auto-commit/push и не запускает cleanup. `before_remove` не добавляет
самостоятельное удаление: ownership и разрешение удаления проверяет Symphony.

## 10. Шаг 6 — реальные команды проверки приложения

Источник — принятый `.github/workflows/verify.yml`, AGENTS/README и package scripts app.
Не исполнять произвольное содержимое GitHub Actions как локальный shell. В runner будет
небольшой явный каталог argv/cwd/env для проверенных команд; тест совместимости обнаружит
расхождение с принятой версией workflow. Обновление команд приложения требует пересмотра профиля.

| Область | Локальная проверка в контейнере |
| --- | --- |
| CI helpers | `python3 -m unittest discover -s .github/tests -v` |
| API dependencies | `uv sync --locked` в `apps/api`, Python 3.11.15 |
| API quality/tests | `uv run --frozen ruff check --no-fix .`, `ruff format --check .`, `python -m unittest discover -s tests -v` через uv |
| Alembic | `uv run --frozen alembic heads` и `alembic upgrade head --sql`, только offline placeholders |
| Web dependencies | `npm ci` в `apps/web` |
| Web | `npm run lint`, `npm test`, `npm run translations:test`, `npm run translations:validate`, `npm run build:dev` |
| Web bundle | `npm exec --no -- wrangler deploy --dry-run` с отключёнными загрузкой sourcemaps/metrics |
| D1 migrations | `npm ci` в tooling и `node .github/scripts/check-d1-migrations.mjs`, только local режим |
| Cloudflare packages | `npm ci`, затем существующий `npm run verify` в перечисленных пакетах текущего workflow |
| API Docker image | `CI_ONLY`: обязательный Docker build выполняется GitHub Actions |

Перед включением каждого npm script проверить его действительное содержимое и dry-run/local
границу. Команды работают без Cloudflare/Sentry/production credentials; настоящие deploy,
migrate remote, изменение Queue/Scheduler не выполняются. Для API используются фиктивные
offline CI значения PostgreSQL, а не доступ к существующей БД. Не выводить окружение целиком.

До handoff выполнить полный поддерживаемый локальный набор. Во время разработки разрешены
узкие проверки затронутого пакета. Зависимости устанавливаются по lockfiles, без `npm install`
или незаявленной регенерации locks. Успех установки сохраняется как подсказка cache,
но сам по себе не считается успешной проверкой изменённого кода.

Отчёт содержит commit SHA, profile/image revision, команду/cwd, продолжительность,
exit code и статус `passed`, `failed`, `not_run`, `ci_only`. Ошибка установки,
timeout/OOM или прерванный тест не превращаются в `passed`. Неизвестная проверка — blocker,
а не автоматическое исключение. SHA и состояние worktree повторно сверяются после тестов;
после изменения кода прошлый отчёт не используется для нового head.

Локальный отчёт — evidence, не замена PR CI и не доверенное разрешение gate. Docker build
отмечается отдельно как `ci_only`; `PR ready` выставляет controller после полного CI.
Отсутствие Docker внутри worker не ослабляет Actions и не блокирует саму отправку кандидата,
если остальные требования handoff выполнены.

Лимиты сохраняются: начальная работа 60 минут; исправления отдельно 60 минут суммарно,
не более двух циклов; до шести CI-попыток, до двух инфраструктурных повторов на SHA.
Установка зависимостей/hooks/локальные тесты входят в активное время. Ожидание CI и оператора
не входит. GitHub verify timeout остаётся 20 минут; в app его здесь не меняем.
Планируемый общий timeout локального verification — 20 минут, но оставшийся controller budget
может остановить его раньше. Долгий verification не помещать в обязательный after_run hook.

## 11. Шаг 7 — передача результата без GitHub доступа worker

Профиль использует ровно инструменты PR-09: `project_context`, `project_start`,
`project_report`, `project_block`, `project_prepare_pr`, `project_handoff`.
Перед handoff проверить назначенную ветку, чистоту отслеживаемого worktree, итоговый SHA
и наличие актуального отчёта. Не добавлять credentials ради выполнения `git push` или `gh`.

После остановки экспорт PR-11 передаёт неизменяемый bundle в publisher PR-09.
Publisher заново проверяет scope, историю, текущий dev/PR/gate и публикует только task branch.
Операция с неизвестным исходом требует readback, а не повторного blind push.

Существующие ограничения publisher сохраняются: `.github/**`, submodules/LFS и запрещённые
изменения не проходят обычную публикацию. Issue, требующая изменения CI, должна быть
передана оператору или в отдельно согласованный scope, без обхода защиты из hooks.
Не выдавать JSON context hook за capability доступа к controller или доказательство допуска.

## 12. Шаг 8 — проверка результата PR-12

Основной harness использует временные реальные Git repositories и bundle transport;
запросы к GitHub и product deployments для негативных тестов не нужны.

| Группа | Что требуется доказать |
| --- | --- |
| Template | Реальный render и парсер Symphony принимают профиль; неизвестные/неподдерживаемые параметры выявляются |
| Portability | Другие пути/пользователь, пробелы/кириллица; отсутствие личных путей, private config и credentials в git/image |
| Scope | Только app/Project 1; `item_ids: []` не допускает ни одной задачи; полный observer не сужается pilot filter |
| New | Ветка ровно из context от ожидаемого dev; две последовательные задачи имеют разные ветки/workspaces |
| Continue | Повтор hook, текущий commit, незакоммиченные файлы и прежний PR не теряются |
| Updated dev | Merge в прежнюю task branch; базовые dev/main refs не публикуются и не переписываются |
| Conflict/crash | Состояние конфликтного merge/прерванной установки сохранено; повтор не стирает работу |
| Invalid input | Неверные SHA/repo/mode/ветка, чужой cycle, повреждённый JSON, shell metacharacters отклоняются |
| Filesystem | Symlink/worktree `.git`/path escape не дают обращения к ресурсам вне разрешённой task area |
| Git boundary | Worker не выполняет сетевой push/fetch; Git hooks/helpers/config не исполняются в служебных операциях |
| Validation | Failed/not_run/CI_ONLY различаются; stale head и timeout не дают зелёного полного результата |
| Publication | На локальном remote и существующем publisher harness dev/main неизменны; отказ forbidden files не обходится |
| Container | Реальные hooks и дочерние процессы сохраняют PR-11 filesystem/network/stop ограничения в производном image |
| Cancellation | Остановка во время dependency install/verification подтверждается transport; workspace остаётся |

Проверки проводить в таком порядке:

1. `git diff --check`, синтаксис и Python `unittest` для изменённых scripts.
2. Template/config contract с принятой Symphony; без настоящих секретов и model turns.
3. Сборка производного image, повтор обязательных PR-11 canary/stop checks для него.
4. Hooks на bundle fixtures, включая negative/restart cases.
5. Поддерживаемые реальные команды app на отдельной копии принятого commit внутри контейнера.
   Ни одна команда продукта не исполняется в checkout controller.
6. Проверка собственных CI jobs runner: offline hook/config tests в GitHub; host/systemd
   acceptance отдельно в WSL2, без заявления, что обычный hosted job повторил её целиком.
7. Отчёт с точными SHA, image ID, командами и результатами; сверка diff на секреты и
   отсутствие изменений app/knowledge-base. Если менялся код Symphony, его полный `make all`.

При нехватке памяти/диска/прав или недоступности зависимостей фиксируется реальный blocker.
Вместо успешного результата по mock-тестам не объявлять фактические container checks пройденными.

## 13. Явные точки интеграции PR-13

Обнаружены при чтении текущего кода и не должны потеряться за готовым шаблоном:

| Контракт | Сейчас | Что требуется при подключении PR-13 |
| --- | --- | --- |
| Рабочий каталог | PR-11 импортирует `/workspace/repo`; обычный Workspace вычисляет `<root>/<issue-key>`, renderer подставляет `/workspace/tasks` | Передавать проверенный путь подготовленного repo в lifecycle, hooks и Codex; не создавать второй пустой checkout и не использовать symlink-обход |
| Profile hooks | Общий image не содержит project hooks | Проверять выбранный производный image и profile revision до task startup |
| Fresh dev | `prepare.base_sha` определяет импортируемый seed; context отдельно содержит task base и expected dev | При continuation импортировать текущий expected dev, сохранять исходную task base и прежний head; проверить на обновившемся dev |
| Pilot | Renderer PR-11 не умеет подставлять список item IDs из local config | Добавить явный типизированный разрешённый параметр в общий renderer при настройке пилота; до этого в PR-12 оставить `[]`, без самодельного второго renderer |
| Runtime | Stop/export callbacks есть; полный startup их не связывает | Подключить prepare/start/heartbeat/async stop/export и реальные tool bindings |
| Activation | Локальный manifest допускает inspection | Итоговые pins, назначение единственного controller, отдельный Codex login и полная системная приёмка |

В PR-12 hook contract и контейнерные проверки используют `/workspace/repo`; template
и README явно маркируют зависимость startup от указанного mapping PR-13. Внутренний
путь контейнера — часть общего контракта, а не имя каталога компьютера пользователя.
Не обходить несовпадение cwd командами `cd` только в hooks: Codex и exporter тоже должны
работать с одним проверенным repository.

Если автономную приёмку профиля невозможно выполнить без исправления общего runtime,
сначала зафиксировать воспроизводимый дефект и отдельный минимальный companion diff в
Symphony. Не добавлять патч движка в runner и не маскировать это как готовый live PR-12.
Такой companion fix подготовлен: `1d74115` дописывает большие Git-bundle фреймы
при частичной записи сокета. Runner закрепляет эту ревизию; перед его hosted CI
владелица должна опубликовать companion commit в личном fork Symphony.

Для одного Project остаётся один активный controller; остальные установки inspection.
Локальный flock не является блокировкой между компьютерами. Профиль это правило описывает,
не обещая автоматические распределённые leases, которых нет в реализации.

## 14. Критерии приёмки владелицей

PR-12 готов к принятию, когда:

- В runner есть понятный WORKFLOW template и инструкции для другой установки без личных путей.
- Hooks создают и продолжают только назначенную ветку; результаты и workspace не теряются.
- Производный image запускает реальные поддерживаемые проверки app в границе PR-11.
- Docker build честно остаётся CI_ONLY, а остальные обязательные локальные проверки имеют результаты.
- Agent не получает GitHub/App/Cloudflare credentials или доступ к host dirs/sockets.
- Публикация и операторские решения остаются в уже реализованных компонентах Symphony.
- Есть проверяемый отчёт negative cases, portability и container acceptance.
- Пустой pilot filter и inspection-only startup сохранены; PR-13 integration gaps перечислены явно.

Для валидации этого плана предлагается принять два конкретных решения реализации:
проектные hooks и build-зависимости поставлять производным image; Docker build app выполнять
в существующем CI. Эти решения сохраняют ранее согласованную изоляцию worker.

До начала кодирования дополнительные секреты, новая GitHub App или pilot issue не нужны.
Выбор одной реальной задачи и окончательная настройка живого запуска относятся к PR-13/14.
По завершении реализации подготовить описание PR и validation report; push/merge — владелица.
