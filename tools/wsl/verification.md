# Проверка установщика

Дата: 2026-09-18. Проверка кода не заменяет приёмку чистой установки.

В Linux/WSL прошли 60 runtime-тестов и 32 теста operator/bootstrap/комплекта.
Проверены настоящие приватные файлы, flock, бинарная передача, Git bundles,
отказ при изменённом checkout, безопасное извлечение архивов, сохранение работы
и остановка настоящего тестового controller после закрытия stdin владельца.
В этом тесте GitHub и управление реальным task container подменены.

В Windows PowerShell 5.1 проверены:

- 19 сценариев внутреннего operator с подменёнными WSL endpoints;
- 11 сценариев настоящих native argv/stdin, бинарных SHA256, ограничения логов,
  атомарного checkpoint, Windows ACL/mutex и проверки комплекта;
- передача argv через настоящий wsl.exe в Linux Python, включая пробелы и кавычки;
- мастер с подменёнными WSL endpoints: сбой пакетов, поздний сбой готовности,
  продолжение с тем же ID/descriptor и уже импортированным ключом, отказ от повторной
  настройки завершённой установки и от изменённых helper-файлов;
- настоящий скрытый Windows manager и дочерние fixture-процессы: готовность,
  сохранение процессов, отклонение старого stop-запроса и подтверждённая остановка.

Исправлен nested prepare.lock в maintenance.login/Models/cleanup при сохранённом
worker.json. Launcher lock удерживается; prepare lock проверяется, затем освобождается
перед recover и снова захватывается с повторной проверкой worker. Удалять сохранённую
задачу для обхода ошибки не требуется.

## Воспроизведение

Linux:

```bash
python3 -I -B -m unittest discover -s runtime/tests -p 'test_*.py'
python3 -I -B -m unittest discover -s tools/wsl/tests -p 'test_*.py'
```

Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/wsl/tests/test-commands.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/wsl/tests/test-installer.ps1 -WslDistro YOUR_TEST_DISTRO
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/wsl/tests/test-setup.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/wsl/tests/test-manager.ps1
```

Тесты не меняют пакеты, пользователей или службы существующих Ubuntu.
Временные файлы и дочерние процессы принадлежат только каждому тесту.

## Приёмка настоящей установки

До признания первой поставки принятой остаются полный Setup из её manifest на двух
новых WSL-дистрибутивах, реальный isolation smoke внутри них, GitHub read inspection,
новый Codex login, model/list и выбор effort, Start/Stop/повторный Start с закрытыми
терминалами, сон/пробуждение Windows и остановка при утрате manager.
Установщик выполняет bootstrap, smoke и доступные проверки; браузерный login
и проверка Windows после сна требуют участия оператора.

В ходе разработки эти системные действия не выполнялись. Старые среды и credentials
не переносились. Продуктовый пилот, задачи, PR и деплой не запускались.
