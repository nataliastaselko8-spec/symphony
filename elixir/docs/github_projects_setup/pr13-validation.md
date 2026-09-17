# PR13 — реализация и локальная приёмка

Дата: 2026-09-18. **Реализация и локальная приёмка завершены; готово к review владелицей.**
Полные проектные проверки финального image прошли. Push/merge не выполнялись.

## Проверяемый комплект

| Компонент | Ревизия |
| --- | --- |
| Symphony, код | `4fa7735eb8357305556249e9094827d4b6bf3db7` |
| Ветка Symphony | `agent/feat/projects-runtime-integration` |
| agent-runner | `95cf0fc12d0e62547d41c4ea4a45fbefd03ccd06` |
| Ветка agent-runner | `agent/feat/pr13-runtime-profile` |
| Проектный image | `sha256:eb11a7e782e47ccd51952aa1e3a020417143d8ab8ea251f96a5e7005d896426e` |
| SHA256 испытанного Linux escript | `5ce009bc84ac48d85d017c709cd251e5462f34f4cab5c17fd560a6ec40b650fc` |
| Приложение для контейнерной проверки | `a880e7811742458ac5492023ebfa882cc0a3d4a1` |
| Базовый image PR11 | `sha256:6145ad195c748056819a1cac5f99d49012801cb8a2b7db002aaf8f95b800533d` |

Следующие документационные коммиты не заменяют кодовый pin автоматически. Перед
пилотом принимается весь комплект: чистые source/profile checkouts, escript, Python
runtime, workflow и image. Локальный manifest v2 связывает их hashes. Другой
разработчик использует собственные пути, accounts, distro, credentials, порты и модель.

## Что реализовано

- Launcher отдельно проверяет готовность controller и worker. По умолчанию — конечная
  inspection. `launch --execute` требует private activation, чистых закреплённых
  ревизий, совместимого профиля/образа и живого launcher. Dashboard можно открыть
  с закрытым допуском; `--execute` не обходит delivery gate.
- Controller передаёт свежий разрешённый dev как ограниченный bundle. Исходная база
  задачи и сохранённая работа продолжаются по правилам hooks. Единственный рабочий
  cwd — `/workspace/repo` внутри контейнера. Выданный SSH alias связан с конкретным
  cycle/interval/generation; произвольный host или каталог модель не выбирает.
- Runtime устанавливает prepare/start/heartbeat/stop/export callbacks. Отдельно
  подтверждается отсутствие контейнера и потомков; выход agent PID сам по себе
  не завершает интервал и не разрешает публикацию. Watchdog сохраняет границы PR11.
- Только controller владеет GitHub App, publisher и operator credential. Worker
  получает отдельную Codex-авторизацию и task workspace. Merge, Actions rerun при
  Actions: read, ручная проверка dev и recovery остаются решениями оператора.
- `login`/`models` используют пустой изолированный контейнер и `model/list`.
  `select-model` сохраняет **модель и reasoning effort** локально; обе величины
  закрепляются для цикла. Каждый thread/turn получает явные параметры. Несовпадение
  ответа и `model/rerouted` останавливают сессию. Dashboard отличает выбор от
  подтверждения Codex. Права, 60-минутные бюджеты и CI-попытки от усиления не меняются.
- Незавершённые, отменённые и аварийные данные сохраняются. Только успешное завершение
  создаёт immutable report и запускает retention, по умолчанию 7 дней. Удаляются
  собственные проверенные тяжёлые данные, небольшие отчёты/привязки остаются.
  Очистка отменённых задач отдельной кнопкой в PR13 не реализована и автоматической не является.
- Контролируется место controller/worker: предупреждение ниже 10 GiB, остановка/запрет
  допуска ниже 5 GiB, пороги локально настраиваются. Логи ограничены; image cleanup
  использует только namespace установки, без global prune/force и удаления используемых образов.
- Допускается один выбранный пилот. Ownership сохраняется через CI/review/deployment/
  ручную проверку; после его завершения launcher сохраняет итог и останавливается.
  `last_cycle` запрещает переход к следующей обычной задаче в профиле PR13.

## Автоматические проверки

| Проверка | Результат |
| --- | --- |
| `make -C elixir all` | PASS: 575 тестов, 0 ошибок, 6 skipped; 100% измеряемого покрытия |
| Format, specs, Credo, Dialyzer | PASS |
| Runtime Python | 55 PASS |
| Delivery store / publisher Python | 8 / 9 PASS |
| Agent-runner Python с `SYMPHONY_SOURCE` | 31 PASS, без skips |
| Реальный parser / renderer / prompt / startup guard профиля | PASS на закреплённой Symphony |
| Packaged inspection / прямой execution | Конечный отказ на тестовом invalid key / отказ без launcher activation |
| Model protocol | PASS: пагинация, неподдерживаемый effort, скрытая/неоднозначная модель, несовпадение ACK, reroute |
| Модель и усилие при продолжении | PASS: обе величины передаются каждому turn; смена выбора не перезаписывает цикл |
| Stop/status одновременно | PASS: pending poll не теряет finish, повторное подтверждение не создаёт второй finish |
| Хранение и границы | PASS: cancelled/crash/active сохраняются, чужие paths/tags отклоняются, более длинный retention сохраняется |

Покрытие относится к измеряемому набору модулей проекта, не является утверждением
о 100% всех файлов или всех возможных состояний. Шесть skips — существующие
опциональные live/Docker сценарии; они не заменялись фиктивным успехом.
`mix deps.get` также сообщил о существующих advisories закреплённой Req; зависимости
в PR13 не изменялись, отдельная проверка/обновление зависимости остаётся вне этого изменения.

Delivery-сценарии проверены на настоящих OTP-процессах и fsync-backed store с
контролируемыми GitHub-ответами: handoff и stop до publication; CI failure/rework и
ручной rerun; review/merge/deployment; сохранённая пауза Queue и ручная проверка dev;
stale/expired forms; отмена во время эффекта; recovery; restart и неизвестный результат.
Это набор связанных интеграционных сценариев, а не live выполнение продуктовой карточки.

## Настоящий runtime и собранный launcher

Испытания: отдельная WSL2 Ubuntu 26.04, rootless Podman 5.7.0, cgroup v2, scoped
iptables-nft/ip6tables-nft, pasta, systemd. Root использован для supervisor/firewall;
продуктовый код работал только внутри непривилегированного контейнера.

Финальный runtime smoke прошёл:

- невидимость host home, Windows-дисков, WSLg, сокетов Docker/Podman;
- private PID/IPC/mount/network namespaces, capabilities=0, no-new-privileges, seccomp;
- блокировка private network/IPv6 при доступной контрольной точке вне worker cgroup;
- публичный HTTPS и management SSH с принудительным ограниченным протоколом;
- фактический лимит отдельного файла 256 MiB;
- Codex CLI 0.154.0 и настоящий `app-server initialize`, без model turn;
- descendants stop/export, deadline, controller loss **45,4 секунды**;
- guardian crash/restart, сохранение worktree, отдельный login-container и возврат прежней привязки;
- удаление только собственных временных служб и scoped firewall rules.

Packaged acceptance запускала **реальный escript из чистого Linux checkout**, из `/tmp`,
с внешним WORKFLOW, настоящими framed Python helpers и management SSH финального image.
Тестовый App key заведомо не является PEM, pilot filter пуст: токен GitHub получить
невозможно, task/model/writes не выполняются. Проверены реальный HTTP login с CSRF,
operator dashboard/API, причины отсутствия login/модели, отказ второго launcher,
`shutdown.ack`, `last_shutdown.stopped=true` и отсутствие task attempts.
Поддержанный packaged entrypoint — Linux escript; Burrito execution не принят.

Первый такой запуск выявил потерю finish при одновременном status poll. Исправление
`4fa7735` сохраняет запрос до завершения опроса и устраняет синхронный обратный вызов
Worker → DeliveryRuntime. Повторная packaged-приёмка завершилась `SUMMARY PASS`.

Проектная проверка предыдущего candidate image `77e02bb...` прошла все 36 локальных
шагов за 242,89 секунды, handoff-check и отмену verification с сохранением незавершённой
работы. Финальный image отличается pin-метаданными; исходники hooks/checks/Containerfile
не изменились. Финальный image также прошёл **все 36 шагов за 231,8 секунды**,
handoff-check и verification cancellation с подтверждённой остановкой и сохранённым файлом
незавершённой работы. Итог — `passed_local`; Docker build по-прежнему `ci_only`.

Adversarial-проверка в ходе реализации отдельно затронула одновременные poll/stop,
сохранение неопределённого состояния, stale handles, изменение модели, сохранение
обновлённой авторизации и границы очистки. Найденные воспроизводимые дефекты исправлены
и проверены повторно. Это проверка автора изменения; **независимый review перед merge
остаётся за владелицей/ревьюером**, отдельный независимый агент не запускался.

## Воспроизведение и оставшиеся условия пилота

Команды установки и работы: [руководство PR13](pr13-runtime-guide.md).
Описания для review: [Symphony](pr13-description.md), [agent-runner](pr13-runner-description.md).
Приёмочные программы: `runtime/tests/runtime_smoke.py`, `runtime/tests/packaged_smoke.py`
и `agent-runner/tests/container_acceptance.py`. Для packaged fixture нужны отдельные
private config/state/SSH и точные pins; `app_key` должен содержать только
`PR13_INVALID_KEY_FIXTURE` с переводом строки. Не используйте рабочие credentials.

Владелица публикует Symphony в свой fork **до** companion agent-runner: его CI
загружает указанный commit. Затем review/CI/merge обоих репозиториев и принятие
окончательного комплекта. При squash с изменением SHA pin нужно явно согласовать
и проверить; moving main не заменяет его. Upstream openai/symphony не изменялся.

Перед PR14 нужны отдельный реальный вход Codex, выбор доступных модели **и усиления**,
сверка прав/установки GitHub App, один активный controller, исходный dev и единственная
согласованная карточка с критериями. В этой приёмке реальные GitHub/App credentials,
карточки, PR, merge, deployment и платные model turns не использовались. App и
knowledge-base не изменены. API Docker build остаётся `ci_only`, не объявляется
выполненным локальной проверкой. Проверка развернутого dev относится к PR14.
