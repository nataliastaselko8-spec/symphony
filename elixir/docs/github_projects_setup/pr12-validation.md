# PR-12 — отчёт реализации и проверок

Дата: 2026-09-17. Статус: **PR12 прошёл локальную приёмку и готов к review владелицей**.
Согласованный предел 256 MiB установлен; все 36 локальных шагов приложения прошли,
остановка и изоляция подтверждены. Push/merge не выполнялись; реальные задачи Project
не запускались. Публикация и hosted CI остаются действиями владелицы.

## Изменения и ревизии

| Компонент | Ревизия / назначение |
| --- | --- |
| agent-runner | `agent/feat/emotionstat-workflow`, `f5f7140f556db6996ff7717677b565418e6ae46c` |
| Symphony companion | `agent/fix/worker-bundle-transfer`, код `1f6944c5a47021408487212d29b142d7c8c6c1e5` |
| Приложение для проверки | `a880e7811742458ac5492023ebfa882cc0a3d4a1`, неизменённый bundle локального dev |
| Project image | `sha256:0965d96f3b1b6fd616355de0e3a747951f005eb7aeb203e32cf62af88fd2192e` |
| Base PR11 image | `sha256:6145ad195c748056819a1cac5f99d49012801cb8a2b7db002aaf8f95b800533d` |
| Node image | `docker.io/library/node@sha256:152aceace5c03e2597988763165ee33e3fd3633636db0fc983cd2e126b02cfde` |

В image: Node 24.15.0, uv 0.11.32, Python 3.11.15, jq 1.8.1,
build-essential/libpq-dev, root-owned scripts и собственный localhost-only hosts.
Исходники приложения, host paths и credentials в build context не входят.
Сборка читает пять разрешённых Git blobs; image-source.json связывает их hashes с ревизией.
Пакеты apt устанавливаются на момент сборки; побитовая воспроизводимость не заявляется.
Закрепляется фактически испытанный полный image ID.

Контракт deployment evidence взят из Git blob app, SHA256:
`b3a384c8502fa4b1593167c8c38d4c9ac90f36587bca8269a4cb41c9f878fba1`.
Windows CRLF-копия не используется для вычисления pin.

## Что реализовано

- WORKFLOW.template с действительными полями Symphony, Liquid prompt, concurrency=1,
  GitHub App references controller, `item_ids: []` и ручным операторским процессом.
- Hooks для создания, повторного запуска и продолжения назначенной ветки. Свежий dev
  вливается обычным merge; грязная работа и конфликт сохраняются. Worker не выполняет
  сетевые Git-операции и не удаляет workspace после handoff.
- Ограниченный контекст и проверка Git layout/config. Marker worker остаётся диагностикой,
  не разрешением controller на работу, публикацию, recovery или изменение бюджета.
- Явный каталог команд API/web/D1/Cloudflare, изолированные cache/home/tmp/logs,
  отчёт по SHA/profile с `passed`/`failed`/`not_run`/`ci_only`. Только полный текущий
  успешный локальный отчёт допускает диагностический handoff-check; GitHub CI остаётся
  доверенным источником для gate.
- Производный image, контролируемый build context, unit/contract/container tests,
  собственный CI без production secrets и переносимые инструкции.

## Проверки

| Проверка | Результат |
| --- | --- |
| Python profile tests | 31, PASS, без skips при SYMPHONY_SOURCE |
| Реальный renderer/Config/Settings/Liquid/guard | PASS на закреплённой Symphony |
| Git negatives | PASS: stale/foreign context, повтор hook, interrupted create, dirty/conflicting merge, symlinks/config |
| Controller publisher | PASS на локальном bare remote: повтор идемпотентен, dev/main неизменны, `.github/**` запрещён |
| Build source/portability | PASS: чужой SHA/dirty tree отклонены, личных путей нет, config проверен с временными путями |
| Symphony make all | PASS: 552 Elixir tests, 0 failures, 6 skipped; format/specs/Credo/Dialyzer |
| Python checks Symphony | PASS: 8 store, 9 publisher, 31 runtime tests |
| Project image / PR11 smoke | PASS: файл 144 MiB разрешён, выше 256 MiB — EFBIG; host filesystem/network недоступны |
| Stop/recovery | PASS: descendants/export/deadline, controller loss 45,47 s, guardian crash/restart; scoped firewall удалён |
| Публичный HTTPS | PASS при успешном curl; управляющий SSH принял только ограниченный протокол |
| Команды приложения в контейнере | PASS: 36 локальных шагов за 230,04 s; API Docker build — отдельный `ci_only` |
| Handoff-check | PASS: тот же SHA, чистый worktree, полный текущий отчёт |
| Отмена verification | PASS: реальный stop подтверждён, дочерний процесс остановлен, незавершённая работа сохранена |

Unit tests профиля проверяют orchestration команд на fixtures; они не заменяют
следующую контейнерную приёмку. Product tests не выполнялись на controller host.

Полный успешный запуск включает CI helper tests, установку API, ruff/format/unittest,
offline Alembic, web npm ci/lint/tests/translations/build/Wrangler dry-run, D1 local
migrations, установку и `verify` всех десяти Cloudflare Worker packages. Общий отчёт —
`passed_local`; это не утверждение об уже прошедшем hosted CI или здоровье deployed dev.

## Исправления, найденные на настоящем приложении

1. Bundle 3 073 845 bytes выявил частичную запись сокета PR11: guardian ожидал остаток
   и возвращал guardian_io_error. Companion commit Symphony дописывает весь фрейм.
   Реальный relay round trip 3,5 МБ и short-write regression прошли. Лимиты не расширялись.
2. Тестам CI finalizers нужен jq; он добавлен в проектный image.
3. База PR11 использует `--no-hosts`; localhost отсутствовал, что останавливало Vitest.
   В image добавлен собственный файл только с 127.0.0.1/::1. Файл хоста не копируется;
   сетевые запреты PR11 сохраняются и проверяются заново.
4. После исправлений за 220,19 s прошли API/web/D1, quiz-engine и api-publisher.
   `npm ci` для question-results-workflow-worker завершился `EFBIG`/`SIGXFSZ`:
   бинарник `@cloudflare/workerd-linux-64` 1.20260820.1 занимает 151 356 536 bytes
   (около 144 MiB), лимит PR11 — 128 MiB. Последующие шаги отмечены `not_run`.
   Лимит не обходился установкой на host или использованием чужого volume.
   Владелица явно согласовала 256 MiB на файл. Изменение реализовано с сохранением
   2 GiB/2 CPU, лимита Git bundle 80 MiB и остальных границ. Новый canary проверяет
   разрешённый размер workerd и фактический отказ ядра выше 256 MiB.
5. В smoke исправлено ложное сообщение PUBLIC_HTTPS_PASS после ошибки curl:
   теперь оно возможно только при успешном HTTP-запросе. Допускаются два ограниченных
   повтора сетевой операции, итоговая неудача завершает smoke ошибкой.

Сохранённый отчёт неуспешного запуска находится в тестовой WSL2:
`/home/symphony-worker/pr12-acceptance-ipq6jeru/workspaces/pr12-d3ca6ec7b26e/.emotionstat/verification.json`.
После согласованного исправления успешный отчёт:
`/home/symphony-worker/pr12-acceptance-xowqlszn/workspaces/pr12-48a1a953ea9b/.emotionstat/verification.json`.
Текстовые логи финального повторения: `/tmp/symphony-pr12-256-acceptance.log`,
`/tmp/symphony-pr12-256-smoke.log` в worker WSL; `/tmp/symphony-pr12-256-make-all.log`
в controller WSL. Для будущей установки источник версий — таблица выше, не имена этих каталогов.
Это путь evidence на данной машине, не default конфигурации других разработчиков.
После проверки добавлен синтетический файл незавершённой работы для canary отмены;
он сохранён после stop. Отчёт предыдущего SHA не разрешает handoff грязного workspace.

## Воспроизведение

Требуются чистые checkout закреплённых ревизий, подготовленный root-owned package
Symphony на worker host, принятые base/Node images и app bundle от controller.
Имена аккаунтов, пути package/bundle и distro выбирает локальная установка.
Для contract checks нужен checkout точного `symphony_commit` из profile-lock;
последующие документационные коммиты ветки не заменяют этот pin.

```bash
SYMPHONY_SOURCE="$SYMPHONY_ROOT" python3 -I -B -m unittest discover -s tests -v
python3 -I -B scripts/profile_check.py --symphony "$SYMPHONY_ROOT"
python3 -I -B worker/build.py --revision "$PROFILE_COMMIT" --base-image "$BASE_IMAGE_ID"
sudo python3 -I -B "$PACKAGE/tests/runtime_smoke.py" \
  --worker "$WORKER_ACCOUNT" --image "$IMAGE_ID" --package "$PACKAGE"
sudo python3 -I -B tests/container_acceptance.py \
  --worker "$WORKER_ACCOUNT" --image "$IMAGE_ID" --package "$PACKAGE" --bundle "$APP_BUNDLE"
```

Root используется для временного supervisor/firewall setup. Продуктовые команды
внутри rootless task container работают под UID 10001 без capabilities.
Smoke удаляет только свои ресурсы; app acceptance сохраняет workspace/logs для review.
Проверка выполнена на выделенной WSL2 Ubuntu 26.04, Podman 5.7.0; это не заявление
о повторении полной приёмки на всех Linux/WSL версиях или всех машинах разработчиков.

## Порядок публикации и оставшиеся границы

1. Владелица публикует companion ветку Symphony в личный fork. Runner CI обращается
   к commit `1f6944c`, поэтому он должен быть доступен на GitHub. При squash, меняющем
   этот SHA, перед удалением ветки согласовать новый pin и повторить contract/image checks.
2. Владелица публикует `agent/feat/emotionstat-workflow` в `EmotionStat/agent-runner`,
   создаёт PR в `main` и проверяет hosted CI. Hosted Actions в этой сессии не запускались.
3. После review/merge итоговые source/image pins записываются в локальный manifest.
   Этот image/profile пока подходит для инспекции и отдельной приёмки.

App/knowledge-base не изменены. Реальные App tokens, карточки, deploy и model turns
не использовались. Код `.github` приложения не изменяется ради зелёных проверок.
API Docker build сохраняется обязательным в Actions, локально — `ci_only`.

PR13 должен соединить `/workspace/repo` с lifecycle/hooks/Codex/export, fresh-dev seed
с исходной task base, runtime callbacks/watchdog, profile pins и локальный pilot filter.
Требуются окончательная настройка отдельной Codex-авторизации и назначение единственного
controller. Один файл WORKFLOW и успешная изолированная приёмка этих действий не заменяют.
