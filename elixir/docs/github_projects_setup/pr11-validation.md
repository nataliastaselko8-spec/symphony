# PR-11: результаты проверки

Дата: 2026-09-17. Ветка: `agent/feat/portable-worker-runtime`, база `df918b9`.
Публикация и merge остаются за владелицей. Product/agent-runner/knowledge-base не изменялись.

## Что реализовано

- Общий `runtime/` в fork: образ, локальная конфигурация, manifest/pin, render и launcher.
- Root-owned supervisor и непривилегированный guardian в отдельной делегированной cgroup.
- Task SSH внутри rootless Podman; отдельный management SSH с forced command и pinned host key.
- Ограничения файлов, namespaces, capabilities, ресурсов и сети конкретной службы.
- Heartbeat/deadline, подтверждение остановки всех task-процессов, сохранение workspace.
- Импорт `dev` bundle и экспорт task branch через контейнеры без сети и credentials.
- Контролируемые `WorkerTransport` callbacks, не подключённые автоматически к startup.
- Старый персональный launcher и canary параметризованы. Личных путей в общем runtime нет.

Контракт и воспроизводимые команды: [runtime/README.md](../../../runtime/README.md).

## Среда приёмки

Это параметры проверенной машины, **не defaults программ**.

| Компонент | Проверенное значение |
| --- | --- |
| WSL kernel | `6.18.33.2-microsoft-standard-WSL2` |
| Worker distro | Ubuntu 26.04, отдельный от рабочей Ubuntu controller |
| Podman / manager | 5.7.0; rootless; cgroupfs внутри systemd-delegated service |
| Host UID | 2002; дополнительная независимая проверка под временным UID 2003 |
| Image UID | 10001, через keep-id mapping |
| Codex CLI | 0.154.0, Linux binary внутри образа |
| uv / task Python | 0.11.32 / 3.11.15 |
| Итоговый image ID | `sha256:6145ad195c748056819a1cac5f99d49012801cb8a2b7db002aaf8f95b800533d` |

Образ собран локально, в registry не опубликован. Разработчик собирает/получает принятый
образ, сверяет его ID и задаёт локальный manifest. Значение выше — свидетельство проверки,
не обещание доступности этого ID после нового clone.

## Проверки

| Проверка | Результат |
| --- | --- |
| `make -C elixir all` | Elixir format/specs/Credo, 552 теста, 0 failures, 6 skips, 100% измеряемого coverage; Dialyzer без ошибок |
| Python store/publisher | 8 + 9 тестов |
| Python runtime | 29 тестов: config, pins, private files, framing, locks, stop/export, env и launcher |
| PR body | `mix pr_body.check --file docs/github_projects_setup/pr11-description.md` — PASS |
| Настоящие SSH и Codex | CLI запускается в контейнере; `app-server initialize` отвечает без создания thread/turn |
| Файлы хоста | Чтение, листинг, запись и symlink escape к host/controller canaries не проходят |
| Root filesystem | Запись в `/etc` отклонена; `/usr` и инструменты образа доступны |
| Привилегии | UID 10001, CapEff=0, NoNewPrivs=1, Seccomp=2 |
| Сеть IPv4/pasta | Host listener доступен снаружи cgroup; из task SSH — отказ с увеличением счётчика REJECT |
| IPv6 | Loopback listener доступен снаружи; процесс в той же service cgroup отклонён IPv6-правилом |
| Публичная сеть | HTTPS к `registry.npmjs.org` работает из task SSH |
| Management SSH | Framed status принят; произвольная переданная SSH-команда не исполнена |
| Передача кода | Импорт ровно выбранного dev SHA; после остановки получен bundle только task branch |
| Controller transport | Реальный bundle принят через pinned management SSH и записан с private permissions |
| Отмена/stop | Фоновый `sleep` завершён вместе с контейнером; export до stop запрещён |
| Старая команда | Неверный interval/generation отклонён, новый ресурс не затронут |
| Повтор | prepare/start/stop/export идемпотентны; повтор start не продлевает срок |
| Сбой export | Перед повторным допуском выполняется stop; неопределённая очистка удерживает ресурс |
| Deadline | Интервал с коротким тестовым сроком завершён автоматически |
| Потеря controller | Без heartbeat остановка подтверждена примерно через 45,4 секунды |
| Guardian crash | SIGKILL главного процесса привёл к завершению остальных процессов unit |
| Guardian restart | Workspace/коммит сохранены; фаза stopped; задача не возобновилась автоматически |
| Другой account | Та же программа прошла под UID 2003 с другим home и отдельным Podman image store |
| Пробелы/Unicode | Реальные task/state пути smoke содержали пробелы и кириллицу |
| WSL restart | Перезапущен только worker distro; host preflight и повторный smoke прошли |
| Очистка | Собственные units, containers и firewall jumps/chains сняты; временный account удалён |

IPv6-проверка доказывает применение фильтра к cgroup, используемой pasta; она не
объявляется проверкой внешней IPv6-маршрутизации провайдера. Smoke не сканирует LAN.
Проверены конкретные canaries и профиль; отсутствие будущих kernel/container escape
уязвимостей из результата не следует.

Во время разработки обнаружены и исправлены: несовместимые tmpfs options Podman;
ложная готовность по старому socket после аварии; потеря CODEX_HOME при входе через SSH;
неверная область file-size limit при распаковке нового образа; очистка transfer-процесса
при неудачном экспорте. Проверки не отключались для получения успешного результата.
Существующий тест stale retry timer мог попасть в сетевой startup poll Linear;
он переведён на memory tracker и синхронный барьер вместо фиксированного sleep.

## Изменения на компьютере

В выделенном worker distro установлен openssh-server. Стандартные ssh/sshd service и
ssh.socket остаются masked/inactive, порт 22 не слушается. Для host account worker
включён linger user manager; рабочая Ubuntu других проектов не изменялась.
Остались собранный локальный образ и root-owned установочная копия для проверки.
Тестовые supervisor/management службы не включены в автозапуск и после теста остановлены.

## Что относится к следующим этапам

- PR-12: настоящий project template, dev-based hooks, продуктовые проверки и зависимости app.
- PR-13: назначение единственного controller, подключение callbacks, доставка heartbeat,
  асинхронная отмена, отдельный Codex login в принятом профиле, итоговый deployment manifest.
- PR-14: разрешённая владельцем живая задача. PR-11 не выполняет GitHub mutations,
  merge/deploy, модельные turn или live-запуск Project.

В зависимостях Symphony существующие security advisories продолжают выводиться при
`mix deps.get`. Их устранение не подменяется sandbox-проверками и остаётся условием
подготовки production runtime. Общий размер сохраняемых task volumes не квотируется
на уровне Podman bind mount; эксплуатация должна контролировать свободное место.
