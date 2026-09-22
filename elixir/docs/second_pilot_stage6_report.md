# Этап 6: обновление, миграция и контроль Windows-диска

Дата: 2026-09-22. **Локальная реализация и приёмка завершены. PR #14 смержен; нестабильный тест, упавший в `main`, исправлен и прошёл полный локальный `make all`. Этап остаётся открыт до публикации исправления и успешного hosted CI.** Владелица выполняет публикацию самостоятельно, agent-runner пока остаётся локальным. Действующая установка не переключалась; следующий продуктовый пилот не запускался.

## Главное решение и его обоснование

Обновление готовит отдельную проверенную версию и переключает installation descriptor последним. Это сохраняет прежние исходники и состояние, позволяет продолжить прерванную операцию и проверить откат до начала новой работы. Старый журнал не получает произвольный новый fingerprint: миграция сохраняет исходный snapshot и проверяет его повторным replay.

Физический Windows-диск проверяется автоматически. Свободное место внутри WSL не показывает, сколько ещё может вырасти VHDX, поэтому controller учитывает меньший из двух остатков. Ручная проверка места не является условием допуска или заменой этой защиты.

## Что реализовано

- `Update` проверяет manifest/assets/helpers, commits, executable и image; готовит отдельные source/profile, host config, helpers, workflow/manifest и state.
- Версионированная миграция четырёх ролей на семь сохраняет историю, предыдущий цикл и бюджеты; аннулирует прежнее подтверждение dev. Исторический финальный статус остаётся `legacy_not_recorded`, без ретроспективной записи в GitHub.
- Допускается точный переход профиля этапа 5: read timeout 5000 → 60000 и заданная container sandbox policy. Изменение репозитория, карточки, App identity и произвольных настроек отвергается.
- Приватная резервная копия сохраняет исходные state/config/workflow/manifest. Auth, модель, SSH identity и worker workspaces остаются на месте.
- Pending journal закрывает Start; повтор с тем же bundle продолжает переход. Уже завершённая maintenance-проверка не повторяется после прерывания финального переключения.
- `Rollback-Update` выбирает прежний комплект только при неизменности обоих состояний и до первого запуска новой версии. Состояние не восстанавливается поверх новой работы.
- Windows manager каждые 3 секунды определяет тома зарегистрированных VHDX и передаёт свободное место через существующий stdin-канал. Проверяются установка, обе WSL, процесс manager/launcher, boot и свежесть до 15 секунд по часам, учитывающим sleep.
- Общий том учитывается один раз. Ниже 10 GiB — предупреждение; ниже 5 GiB или при неизвестности — закрытие допуска и штатная остановка активного worker с сохранением работы. Проверка не резервирует место от других программ.
- Панель показывает Windows и WSL отдельно, время измерения и причину ограничения. Worker не получает Windows mounts или новые права на хост.

## Итоговый локально проверенный комплект

| Артефакт | Закреплённое значение |
| --- | --- |
| Symphony source | `9f0a6b561d5c4af566373a659a03aa9aaf0eb247` |
| agent-runner profile | `17619e2e0f8ad9952fa71b54dd42e7a5a7b5b1b9` |
| Worker image | `sha256:2226444b9cb610d27cde671cb49e426d86d591162289520c72ace2536278e35e` |
| Bundle manifest SHA256 | `3561d0af475a7f4a83f9bc64786eb6905dfdf434cb6d2aed7c071303e9b9628c` |
| Bundle | `.runtime-local/release-9f0a6b5/bundle/bundle.json` |
| Ветки обоих репозиториев | `agent/second-pilot-release` |

Исходники и профиль проверены в чистых Linux checkout, без development-исключений. Image собран штатным builder. Документационный commit после source pin не меняет состав уже проверенного bundle; pin относится к указанному исходному commit, а не автоматически к HEAD.

## Что проверено

| Проверка | Результат |
| --- | --- |
| Полный `make -C elixir all` | 623 теста, 0 failures, 6 opt-in skips; coverage 100%; format/specs/Credo/Dialyzer PASS |
| Python store / publisher / runtime | 8 / 9 / 86 тестов, успешно |
| WSL helpers с настоящим Elixir replay | 58 тестов, успешно, без skips |
| Профиль и strict pin | 42 теста без skips; renderer и реальный Elixir contract PASS |
| Windows PowerShell 5.1 | 23 command и 13 native/WSL сценариев; setup, manager, pilot, dashboard, disk и update PASS |
| Чистая установка итогового bundle | Две новые WSL, полный Setup с `SkipLogin`, isolation smoke, чтение GitHub, readiness и confirmed Stop PASS |
| Обновление копии старой установки | `ffb3f1a` / `7a2cbf2` → итоговый комплект; descriptor переключён; продуктовая задача не запущена |
| Реальный журнал | Ревизия 77 → 78; исходный snapshot и last_cycle сохранены, baseline null |
| Сохранность данных | Все 1 253 файла workspace, Codex auth, App key, SSH identity и выбранная модель сохранены; сравнение с исходным архивом PASS |
| Модель и Codex | Каталог модели обновлён настоящим Codex app-server в новом image; прежние модель/усиление доступны |
| Isolation / filesystem / export | Настоящий SSH/Podman smoke: app-server initialize, Git add/commit, stop descendants, export, auth binding, deadline, controller loss и guardian crash/restart PASS |
| Project-container acceptance | Hooks/cwd/filesystem и остановка с сохранением частичной работы PASS; доступные проверки выполнены |
| Реальный rollback и повтор Update | Точный прежний descriptor восстановлен; тот же bundle повторно выбран без потери состояния |
| Прерывания update/rollback | Windows journals и приватные файлы; повтор после прерывания до/после переключения PASS |
| Windows manager → controller → панель | На итоговом bundle виден один общий физический том и отдельные WSL-показатели; измерение ready |
| Потеря настоящего Windows manager | На итоговом bundle панель закрылась; получено свежее подтверждение `stopped: true`; затем штатный Stop PASS |
| Пороги / unknown / привязка / свежесть / sleep clock | Управляемые измерения и реальные pipe-тесты; низкий запас и утрата подтверждения закрывают допуск |
| GitHub schema и grants | Чтение целевого Project PASS; projects_read, projects_write, publication, contents_write, delivery_read подтверждены; тестовые токены отозваны |
| Исходная установка | Указатель `%LOCALAPPDATA%/Symphony/current.json` сохранён; её версия не переключалась |

Проверка grants не меняла карточки, статусы, ветки или PR. Историческая issue #132 не запускалась и не изменялась; её журнал использован только в копиях для проверки миграции.

Чистый Setup проверялся без нового интерактивного Codex login. Реальные auth/model проверены на обновлённой копии с сохранённой авторизацией. Оплачиваемая продуктовая работа агента для приёмки не запускалась.

## Какие дефекты обнаружила реальная приёмка

1. **BOM в PowerShell 5.1.** В бинарный stdin добавлялись три байта; проверка размера останавливала установку. Для дочернего процесса теперь задаётся UTF-8 без BOM, кодировка консоли восстанавливается. Большой mise asset передаётся с точным SHA256; добавлен регрессионный тест.
2. **Stop после перезапуска WSL.** Сохранённый cgroup содержит меняющийся префикс дистрибутива. Проверяются принадлежность прежнему service и отсутствие процессов в старом и текущем payload. Для завершённого legacy worker свежий scope-bound proof исключает повторный ошибочный Stop.
3. **Неполная совместимость миграции.** Первые тесты учитывали статусы, но пропустили два реальных изменения Codex-профиля. Добавлен точный разрешённый переход и проверки отказа при расширении сети/writable roots или иных изменениях.

Промежуточные candidates не объявлялись принятыми; после исправлений pins, image и bundle пересобирались. Проверки итогового комплекта выполнены отдельно.

## Публикация и hosted CI

Владелица слила [PR #14](https://github.com/nataliastaselko8-spec/symphony/pull/14) в `main` 2026-09-22 в 13:08:37 UTC. Head PR — `cd66e546296a3ba81cdf6e20bc36a64143d87f6e`, merge commit — `d136126c76270dff8ef9d78e3d7b5b2fa7dbd180`.

| Проверка | Результат |
| --- | --- |
| [PR: make-all, run 35730267948](https://github.com/nataliastaselko8-spec/symphony/actions/runs/35730267948) | success, attempt 1 |
| [PR: pr-description-lint, run 35730268051](https://github.com/nataliastaselko8-spec/symphony/actions/runs/35730268051) | success, attempt 1 |
| [main: make-all, run 35731558158](https://github.com/nataliastaselko8-spec/symphony/actions/runs/35731558158) | failure, attempt 1; шаг `Verify make all`, exit code 2 |

После `git fetch origin main` подтверждено: дерево merge commit совпадает с head PR. Отличия от принятого source pin `9f0a6b5` ограничены тремя файлами документации. Полный журнал шага предоставила владелица: 623 теста, 1 failure, 6 skipped при покрытии 100%; seed `197295`, max_cases `8`.

### Причина сбоя и локальное исправление

Упал `late publication authorization after cancellation is rejected` в `delivery_runtime_test.exs`. Отказ `effect_revoked` уже был получен, но тест затем ожидал временный `reason: publication_result_unknown`. Завершение остановки worker и следующее наблюдение законно заменяют это диагностическое поле; порядок завершения двух задач определял, успеет ли тест увидеть его.

Прежнее ожидание воспроизведено с ошибкой при управляемом порядке событий: publisher завершён, затем подтверждена остановка worker и принято новое наблюдение. Исправление проверяет оба порядка завершения с явными сообщениями между процессами. После завершения обоих процессов и обновления наблюдения проверяются сохранённая отмена, фаза `cancelling`, единственная исходная операция с пустыми шагами и признаком отмены, завершение worker и запрет запуска другой задачи.

Исправление находится в локальной ветке `agent/fix-cancellation-test-race`. Изменены только тест и документация; runtime, профиль, порог покрытия и закреплённый комплект не менялись.

| Проверка исправления | Результат |
| --- | --- |
| Прежнее ожидание с управляемым порядком | 1 test, 1 failure на исходном ожидании `reason` |
| Весь `DeliveryRuntimeTest`, seed `197295`, max_cases `8` | 36 tests, 0 failures |
| Полный `make -C elixir all` после исправления | 624 tests, 0 failures, 6 opt-in skips; coverage 100%; format/specs/Credo/Dialyzer PASS |
| Python store / publisher / runtime | 8 / 9 / 86 tests, успешно |
| Hosted CI исправления | Ожидает публикации владелицей |

## Что осталось

1. Опубликовать ветку `agent/fix-cancellation-test-race`, создать новый PR и подтвердить успешный hosted CI исправления, затем проверку `main` после merge. Локальное исправление и полный прогон завершены; описание PR подготовлено в `.runtime-local/pr14-cancellation-fix-pr.md`.
2. Agent-runner пока остаётся локальным. Публикация его ветки и отдельный PR сейчас не требуются; hosted profile CI не выполнялся и отложен до публикации репозитория. Доказательства текущей приёмки профиля — 42 локальных теста, strict pin/renderer/Elixir contract и проверки собранного image/bundle. Они не обозначаются как успешный hosted CI.
3. После устранения сбоя CI Symphony завершить релизный допуск этапов 5–6 для локального комплекта и согласованный переход к этапу 7. Действующая установка и новая пилотная карточка остаются отдельными действиями; локальная приёмка их не запускала. Полный CI продуктового PR при новом пилоте остаётся обязательным для `PR ready`.

Шесть opt-in live E2E не выполнялись без своих внешних fixtures. В project-container 22 проверки пропущены из-за отсутствующих offline-зависимостей, Docker build отмечен как `ci_only`; результат честно `incomplete_local`, а не полный зелёный CI приложения. Реальный сон Windows и заполнение пользовательского диска не вызывались: соответствующие переходы проверены контролируемыми входными данными. Существующие Hex dependency advisories этим этапом не исправлены.

Миграция ограничена описанным переходом четырёх ролей на семь. Это не универсальный updater произвольных будущих контрактов.

## Где находятся доказательства

- `.runtime-local/stage6-make-v4.log`, `stage6-wsl-v4-tests.log`, `stage6-profile-v4-tests.log`, `stage6-strict-v4.log`, `stage6-native-v4.log`.
- `.runtime-local/stage6-clean-v4.log`, `stage6-real-update-v4.log`, `stage6-rollback-v4.log`, `stage6-reapply-v4.log`.
- `.runtime-local/stage6-preservation-v4.json`, `stage6-grants-v4.json`, `stage6-dashboard-v4.json`, `stage6-manager-loss-v4.json`, `stage6-container-v4.log`.
- `.runtime-local/pr14-cancellation-red.log`, `pr14-cancellation-green.log`, `pr14-make-all-fix.log` — воспроизведение сбоя и проверка исправления теста.
- Чистый итоговый стенд: `.runtime-local/stage6-clean-v4/instances/5d378b02ee0b4f02b57ca35e6d88f936/installation.json`.
- Обновлённая копия: `.runtime-local/stage6-old-copy-v3/installation.json`.
- Черновик описания PR: `.runtime-local/stage6-symphony-pr.md`.

Десять промежуточных тестовых WSL удалены после проверки их точных путей; итоговые стенды остановлены, архив исходной копии и журналы сохранены. Приватные стенды и архив содержат локальную авторизацию; они не входят в распространяемый bundle или Git.
