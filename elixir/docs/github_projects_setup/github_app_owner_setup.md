теперь перепроверь план и какой шаг мы може начать?
# GitHub App для EmotionStat — инструкция владельцу организации

Дата: 2026-09-15. Получатель результата: Наталья, GitHub **nataliastaselko8-spec**.

Нужно создать отдельное GitHub App организации **EmotionStat**, установить его для **EmotionStat/app** и передать Наталье данные подключения. Приложение предназначено для будущей работы Symphony с [доской Delivery, Project №1](https://github.com/orgs/EmotionStat/projects/1): чтения задач, обновления статусов, отчётов и создания PR в dev.

Результат этой инструкции: **App создано и установлено, данные и ключ переданы**. Подключение раннера и проверка его прав выполняются следующим этапом. Создание App само по себе не запускает Symphony.

**1. Откройте настройки именно EmotionStat**

Войдите в GitHub под владельцем организации и откройте [GitHub Apps организации EmotionStat](https://github.com/organizations/EmotionStat/settings/apps).

Путь в интерфейсе: **EmotionStat → Settings → Developer settings → GitHub Apps**.

Владельцем должна быть EmotionStat.
**2. Заполните форму**

| Поле | Значение для этого подключения |
| --- | --- |
| GitHub App name | emotionstat-agent-runner; если занято, выберите свободное имя и сообщите его Наталье |
| Description | Symphony automation for EmotionStat Delivery |
| Homepage URL | https://github.com/EmotionStat |
| Callback URL / Redirect URI | Оставить пустым |
| Allow wildcard matching | Выключить |
| Expire user authorization tokens | Оставить включённым; пользовательский OAuth в этом профиле не используется |
| Request user authorization (OAuth) during installation | Выключить |
| Enable Device Flow | Выключить |
| Setup URL | Оставить пустым |
| Redirect on update | Выключить |
| Webhook → Active | **Выключить** |
| Webhook URL / Secret | Оставить пустыми |
| Subscribe to events | Не выбирать события |
| Where can this GitHub App be installed? | **Only on this account**; подпись должна указывать **EmotionStat** |

Symphony будет периодически опрашивать GitHub. Публичный сервер и webhook URL для этого подключения не требуются.

**3. Выберите разрешения**

Это права регистрации App для согласованного рабочего процесса. Позже раннер будет получать токены с более узкими правами для конкретных операций.

| Раздел | Permission | Доступ | Для чего |
| --- | --- | --- | --- |
| **Organization permissions** | **Projects** | **Read and write** | Читать доску и обновлять поля её карточек |
| Repository permissions | Contents | Read and write | Читать код и публиковать ветки задач |
| Repository permissions | Issues | Read and write | Читать issue и вести комментарий-отчёт |
| Repository permissions | Pull requests | Read and write | Создавать и обновлять PR |
| Repository permissions | Actions | Read-only | Читать результаты workflow, jobs и доступные свидетельства проверок |
| Repository permissions | Metadata | Read-only | Служебное чтение сведений о репозитории; обычно включается автоматически |
| Остальные Organization / Repository permissions | Все остальные | No access | Сейчас не нужны |
| Account permissions / Enterprise permissions | Все | No access | Сейчас не нужны |

Projects выбирается в **Organization permissions**. Repository Projects / Projects classic, если такой пункт есть, оставьте без доступа. Workflows, Administration, Secrets, Checks, Commit statuses и Deployments сейчас также не включайте. Если выбранная реализация потребует чтения Checks или Deployments, отдельно согласуем добавление Read-only.

Описание возможностей разрешений: [выбор прав GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app), [справочник прав API](https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps).

Ограничение установки одним репозиторием относится к repository permissions. Оно **не сужает Organization Projects до одной доски**: работу только с Project №1 дополнительно ограничит конфигурация адаптера.

Не добавляйте это App в bypass rulesets или в список участников, которым разрешено обновлять защищённые dev/main. Contents write технически позволяет операции с ветками и merge; окончательный запрет прямого push и автоматического merge требует отдельной настройки и проверки GitHub rules. В этом шаге существующие правила веток не изменяем.

**4. Создайте и установите App**

1. Нажмите **Create GitHub App**.
2. В меню созданного приложения откройте **Install App**.
3. Выберите **EmotionStat**.
4. Выберите **Only select repositories**.
5. Отметьте только **EmotionStat/app**.
6. Нажмите **Install** и подтвердите запрошенные разрешения.

Если меняли уже установленное App, проверьте, что новые разрешения одобрены для его установки: изменения регистрации сами по себе не обновляют ранее одобренные права. [Установка собственного App](https://docs.github.com/en/apps/using-github-apps/installing-your-own-github-app), [изменение разрешений](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app#about-changes-to-permissions).

Доступ к knowledge-base, agent-runner, marketing, qdata и личному форку Symphony для этого подключения не требуется.

**5. Запишите идентификаторы и создайте приватный ключ**

На странице настроек регистрации App запишите **App ID** и **Client ID**. Это разные идентификаторы; Client ID можно передать дополнительно, **Client secret создавать не требуется**.

Откройте настройку установки приложения в EmotionStat и скопируйте полный URL. Число после /installations/ в адресе — **Installation ID**. Если число не удаётся найти, передайте полный URL страницы установки; идентификатор уточним при подключении. Installation ID относится к установке, а App ID — к самой регистрации.

Далее в настройках App:

1. Найдите **Private keys**.
2. Нажмите **Generate a private key**.
3. Сохраните скачанный файл **.pem** вне Git-репозиториев.
4. Скопируйте **fingerprint**, который GitHub показывает рядом с этим ключом.

GitHub хранит публичную часть ключа; скачать тот же приватный файл повторно из интерфейса нельзя. Fingerprint из GitHub — отпечаток публичного ключа, а не хеш файла .pem. [Управление ключами](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps).

**6. Передайте Наталье комплект подключения**

| Что передать | Где взять | Как передать |
| --- | --- | --- |
| Название App и ссылка на его настройки | Страница регистрации App | Обычным сообщением |
| App ID | Страница регистрации | Обычным сообщением |
| Client ID | Страница регистрации; дополнительный идентификатор | Обычным сообщением |
| Installation ID и полный URL установки | Настройки установленного App в EmotionStat | Обычным сообщением |
| Подтверждение Only select repositories → EmotionStat/app | Страница установки | Текстом или скриншотом без секретов |
| Фактически одобренные permissions | Страница установки / Permissions & events | Текстом или скриншотом без секретов |
| Fingerprint нового ключа | Раздел Private keys | Обычным сообщением |
| **Сам файл .pem** | Скачан при Generate a private key | **Отдельно через защищённый канал** |

