# Переносимая среда Symphony

Этот каталог поставляется вместе с fork. Он содержит образ изолированного worker,
ограниченный транспорт, остановку и предварительную диагностику. Рабочий профиль
EmotionStat поставляется отдельно в agent-runner. PR13 подключает runtime к startup
и delivery cycle. По умолчанию действует inspection; `launch --execute` требует
явно принятого manifest v2 и живой привязки launcher. Подробные команды запуска,
выбора модели/усиления и очистки — в [руководстве PR13](../elixir/docs/github_projects_setup/pr13-runtime-guide.md).

Для профиля PR-12 нужен также companion fix передачи больших Git bundles:
управляющий транспорт дописывает фрейм целиком при частичной записи в сокет.
Проверка relay передаёт 3,5 МБ в обе стороны; прежняя одиночная запись могла
оборвать bundle до запуска transfer-контейнера. Ограничение 80 MiB сохраняется.

Поддерживаемый профиль: Linux x86_64, WSL2 с отдельным worker-дистрибутивом,
systemd с `DelegateSubgroup`, cgroup v2, rootless Podman 5.7+, pasta и
iptables-nft/ip6tables-nft с `xt_cgroup`. Приёмка выполнена на systemd 259.5 и
Podman 5.7.0. Другие версии требуют повторения smoke-теста.

В WSL с раздельными systemd-поддеревьями runtime получает полный ControlGroup
выделенной службы через systemd. Динамический ID дистрибутива не сохраняется в
конфигурации. Firewall и guardian сверяют точную службу, inode и доступность
контроллеров CPU/памяти/pids; общий ancestor не используется. Setup проверяет
изоляцию при одновременно работающих controller и worker.

## Что видит агент

```text
Controller: Symphony + GitHub App + delivery store + operator credential
    │ ограниченный управляющий SSH: prepare/start/heartbeat/stop/export
    ▼
Отдельный worker host: root supervisor → непривилегированный guardian
    │ rootless Podman, один контейнер для выданного interval
    ▼
Контейнер: /workspace/repo + /codex + временные /tmp и /home/worker
```

Только SSH в контейнер исполняет hooks, Codex и команды проекта. Управляющий SSH
принимает фреймы ограниченного протокола; переданная ему shell-команда не выполняется.
Контейнеру не передаются домашние каталоги хоста, Windows-диски, WSLg, controller
state/keys, сокеты Docker/Podman, SSH agent или GitHub-токен. `/usr`, `/etc` и
библиотеки принадлежат образу; корневая файловая система образа доступна только для чтения.

Контейнер работает как UID 10001, сопоставленный с произвольным UID worker host.
10001 и внутренний SSH-порт 2222 — часть образа, а не параметры компьютера.
Внешний task-порт выбирает Podman на loopback; management-порт задаёт локальный config.
Ограничения: capabilities отключены, `no-new-privileges`, seccomp Podman,
частные PID/IPC/mount/network namespaces, 2 CPU, 2 GiB, 512 процессов,
256 MiB `/tmp`, 64 MiB временный home, 256 MiB на отдельный создаваемый файл.
Task volume сохраняется; его общий размер этим лимитом не ограничен. Controller проверяет
свободное место перед работой и при heartbeat; ниже локального порога закрывает допуск
и останавливает активный worker с сохранением данных. Изменение профиля ресурсов требует повторной приёмки.
Предел файла повышен со 128 до 256 MiB по решению владелицы при приёмке PR12:
бинарник workerd требует около 144 MiB. Предел Git bundle остаётся 80 MiB.

Новые соединения к приватным, loopback, link-local, multicast и адресам интерфейсов
хоста блокируются отдельно для cgroup службы. Публичный интернет разрешён, DNS —
1.1.1.1/1.0.0.1. Это не доменный allowlist. Другие WSL-проекты не фильтруются.
Подтверждённое ответное SSH-соединение разрешено. Supervisor обновляет срок сетевой
готовности каждые 2 секунды; потеря supervisor или правил закрывает gate.

Контейнеры используют общее ядро Linux. Описанная граница и тесты не являются гарантией
против неизвестной уязвимости ядра или администратора хоста.

## Три конфигурации

1. Общий код и версии — здесь, в публичном fork.
2. `WORKFLOW.template.md`, правила и hooks проекта — в его `agent-runner` (PR-12).
3. Личные пути, accounts, distro, порты и принятые ревизии — локальные JSON вне checkout.

Начальный файл по умолчанию: `${XDG_CONFIG_HOME:-$HOME/.config}/symphony/local.json`.
Пример полей — [config/local.example.json](config/local.example.json).
`null` означает «ещё не настроено», не поиск случайного профиля или ключа.
Состояние хранится на Linux FS, отдельно от исходников и credentials, с правами 0700;
локальные файлы — 0600. Symlink/hardlink credentials и пересечение state/source запрещены.
Никакие значения JSON не исполняются как shell.

Для одного Project разрешена одна активная установка controller. Остальные запускают
инспекцию. Локальный flock предотвращает второй процесс на той же установке;
межкомпьютерной блокировки в PR-11 нет. Передача роли требует остановки прежнего
controller и сверки сохранённого delivery store, а не создания пустой очереди.

## Controller: настройка и конечная инспекция

Команды выполняются в Linux под пользователем controller. В shell сначала активируйте
mise согласно инструкции Symphony; соберите `elixir/bin/symphony`. Пути ниже — переменные
текущего разработчика, их значения не встроены в программы.

```bash
RUNTIME=/absolute/path/to/symphony/runtime
LOCAL_CONFIG="$HOME/.config/symphony/local.json"
python3 -I -B "$RUNTIME/scripts/runtime.py" configure --config "$LOCAL_CONFIG" --from-json /absolute/machine-parameters.json
python3 -I -B "$RUNTIME/scripts/runtime.py" render --config "$LOCAL_CONFIG"
python3 -I -B "$RUNTIME/scripts/runtime.py" pin --config "$LOCAL_CONFIG" \
  --symphony-commit "$ACCEPTED_SYMPHONY_COMMIT" \
  --profile-revision "$ACCEPTED_PROJECT_PROFILE_COMMIT" \
  --worker-image "$ACCEPTED_IMAGE_ID"
python3 -I -B "$RUNTIME/scripts/runtime.py" preflight --config "$LOCAL_CONFIG"
python3 -I -B "$RUNTIME/scripts/runtime.py" launch --config "$LOCAL_CONFIG"
```

`configure` создаёт новый config и state directory, не перезаписывает существующие.
`render` принимает JSON как YAML front matter между `---`; замены разрешены только
для полных `${runtime.NAME}` строк. Prompt не шаблонизируется. Рабочий профиль PR-12
нужно выбрать явно; тестовый профиль автоматически не применяется.

`pin` требует полные принятые SHA и image ID `sha256:...`, не выбирает moving branch.
`preflight` ничего не устанавливает и не меняет firewall. Проверяются digest WORKFLOW,
SHA обоих checkout, отсутствие изменений, доступность бинарника, private paths.
Причины `NOT_READY` перечисляются в JSON. Smoke-проверка worker отмечается отдельно;
успешная инспекция не означает готовность исполнения.

`launch` вызывает только `symphony --dry-run <WORKFLOW>` и завершается. Он не поднимает
dashboard. Вход GitHub App выполняется имеющимся credential provider controller.
`status` проверяет владельца процесса и время его создания; `stop` обращается к приватному
сокету launcher, который завершает собственного потомка. Устаревший PID не используется
для `kill`. В исполнительном режиме Ctrl+C/stop сначала отзывает допуск и отдельно
подтверждает остановку контейнера/потомков. `last_shutdown.json` сообщает результат;
`stopped: false` требует проверки оператора. Незавершённые workspaces сохраняются.

Для изменения принятого профиля создайте новый локальный config с отдельными путями
WORKFLOW/manifest. Не удаляйте и не обнуляйте delivery store действующего controller.
Файлы inspection manifest не включают исполнение даже при `role=controller`.

В PowerShell доступна оболочка с обязательными параметрами:

```powershell
.\runtime\scripts\runtime.ps1 -Distro $ControllerDistro -LinuxUser $ControllerUser `
  -LinuxRuntime $LinuxRuntimePath -LinuxConfig $LinuxConfigPath -Action preflight
```

Для `launch` необходим PATH с Erlang, например предварительная активация mise
в Linux или запуск оболочки из соответствующей Linux-сессии. Windows-wrapper
не угадывает менеджер версий и не устанавливает его. Старый `start-dashboard-demo.ps1`
теперь делегирует этому параметризованному launcher; скрытого демо-запуска больше нет.

## Worker host: явный установочный шаг

Используйте отдельный WSL2 distro, а не рабочую Ubuntu других проектов. В нём:

```ini
# /etc/wsl.conf
[boot]
systemd=true
[automount]
enabled=false
mountFsTab=false
[interop]
enabled=false
appendWindowsPath=false
```

Перезапустите только выбранный distro командой `wsl --terminate <имя>` из PowerShell.
Создайте отдельного Linux-пользователя без sudo/docker. Установите Podman, pasta,
uidmap, openssh-server, iptables, Python 3 и Git штатным менеджером пакетов.
Стандартные ssh.service/ssh.socket для этого профиля не нужны; настройка ниже поднимает
отдельную службу на loopback. Под пользователем worker должны существовать диапазоны
не менее 65536 в `/etc/subuid` и `/etc/subgid`, а также активный user manager и
`XDG_RUNTIME_DIR=/run/user/<его UID>`. Администратор может включить linger именно этому
account; исходная рабочая Ubuntu и Docker Desktop не меняются.

Из принятого checkout передайте каталог `runtime/` через tar stdin в новый каталог
Linux worker host. Windows-диски для этого подключать не нужно. Установочная копия
должна принадлежать root и быть недоступна worker на запись. Не копируйте checkout
с `.git`, `.codex`, credentials или пользовательским home. Например, PowerShell 7:

```powershell
wsl -d $WorkerDistro -u root --exec install -d -m 755 $LinuxPackagePath
tar -cf - -C runtime . | wsl -d $WorkerDistro -u root --exec tar --no-same-owner --no-same-permissions -xf - -C $LinuxPackagePath
```

Каталог назначения выбирается новый для принятой ревизии; запущенная копия не заменяется.
Соберите образ под host-пользователем worker из `worker/Containerfile`:

```bash
podman build --tag localhost/symphony-worker:accepted "$PACKAGE/worker"
podman image inspect localhost/symphony-worker:accepted --format 'sha256:{{.Id}}'
```

В `runtime-lock.json` закреплены base image, uv image, Codex и task Python. Пакеты apt
получаются из репозитория Ubuntu на момент сборки; сборка не объявляется побитово
воспроизводимой. После проверки закрепляется **полный ID итогового образа** и используется
`--pull=never`. Для другого компьютера образ можно передать `podman save/load` и сверить ID.

Создайте private state directory под home worker, владельцем — именно worker. Скопируйте
[config/host.example.json](config/host.example.json) в root-owned JSON вне checkout и замените
все placeholders. В `management_public_key` передаётся только публичная часть отдельного
controller SSH-ключа. Закрытая часть остаётся у controller.

Проверка без изменений и отдельный тест с временными ресурсами:

```bash
sudo python3 -I -B "$PACKAGE/scripts/host-preflight.py" --worker "$WORKER_ACCOUNT" --image "$IMAGE_ID"
sudo python3 -I -B "$PACKAGE/tests/runtime_smoke.py" --worker "$WORKER_ACCOUNT" --image "$IMAGE_ID" --package "$PACKAGE"
```

Smoke использует фиктивный Git-репозиторий и публичный npm endpoint для проверки HTTPS.
Он создаёт только свои временные units, контейнеры, SSH-ключи и cgroup rules; после подтверждённой
остановки удаляет их. Реальные GitHub-токены, ChatGPT login и модельные запросы не используются.
При неподтверждённой остановке workspace сохраняется. Не запускайте его как обычный preflight.

Явный запуск управляющей среды:

```bash
sudo python3 -I -B "$PACKAGE/scripts/host.py" --config /absolute/root-owned-host.json
```

Supervisor работает в foreground. Ctrl+C останавливает собственные services и снимает
только их firewall rules после проверки отсутствия процессов. Автозапуск не включается.
При смене интерфейсов или пропаже правил supervisor останавливает среду. После аварии
сначала остановите указанные в config units и подтвердите пустую cgroup; оставшиеся
rules/каталог `/run/symphony-runtime/<name>` принадлежат только этой установке.
Нельзя применять глобальные `iptables -F`, очищать `/run` или удалять state/workspaces.

Каждый запуск сообщает публичный management host key. Controller сохраняет его через
доверенный установочный канал в собственный `known_hosts`. Task host key приходит в ответе
`start` через этот канал и закрепляется отдельно. `StrictHostKeyChecking=yes`,
`IdentitiesOnly=yes`, forwarding выключен. Не применять `ssh-keyscan` как доказательство доверия.

## Credentials и готовность к работе

GitHub App PEM, installation token и operator credential находятся только на controller.
Host guardian не получает их. Отдельный Codex login выполняется через `runtime login`;
старый `$HOME/.codex` controller не монтируется в worker. Guardian сохраняет auth.json
в `<worker-state>/auth/` и переносит только его в `/codex` текущего цикла. Обновлённая
авторизация сохраняется после подтверждённой остановки. История, конфигурация, MCP
и skills controller не копируются. Legacy `codex-auth.json` читается только при
отсутствии новой auth area; для новых установок используется отдельная процедура входа.

Для login используйте тот же принятый контейнерный профиль и `codex login --device-auth`;
браузерное подтверждение выполняет оператор. Модель и уровень рассуждений выбираются
после входа, до открытия допуска, по [руководству](../elixir/docs/github_projects_setup/pr13-runtime-guide.md).

## Остановка, передача кода и callbacks

Guardian сохраняет привязку cycle/interval/generation и фазу ресурса, но не дублирует
delivery store или бюджеты Symphony. Повтор `prepare` с тем же содержимым идемпотентен;
изменённый payload или старый interval отклоняется. Повтор `start` не продлевает deadline.
Controller должен посылать heartbeat каждые 10 секунд. Без него остановка начинается через
45 секунд, при истечении выделенного срока — раньше. Используется Linux CLOCK_BOOTTIME,
учитывающий suspend. Сетевое подтверждение живёт 20 секунд. Мягкий stop — до 10 секунд;
после него — bounded forced removal и проверка пустого payload cgroup. Ошибка даёт
`stop_unconfirmed`; новый interval и экспорт запрещены, данные остаются.

Controller получает код разрешённого `dev` commit и создаёт bundle с единственным
`refs/heads/dev`. `prepare` проверяет размер/хеш и импортирует его в отдельном контейнере
без сети и credentials. Новая копия имеет detached HEAD; создание task branch и правила
продолжения — PR-12. Существующий workspace не reset/clean-ится.

После остановки `export` создаёт bundle только task branch с ожидаемым SHA в отдельном
контейнере без сети, Codex auth и hooks. Максимум 80 MiB. Controller проверяет хеш передачи,
записывает свой private immutable bundle и передаёт его существующему GitPublisher PR-09.
GitPublisher независимо проверяет историю и допустимые файлы перед публикацией.
Код из worker `.git` не исполняется на controller. Прямые push/merge из runtime отсутствуют.

`SymphonyElixir.WorkerTransport.callbacks(binding, exchange)` даёт совместимые
`stop_verifier` и `export_candidate`. Явный `exchange` использует
`scripts/controller-transport.py --config <private transport.json>` через framed stdin/stdout.
Transport config содержит `ssh_config`, `destination`, `export_directory`, `cycle`, `branch`,
`interval`, `generation`; пути и scope задаёт controller, не модель. Runtime получает
`stop_verifier`; publisher — `export_candidate` в своих options. В PR13
`Runtime.Worker` связывает lifecycle с `scripts/controller.py`
с неизменяемыми привязками текущего interval; прежний ручной transport остаётся
низкоуровневым контрактом и не включает допуск самостоятельно.

Подробные проверки и ограничения: [отчёт PR-11](../elixir/docs/github_projects_setup/pr11-validation.md).
Технические источники: [Podman 5.7 run](https://docs.podman.io/en/v5.7.0/markdown/podman-run.1.html),
[uv в контейнерах](https://docs.astral.sh/uv/guides/integration/docker/),
[Codex authentication](https://developers.openai.com/codex/auth/).
