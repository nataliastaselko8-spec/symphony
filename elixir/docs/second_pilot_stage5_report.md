# Второй пилот Symphony — отчёт этапа 5

Дата: 2026-09-22. Основание: [этап 5 плана](second_pilot_implementation_plan.md#этап-5-согласовать-профиль-и-проверки).

**Результат:** профиль agent-runner согласован с текущей реализацией Symphony;
проверены семь статусов, единый источник SHA, строгая проверка pin, отдельный режим
development compatibility и поведение offline-проверок. Реализация этапа проверена.
Релизная приёмка ещё не завершена: окончательные commits, release image и hosted CI
нужны после разработки механизма обновления/миграции этапа 6.

## Почему выбран этот порядок

Источником принятого Symphony SHA остаётся `worker/profile-lock.json`. Ранее CI
использовал другой SHA, поэтому локальная проверка и hosted CI могли проверять разные
версии. Теперь ref читается из lock, формат проверяется до checkout, а затем сверяются
фактический HEAD и чистота Symphony checkout.

Закреплять текущий HEAD как готовую поставку нельзя: изменения этапов 2–4 ещё находятся
в рабочем дереве, а этап 6 добавит механизм обновления и миграцию. Для разработки введён
явный режим совместимости; для поставки остаётся строгая проверка. Цепочка принятия:
итоговый Symphony commit → строгая проверка профиля → profile commit/hosted CI →
release image → bundle/приёмка обновления. Промежуточные commits не требуют смены lock.

Локальная сеть команд агента выключена, поэтому попытки `npm ci` и `uv sync` создавали
заведомые ошибки среды. Теперь исполняются подготовленные проверки, а отсутствие
зависимостей фиксируется до запуска. Полный hosted CI точного candidate SHA остаётся
обязательным доказательством для `PR ready` и операторского merge.

## Изменения профиля

Изменены 10 файлов в `D:\agent-runner`; ранее существовавшие правки README,
WORKFLOW.template.md и profile_check.py сохранены и дополнены.

| Файл | Что обеспечивает |
| --- | --- |
| `.github/workflows/profile-ci.yml` | Читает SHA из lock; проверяет точную чистую ревизию перед тестами; development-режим не используется |
| `scripts/profile_check.py` | Проверяет формат pin, HEAD/чистоту, семь ролей; отделяет development evidence от принятой поставки |
| `WORKFLOW.template.md` | Задаёт семь ролей; объясняет владельца статусов, ожидание status sync, skip и обязательный CI |
| `scripts/checks/verify.py` | Проверяет готовые offline-зависимости; сохраняет passed/failed/skipped и причины; не устанавливает пакеты |
| `tests/test_profile.py`, `tests/symphony_contract.exs` | Проверяют отказ неверному/грязному pin, Python -O, неполную карту ролей и настоящий parser |
| `tests/test_checks.py` | Проверяет пропуски, реальные ошибки, timeout, права, незавершённый/устаревший отчёт и частично установленные зависимости |
| `tests/container_acceptance.py` | Принимает честный неполный локальный отчёт; требует причины пропусков, проверяет hooks и остановку |
| `README.md`, `AGENTS.md` | Описывают фактический запуск, статусы, проверки и порядок поставки; удаляют устаревший PR13 guard |

Карта включает `ready`, `working`, `blocked`, `handoff`, `review`, `dev_validation`,
`production_ready`. Новые роли не включены в tracker active/terminal. Статус
`Ready for production` не разрешает production deployment. Смена карты меняет scope;
применение к действующей установке требует миграции этапа 6.

## Контракт результатов проверок

Перед запуском требуется чистый committed candidate и неизменённый контракт команд
приложения. В каждый scope входит `git diff --check origin/dev...HEAD`.

| Ситуация | Результат |
| --- | --- |
| Команда выполнена с exit 0 | `passed` |
| До запуска нет executable/готовых зависимостей | `skipped` с `command_unavailable` или `offline_dependency_missing` |
| Выполненная команда вернула ненулевой код, включая missing module или OOM | `failed`; текст лога не превращает ошибку в skip |
| Timeout или отказ запуска по правам | `failed` |
| Общий бюджет исчерпан | Оставшиеся шаги `skipped:deadline_exhausted`, общий результат `failed` |
| Все доступные локальные проверки прошли, часть зависимостей отсутствует | `incomplete_local` |
| Все плановые локальные проверки прошли | `passed_local`; полный CI всё равно обязателен |
| Прогон прерван до завершения отчёта | `running` не принимается handoff-check |

После ошибки продолжаются остальные доступные проверки в пределах общего бюджета.
Docker build отмечается отдельным `skipped:ci_only`. Отчёт schema 2 содержит candidate
SHA, команды, причины, hash lock и происхождение image. Старый локальный отчёт нельзя
выдать за новый: handoff-check требует schema 2, актуальные SHA/profile/image/команды.
Это диагностический отчёт worker, а не доверенное доказательство controller.

Полные `verify --scope all` и `--handoff-check` остаются дополнительной диагностикой.
Для полного отчёта с объяснёнными пропусками handoff-check возвращает
`candidate_partially_checked`, список пропусков и напоминание о полном CI; exit 0
означает пригодность диагностического отчёта, а не прохождение CI. Агент обязан
выполнить доступные целевые проверки и перечислить пропуски в project_report и PR.

API использует готовые `.venv/bin` инструменты; npm install/sync отсутствуют.
Wrangler вызывается из готового `node_modules/.bin`, без `npm exec`.
Проставлены offline-переменные npm/uv; ограничение сети runtime сохранено.

## Что проверено

| Проверка | Результат |
| --- | --- |
| Unit/Git tests профиля с development Symphony | 42 теста, 0 ошибок, без пропусков |
| Настоящий renderer → Workflow/Config/Settings → Liquid → execution guard | Успешно; все семь ролей и прежний default inspection подтверждены |
| Строгий pin на текущем development checkout | Ожидаемый отказ `symphony_revision_not_pinned`, включая Python -O |
| Pin на временном настоящем Git repository | Принимает точный чистый SHA; отклоняет иной SHA и untracked/dirty checkout |
| Реальный rootless Podman task image, SSH/UID/read-only profile | Успешно в отдельной Ubuntu-26.04 |
| Hooks before-run дважды, неверный cwd, after-run | Повтор безопасен, неправильный cwd отклонён, работа сохранена |
| Проверки приложения внутри task image | Git diff успешен; CI-helper suite: 40 тестов, 0 ошибок |
| Отсутствующие offline-зависимости | 22 шага skipped с причинами; Docker CI отдельным skipped; общий `incomplete_local` |
| Частичный handoff-check | Успешен; возвращает все 23 пропуска и требование полного CI |
| Остановка команды с дочерним процессом | Stop подтверждён, процесс прерван, частичная работа сохранена |
| Завершение тестовой среды | Активных Podman containers и соответствующих test supervisor units нет |
| `git diff --check` обоих repositories | Успешно |

Проверки приложения не запускались на controller host. Прогон выполнен на прежнем
fixture bundle приложения `a880e7811742458ac5492023ebfa882cc0a3d4a1`, не на новой
продуктовой задаче. Отсутствующие API/Web/Worker зависимости не скачивались.

При испытаниях сначала обнаружены неверные права каталогов development build context;
они исправлены в тестовой подготовке. Следующий прогон обнаружил транзитивную зависимость
переводов от `jsonc-parser`: выполненные команды получили `failed`. После добавления
предварительной проверки этой зависимости новый прогон получил обоснованный skip.
Предыдущие ошибки не переписаны как успех; сохранены отдельные логи всех попыток.

Итоговый development image:
`sha256:6fbaa7398da1e1135cb0592c55d4769ec65e7f699f0c6f162c9cc0ec2fae8d94`.
Основа — существующий project image `sha256:5eeffa002f45a33d72178f9a66c8fed0b399c64fe911a07d6d825d02e96109d0`.
Образ собран без сети только с текущими hooks/checks/lock; metadata явно содержит
`development-stage5-uncommitted`, `accepted=false` и hashes файлов. Он не является
release image и не назначен действующей установке.

Локальные доказательства в `D:\symphony\.runtime-local`:
`stage5-profile-tests.log`, `stage5-profile-contract.log`, `stage5-strict-pin.log`,
`stage5-acceptance.log`, `stage5-acceptance-retry.log`, `stage5-acceptance-final.log`,
`stage5-development-image.json`, `stage5-container-verification.json`.
Fixtures и образ сохранены в отдельной тестовой Ubuntu для разбора; контроллер и
контейнеры агента не оставлены работающими.

Полный quality gate Symphony успешно выполнялся на этапе 4. На этапе 5 Elixir/runtime
реализация не менялась: проверены новые профильные тесты и настоящий Elixir contract,
исторический `make all` не выдан за новый прогон.

## Что остаётся

1. Разработать и проверить обновление/миграцию этапа 6, затем зафиксировать итоговый Symphony.
2. Обновить единственный Symphony SHA в lock и выполнить строгую проверку на его чистом checkout.
3. Зафиксировать профиль, опубликовать изменения и получить успешный hosted CI нового PR.
4. Собрать release image штатным builder из чистой profile revision и повторить container acceptance.
5. Собрать bundle и проверить обновление, scope/store migration, rollback и реальные границы среды.
6. После приёмки выбрать новую задачу и выполнить живой пилот этапа 7.

Текущий lock оставлен на прежнем `ffb3f1ab49c387475a60334bfcc0ca9f3cb076a1`.
Совместимость семистатусного профиля с этой прежней поставкой не заявляется;
новый профиль до итогового pin не готов к публикации как принятый комплект.
Development-проверка сообщает HEAD `6508642643b9c4691bc12cefd6de90df8c2c94f9`,
`dirty=true`, `accepted=false`. Hosted CI не запускался: новые revisions ещё не опубликованы.
Commit/push, обновление действующей установки, выбор/запуск пилота и изменения GitHub
не выполнялись. Issue #132 не использовалась для испытаний.
