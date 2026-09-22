# Второй пилот Symphony: этап 1 — проверка исходного состояния

Дата: 2026-09-21. Проверки завершены около 14:40 UTC / 17:40 Europe/Minsk.

**Результат: этап проверки выполнен. Можно переходить к реализации синхронизации доски.** Предыдущий цикл завершён, незавершённой публикации и работающего агента не обнаружено. Новая задача ещё не выбрана и не запускалась. Это не приёмка исправлений и не подтверждение готовности следующего живого пилота.

## Основные выводы

1. Карточка прежнего пилота **уже находится в Ready for production**. Запись «осталась PR ready» относится к историческому отчёту, а не к текущей доске. В ходе этой проверки карточка не изменялась; кто и как перевёл её ранее, не исследовалось.
2. Доска Delivery содержит все нужные статусы и поле Agent allowed. Создавать колонки для следующего этапа не требуется.
3. Действующая установка использует старый закреплённый source commit и исправленный после сборки исполняемый файл. Чистый Git checkout не означает, что это неизменённая сборка того commit.
4. Журнал корректен: 77 команд, replay успешен, активного цикла нет, последний цикл completed. Все сохранённые операции подтверждены.
5. Следующий пилот должен использовать новую issue. Прежняя задача не требует перезапуска или ретроспективной записи статуса.

## Область и метод проверки

Использованы метаданные установленного комплекта, чтение файлов в его WSL-средах, существующие функции preflight/Snapshot/Effects и read-only API GitHub через установленную GitHub App. Для API выполнялся обычный обмен авторизации на короткоживущие scoped tokens; токены и содержимое ключей не выводились и не сохранялись в отчёт.

Symphony scheduler, controller launcher, task worker и контейнеры не запускались. WSL-дистрибутивы были временно запущены для чтения и диагностики. После проверки отсутствия процессов агента/controller обе среды возвращены в исходное состояние Stopped; остальные WSL-среды не запускались. Не выполнялись изменения карточек/PR, публикация, CI rerun, login, setup, обновление, миграция или сброс store.

Проверка касается первой позиции согласованного списка: «проверяем текущую установку и фиксируем исходное состояние». В первоначальной редакции технического плана она называлась этапом 0; нумерация плана приведена к пользовательскому списку.

## Установленная поставка

| Параметр | Подтверждённое значение |
| --- | --- |
| Installation ID | `3fed257978cd448798a4d337a4450717` |
| Каталог Windows | `D:\SymphonyData\3fed257978cd448798a4d337a4450717` |
| Setup | `complete` |
| Controller WSL | `Symphony-Controller-3fed2579` |
| Worker WSL | `Symphony-Worker-3fed2579` |
| Установленный Symphony source | `ffb3f1ab49c387475a60334bfcc0ca9f3cb076a1`, checkout чистый |
| Установленный profile source | `7a2cbf2cf85cf3d4bcf5b7777497b151d1ff127f`, checkout чистый |
| Worker image | `sha256:5eeffa002f45a33d72178f9a66c8fed0b399c64fe911a07d6d825d02e96109d0` |
| Labels образа | profile revision совпадает; `io.symphony.runtime-contract=2` |
| Runtime package SHA256 | `c902833b2783baf2ca78bbdb19d511a2b18ebf6b5398735635d4ac22cce2cb54` |
| Модель / effort | `gpt-6-astra` / `high` |
| Toolchain по build receipt | Erlang `28.5`, Elixir `1.19.5-otp-28` |
| Исходный bundle SHA256 по setup metadata | `2f373c01f60d1bb22e3e330b9fb67224d1a048c08519352c7ae5421c316759d4` |
| Локальные исходники для дальнейшей разработки | Symphony `6508642643b9c4691bc12cefd6de90df8c2c94f9` |

Полный исходный bundle и его assets повторно не хешировались. Runtime package worker совпадает с runtime hash controller manifest. Четыре установленных Windows helper-файла — operator.py, symphony.ps1, manager.ps1, support.ps1 — побайтово совпадают с текущими соответствующими файлами в D:\symphony.

В локальном D:\agent-runner сохранены незакоммиченные изменения README.md, WORKFLOW.template.md и scripts/profile_check.py. Установленный чистый профиль не включает их автоматически. Его обновление — отдельный этап; в этом аудите файлы не менялись.

### Исполняемый файл содержит локальные исправления

| Источник | SHA256 исполняемого файла |
| --- | --- |
| Исходная root-owned запись controller-build.json | `ab92eea17f2e7d6162642646e91926ad2fb59f1a306007e52c5e0495f2eabe9e` |
| Текущий файл elixir/bin/symphony | `8007f3b3a0f8025e9d5ebe0abfaadf0c17bd8a24660671563718a1a7b519dc2d` |
| Текущий deployment manifest | `8007f3b3a0f8025e9d5ebe0abfaadf0c17bd8a24660671563718a1a7b519dc2d` |

Текущий manifest и бинарник совпадают.

В private repairs сохранены receipts исправлений гонки observer, передачи контекста/app-server, resume, publication permissions, startup timeout и offline policy. Наличие receipts подтверждает локальные вмешательства; полная цепочка происхождения всех промежуточных бинарников в рамках этого этапа не восстанавливалась.

**Следствие:** обновление должно распознавать исправленный установленный артефакт и создать новую проверенную сборку/receipt. Нельзя считать её стандартной сборкой ffb3f1a только по Git HEAD или вручную заменить старый хеш в receipt. Повторный Setup в этом этапе не запускался; результат такого повтора не заявляется.

## Состояние процессов и данных

| Проверка | Результат |
| --- | --- |
| Windows manager | `phase=stopped`, `stopped=true`; записанный PID не существует |
| Controller launcher | `running=false`, `execution_enabled=false` |
| Последняя остановка | `stopped=true`, `workspace_preserved=true` |
| Worker resource | `phase=stopped`, причина `guardian_shutdown` |
| Worker auth sync | `auth_sync_pending=false` |
| Symphony systemd units в worker | Активных/загруженных совпадающих units не перечислено |
| Podman task containers | Пустой список, включая остановленные контейнеры |
| Сохранённая работа | Один каталог workspace и один файл export присутствуют |
| Codex auth | Файл существует, mode `0600`; содержимое и свежесть сессии не проверялись |
| Место Windows | C: около 160,7 GiB; D: около 333,5 GiB свободно на момент чтения |

Чтение свободного места не заменяет автоматический Windows disk readiness. Наличие файла auth и выбранной модели не заменяет реальный login/model acceptance нового комплекта. Workspace и export в этом этапе не изменялись; их полнота потребует проверки перед обновлением/восстановлением.

### Журнал delivery

Файл: `/home/symphony/.local/state/symphony/pilot-e0941901a1dbaaf699d216d0/delivery.json`.

- Envelope checksum корректен; snapshot schema 1, revision 77, commands 77.
- `Snapshot.decode` успешно воспроизвёл журнал и подтвердил равенство восстановленного snapshot сохранённому.
- Scope из текущего установленного workflow совпадает со snapshot: EmotionStat/app, Project 1, base dev.
- Contract hash: `4bc701ee20824d549ae904f5bd870690cf7f5da7f977cb03228782a7f2c7a973`.
- State idle; active cycle отсутствует; operator pause и environment problem отсутствуют.
- Last cycle `5898a0f8a1b292bebbd05639` имеет phase completed; cancellation/recovery отсутствуют.
- Шесть effects, включая publish, имеют подтверждённые шаги; `Effects.unresolved?` вернул false.
- Baseline/validation: SHA `b3b7c17a6b12dc3afe62e2a5be58cd6bc645b947`, run `35366428380`, attempt 1; validation passed для app/scenario/services.

SHA256 всего delivery.json до и после аудита одинаков: `6f430fcbf5866cf3ddc13dfb2032b9a905196e7a87776867cb1585f241ee4c63`.

Дополнительные проверки только на копиях данных в памяти: изменённая revision отвергается; другой scope отвергается; искусственно оставленный sent-шаг публикации определяется как unresolved. Настоящий snapshot не редактировался.

## GitHub: проверено напрямую

Project: [EmotionStat / Delivery, №1](https://github.com/orgs/EmotionStat/projects/1).

**Status:** Backlog, Ready for agent, Agent working, Needs human decision, PR ready, Human review, Dev validation, Ready for production, Done. **Agent allowed:** yes/no. Оба поля — SINGLE_SELECT; read-only инспекция завершилась успешно.

Инспекция вернула одну карточку в Ready for production: [issue #132](https://github.com/EmotionStat/app/issues/132), OPEN, не архивирована, исключена из запуска как inactive_status. Eligible count — 0. Отсутствие новой допущенной карточки ожидаемо: новую задачу ещё не выбирали.

Полученные grants установленной GitHub App:

| Permission | Grant |
| --- | --- |
| actions | read |
| contents | write |
| issues | write |
| metadata | read |
| organization_projects | write |
| pull_requests | write |

Installation не suspended, repository selection — selected. Успешно выдан и проверен delivery_read token с точным scope EmotionStat/app и урезанными правами actions/contents/metadata/pull_requests read. Projects read также сработал. Запись статуса, публикация PR и issuance всех write-профилей намеренно не выполнялись; grants показывают наличие разрешений, но не заменяют проверку реальных операций новой реализации.

Текущий dev: `b3b7c17a6b12dc3afe62e2a5be58cd6bc645b947`, совпадает с baseline сохранённого завершённого цикла. Последний из пяти запрошенных deployment runs: [35366428380](https://github.com/EmotionStat/app/actions/runs/35366428380), attempt 1, completed/success, тот же SHA. Все 127 исторических runs, jobs и evidence artifacts заново не перебирались; live health приложения и Cloudflare не проверялись. Перед новой задачей требуется свежая штатная проверка dev.

## Зафиксированный контракт следующих этапов

| Основание | Целевой статус | Кто подтверждает |
| --- | --- | --- |
| Допущенная работа действительно началась | Agent working | Controller |
| PR/linkage подтверждены, worker остановлен, актуальный полный CI успешен | PR ready | Controller |
| Человек явно начал review | Human review | Сохранённое действие оператора |
| Разрешена доработка до merge | Agent working | Operator/runtime после проверки того же PR и бюджета |
| Назначенный PR merged в dev | Dev validation | Observer/controller |
| Актуальный deployment и положительная ручная validation совпадают по SHA/run/attempt | Ready for production | Controller после решения оператора |
| Требуется вмешательство | Needs human decision | Controller независимо от живого агента |

Контракт применяется к будущей реализации. Нынешнее наличие статусов на доске не доказывает, что controller умеет выполнять все переходы.

Правила конфликта: перед записью перечитать карточку и основания события; уже достигнутую цель подтвердить без повторной mutation; чужое ручное перемещение не перетирать устаревшим событием. Неизвестный ответ сначала сверять чтением; конфликт показывать отдельным состоянием синхронизации. До разрешения конфликт не даёт допуска следующей задачи. Начало review не выводится из открытия страницы или назначения reviewer. Done и production автоматизацией пилота не управляются.

## Требования к совместимости и обновлению

1. Delivery snapshot schema 1, runtime manifest schema 2 и image runtime-contract 2 — разные контракты. Нельзя повышать все номера одним механическим изменением.
2. Новые поля синхронизации меняют форму snapshot, а роли статусов участвуют в scope fingerprint. Текущий строгий replay не допускает дописывания новых полей или подмены scope без явного пути совместимости.
3. До обновления подтвердить Stop и создать проверяемую private backup journal/previous, manifest/workflow/config, descriptors, build/repair receipts, workspace/export и ссылок на auth. Backup с секретами остаётся в защищённом хранилище и не входит в Git или отчёт. Аудит ничего не мигрировал, поэтому свежая backup перед изменением установки относится к этапу обновления.
4. Старый snapshot сначала проверять его исходной схемой и scope. Переход к новой версии должен сохранять старое evidence, identity, budgets и историю; быть повторяемым после сбоя и иметь receipt исходного/целевого digest. Не переписывать старые команды так, будто синхронизация существовала тогда.
5. Текущий completed не требует новых mutations: финальная карточка уже соответствует результату. Для fixtures старых completed без final sync сохранять историческое ограничение, а не создавать задним числом запуск или эффект. Любая реально unresolved publication остаётся блокировкой.
6. Незавершённая синхронизация новых циклов должна сохраняться и после complete/Stop/restart. Выбор следующей issue допускается только после завершения и подтверждения её final sync.
7. После миграции новый pilot profile/state создаётся отдельно. Baseline не переносится как новое доказательство готовности: dev проверяется заново перед запуском.
8. До новых внешних действий rollback может вернуть сохранённые старые версии и состояние. После публикаций/новых записей rollback требует согласования фактов и схемы; слепой откат journal не разрешается.

## Разбор отказов перед реализацией

| Отказ | Требуемое поведение / проверка следующего этапа |
| --- | --- |
| Complete выполнен, GitHub ещё не подтвердил финальный статус | Pending не теряется в last_cycle; следующий пилот не допускается |
| Worker упал до project_start/project_block | Controller сохраняет блокировку и обновление доски самостоятельно |
| Комментарий не записался | Известный статус блокировки не ждёт комментарий бесконечно |
| GitHub принял mutation, ответ потерян | Readback до повтора; отсутствие дубликата PR и отката статуса |
| Человек передвинул карточку | Видимый конфликт; нет автоматического подавления ручного решения |
| Issue закрылась после merge | Отдельная проверка post-merge записи; закрытие само по себе не означает completed |
| Сбой между подготовкой Linux profile и Windows descriptor | Повтор завершает тот же переход; прежний профиль доступен |
| Setup/update встречает исправленный бинарник | Проверка repair/build provenance; новая сборка без обхода hash guards |

Необходимость общего исключения для старой карточки в blocking_items сейчас не подтверждается: Ready for production не входит в текущий перечень блокирующих статусов. Реализовывать широкий обход ownership ради #132 не требуется.

## Что остаётся и границы завершения этапа

Следующий этап — сохранённая синхронизация статусов в controller и тесты restart/ошибок. Затем lifecycle/UI, смена пилота, профиль и проверяемая поставка по [плану](second_pilot_implementation_plan.md).

В этом этапе не запускались полный make all, container isolation suite, live task, CI новой задачи, обновление или чистая установка. Код runtime не менялся. Проверены исходное состояние, journal и scope, метаданные поставки, Project schema и grants. Свежая копия для восстановления и принятие новой поставки выполняются перед изменением установки.

Каноническое основание: Agent-Native GitHub and Cloudflare Concept; Action Register OPS-002, ENG-026, ENG-027, ENG-028 и ENG-008. Статусы этих работ не закрываются данным аудитом. Исторические сведения Pilot Results остаются историческими; актуальная проверка записана отдельно в этом отчёте.
