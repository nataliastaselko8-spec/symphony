# Запуск изолированной Symphony и локальные настройки

PR13 связывает controller, worker, GitHub Projects и delivery gate. Реальная первая
карточка и её полный dev-цикл относятся к пилоту PR14. До допуска можно открыть
дашборд; пустой фильтр карточек, отсутствие входа/модели или неподтверждённый dev
показываются как причины блокировки.

## Что подготовить

1. Чистый Linux checkout принятого Symphony commit и собранный `elixir/bin/symphony`.
2. Чистый checkout проектного agent-runner: `profile_contract: 1`, `runtime_contract: 2`,
   его `worker/profile-lock.json` закрепляет тот же Symphony commit.
3. Проверенный производный project image с метками `io.symphony.profile-revision`
   (полный commit профиля) и `io.symphony.runtime-contract=2`. Базовый образ без hooks
   не подходит для исполнения EmotionStat. На другой машине можно передать образ
   через `podman save/load` и сверить полный image ID.
4. Worker host и management SSH по [runtime/README](../../../runtime/README.md).
   Администратор запускает root supervisor отдельно; обычному controller sudo не нужен.
5. Локальные private файлы GitHub App и operator credential. Их содержимое в Git,
   чат, аргументы команд и worker не передаётся. App использует существующий профиль
   прав, включая Actions: read; CI rerun остаётся действием оператора в GitHub.

Только одна установка исполняет задачи одного Project. Все другие — inspection.
Локальный flock защищает одну установку, а не координирует разные компьютеры.
Перед передачей роли нужно остановить прежний controller и перенести проверенное
состояние, сохранив цикл и бюджеты; новый пустой store для обхода ожидания запрещён.

Производный образ собирает host-пользователь worker из чистого checkout профиля:

```bash
python3 -I -B "$PROJECT_PROFILE/worker/build.py" \
  --revision "$ACCEPTED_PROJECT_PROFILE_COMMIT" --base-image "$ACCEPTED_BASE_IMAGE_ID" \
  --tag "$LOCAL_PROJECT_IMAGE_TAG"
```

Чтобы старые образы этой установки могли освобождать место автоматически, используйте
собственный namespace. Вычисление выполняется **под worker account** для его state root:

```bash
IMAGE_NAMESPACE=$(python3 -I - "$RUNTIME/lib" "$WORKER_STATE" <<'PY'
import pathlib, sys
sys.path.insert(0, sys.argv[1])
from symphony_runtime.images import namespace
print(namespace(pathlib.Path(sys.argv[2])).removesuffix(':'))
PY
)
python3 -I -B "$PROJECT_PROFILE/worker/build.py" \
  --revision "$ACCEPTED_PROJECT_PROFILE_COMMIT" --base-image "$ACCEPTED_BASE_IMAGE_ID" \
  --installation "$IMAGE_NAMESPACE" --tag "$IMAGE_NAMESPACE:accepted"
```

Общий base image и образы без метки владения установка самостоятельно не удаляет.

## Локальный профиль

Все пути, имена WSL-дистрибутивов и Linux-учётных записей задаёт разработчик.
Начните с `runtime/config/local.example.json`: schema v2, `role: inspection`,
`pilot_item_ids: []`. Передайте machine parameters команде `configure`, затем `render`
и `pin`, как описано в runtime/README. Inspection manifest не разрешает исполнение.

Для controller нужен v2 config с `role: controller`. Отдельно задаются пути `workflow`
и `manifest`; state root действующего проекта сохраняется. `render` и `pin` не
перезаписывают несовпадающие существующие файлы: для изменения принятого профиля
выбирают новые локальные имена workflow/manifest, сохраняя прежний delivery store.

Переменные ниже задаются в своей Linux-сессии:

```bash
RUNTIME=/absolute/path/to/symphony/runtime
LOCAL_CONFIG=/absolute/private/path/local.json
```

После рендера controller workflow:

```bash
python3 -I -B "$RUNTIME/scripts/runtime.py" pin --execute --config "$LOCAL_CONFIG" \
  --symphony-commit "$ACCEPTED_SYMPHONY_COMMIT" \
  --profile-revision "$ACCEPTED_PROJECT_PROFILE_COMMIT" \
  --worker-image "$ACCEPTED_IMAGE_ID"
```

Manifest v2 связывает SHA исходников/профиля, digest исполняемого файла, runtime package,
локального config и workflow. Изменение любого из них закрывает активацию. Новая
модель/усиление сохраняются отдельно и не меняют системные права или budget.

## Вход, модель и усиление

При остановленном launcher:

```bash
python3 -I -B "$RUNTIME/scripts/runtime.py" login --config "$LOCAL_CONFIG"
```

Откроется отдельная процедура `codex login --device-auth` внутри пустого изолированного
контейнера. Перейдите по показанному адресу и подтвердите вход самостоятельно.
Одноразовый код остаётся в вашем терминале. Время входа ограничено; отдельный heartbeat
и stop работают и здесь. Рабочая папка прежней задачи не подключается. Сохраняется
только выделенная авторизация; после подтверждённой остановки login-контейнера его
временные ключи удаляются и восстанавливается привязка прежней остановленной задачи.

Команда входа также читает `model/list`. Повторно обновить список без нового входа:

```bash
python3 -I -B "$RUNTIME/scripts/runtime.py" models --config "$LOCAL_CONFIG"
python3 -I -B "$RUNTIME/scripts/runtime.py" select-model --config "$LOCAL_CONFIG" \
  --model "$CHOSEN_MODEL" --effort "$CHOSEN_EFFORT"
```

Оба значения берутся из показанного списка. Модели и уровни не зашиты в fork.
Выбор хранится в `state_root/model-selection.json`, каталог — в `model-catalog.json`.
Каталог привязан к образу и действителен 24 часа; перед запуском сессии Codex всё равно
повторно получает свежий список. Для обновления локального каталога остановите launcher.

При первом рабочем interval пара закрепляется в `execution-profiles/<cycle>.json`.
Для продолжения цикла она должна совпадать с локальным выбором. Изменение выбора
не обнуляет бюджет и не переносит незавершённую работу на другую модель. Если случайно
изменили пару, верните значения из сохранённой привязки перед продолжением.

В `thread/start` явно передаются model и `config.model_reasoning_effort`. Перед
первым prompt проверяются ответные `model` и `reasoningEffort`; каждый `turn/start`
получает ту же пару. Несовпадение закрывает допуск. При событии `model/rerouted`
сессия прерывается; продолжение на другой модели автоматически не выполняется.
Дашборд различает **выбранные** и **подтверждённые Codex** параметры.

«Усиление» — reasoning effort. Оно влияет на рассуждения, но не увеличивает права,
выделенные 60 минут, отдельный бюджет исправлений или число попыток CI.
Выбор модели в desktop-окне Codex к worker отношения не имеет.
[Контракт app-server](https://learn.chatgpt.com/docs/app-server).

## Дашборд и один пилот

Перед запуском в окружении controller задаются согласованные App ID, Client ID и
Installation ID; private key берётся из local config. Запускать в shell с Erlang в PATH.

```bash
python3 -I -B "$RUNTIME/scripts/runtime.py" preflight --execute --config "$LOCAL_CONFIG"
python3 -I -B "$RUNTIME/scripts/runtime.py" launch --execute --config "$LOCAL_CONFIG"
```

Откройте локальный адрес с настроенным `dashboard_port`, войдите operator credential.
Preflight разделяет `controller_ready` и `worker.ready`: готовый интерфейс может
показывать закрытый допуск. В конфигурации выбирается не больше одной Project item ID.
Текущие Agent allowed/Status, dev, checks и подтверждения дополнительно проверяет gate.
`--execute` не означает «игнорировать блокировки».

После окончательного завершения одного цикла launcher подтверждает stop, сохраняет
итог и завершается. Наличие `last_cycle` запрещает автоматический переход к следующей
обычной задаче в профиле PR13. Нельзя удалять store, чтобы обойти это ограничение.

Остановка из другого терминала:

```bash
python3 -I -B "$RUNTIME/scripts/runtime.py" status --config "$LOCAL_CONFIG"
python3 -I -B "$RUNTIME/scripts/runtime.py" stop --config "$LOCAL_CONFIG"
```

Ctrl+C запускает ту же последовательность. При `stopped: false` проверьте worker host;
не удаляйте workspace и не запускайте второй controller. При потере controller
guardian самостоятельно начинает остановку после истечения heartbeat lease.

## Диск, хранение и очистка

- Пока задача ждёт CI, review, merge, deployment, проверки dev или исправлений,
  workspace и данные восстановления сохраняются независимо от длительности ожидания.
- Только успешные `completed/recovered` получают неизменяемый итоговый отчёт
  `reports/<cycle>.json`. Тяжёлые данные становятся доступными для очистки через
  **7 дней после этого отчёта**; срок настраивается `retention_days` и не сокращается
  случайным возвратом к значению по умолчанию. Отчёт, привязка и подтверждения модели остаются.
- Guardian проверяет очистку при простое примерно раз в час. Controller очищает
  свои старые transfer-данные при подтверждённом восстановлении/остановке и команде cleanup.
  Выключенная установка очистку не выполняет.
- Отменённые, аварийные и незавершённые циклы не очищаются автоматически.
  `cleanup --apply` тоже их сохраняет. Оператор отдельно решает судьбу неопубликованной
  работы после сверки PR и сохранения нужного результата; отдельной кнопки их удаления в PR13 нет.
- OTP-лог: 5 файлов по 10 MiB; container log: до 2 MiB; служебный maintenance-log:
  ротация по 2 MiB. Внутренние данные Codex сохраняются как часть цикла до его завершения,
  не обрезаются во время сессии.
- По умолчанию ниже **10 GiB** показывается предупреждение, ниже **5 GiB** блокируется
  допуск и отзывается активный worker. Проверка — перед запуском и при heartbeat.
  Это контроль свободного места, не квота: интенсивная запись может опередить проверку.
- Образы очищаются только через namespace этой установки, без global prune и force.
  Текущий образ и образы контейнеров сохраняются. Последние ссылки удаляются только
  для image с build-меткой `io.symphony.installation` этой установки; общие образы остаются.

```bash
# Сначала список кандидатов; launcher должен быть остановлен.
python3 -I -B "$RUNTIME/scripts/runtime.py" cleanup --config "$LOCAL_CONFIG"
# Удалить только успешно завершённые данные старше срока хранения.
python3 -I -B "$RUNTIME/scripts/runtime.py" cleanup --apply --config "$LOCAL_CONFIG"
```

Нет рекурсивного удаления пользовательских home, Windows-папок или произвольного
пути из карточки. Cycle/generation берутся из private controller state и проверяются
по scope; symlink/hardlink и смена владельца запрещают очистку.

## Что эта приёмка не заменяет

Отдельный реальный вход, выбранная оператором модель/усиление, права GitHub App,
одна согласованная карточка и ручное подтверждение актуального dev — условия пилота.
Тесты на фиктивных GitHub-ответах и тестовом Codex-протоколе не означают их выполнения.
Поддержанный entrypoint — Linux escript через launcher. Burrito binary отдельно не
принимался; его исполнительный профиль здесь не объявляется поддержанным.
