# SuperDictate

## Быстрая установка

**Нужен Mac с Apple Silicon (`M1` или новее) и macOS 14+.**

1. Откройте приложение **Terminal**.
2. Вставьте эту команду и нажмите Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/v0.2.21/install.sh | bash
```

3. В открывшемся SuperDictate нажмите `Grant` для **Microphone**,
   **Accessibility** и **Input Monitoring**.
4. Дождитесь статуса `Ready`, нажмите **правый Command** и говорите.
   Нажмите **правый Command** ещё раз, чтобы вставить текст.

При первом запуске один раз загрузится локальная модель распознавания. На
диске она занимает около 460 МБ; для установки лучше иметь не менее 1 ГБ
свободного места. После загрузки интернет для диктовки не нужен.

SuperDictate — быстрая локальная диктовка для macOS. Аудио и расшифровка не
отправляются в облачный API.

## Горячие клавиши

- **Правый Command** — начать или закончить диктовку.
- **Правый Shift + правый Command** — открыть или закрыть быструю историю.
- **Правый Option + правый Command** — альтернативное завершение; действие
  Enter настраивается в панели SuperDictate.
- Откройте `SuperDictate` из Applications, чтобы проверить службу,
  разрешения и настройки.

Панель можно полностью закрыть. Отдельная фоновая служба продолжит работать и
автоматически запустится после следующего входа в macOS.

## Зачем нужны разрешения

macOS не разрешает приложению выдать их самому:

- **Microphone** — записывать голос во время активной диктовки.
- **Accessibility** — находить активное поле и вставлять готовый текст.
- **Input Monitoring** — видеть глобальную горячую клавишу.

Если после выдачи разрешений статус не стал `Ready`, откройте SuperDictate и
нажмите `Restart` у фоновой службы. Если приложение не появилось в системном
списке, нажмите `Try Again` у соответствующего разрешения.

## Что делает установщик

Установщик:

1. Загружает `SuperDictate.zip` из
   [GitHub Releases](https://github.com/shlgd/SuperDictate/releases).
2. Проверяет закреплённую SHA-256, версию, bundle ID, архитектуру arm64,
   подпись и microphone-entitlements.
3. Безопасно заменяет `/Applications/SuperDictate.app` и открывает панель.

Xcode и Command Line Tools для обычной установки не нужны. История, настройки
и уже загруженная модель при обновлении сохраняются.

## Обновление

Запустите ту же команду ещё раз:

```bash
curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/v0.2.21/install.sh | bash
```

Приложение проверяет GitHub Releases на наличие обновлений, но не устанавливает
их без вашего действия.

## Сборка из исходников

### Самый простой способ

Команда скачает открытый исходный код, соберёт его локально и установит
результат в `/Applications`:

```bash
curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/v0.2.21/install.sh | SUPERDICTATE_BUILD_FROM_SOURCE=1 SUPERDICTATE_REF=v0.2.21 SUPERDICTATE_SOURCE_COMMIT=dcfbceb6e085f3dfc3f1a1acc2fbc4d9deeceb93 bash
```

Понадобятся бесплатные Apple Command Line Tools. Если их нет, установщик
откроет стандартный диалог установки; после его завершения запустите команду
ещё раз. Первая чистая сборка обычно занимает несколько минут.

По умолчанию сборка из исходников скачивает тег `v0.2.21` и проверяет,
что он указывает на ожидаемый коммит. Для разработки можно передать свои
`SUPERDICTATE_REF` и `SUPERDICTATE_SOURCE_COMMIT`; без совпадения коммита
установщик не запустит скачанный `scripts/build-app.sh`.

### Ручная сборка для разработки

```bash
xcode-select --install
git clone https://github.com/shlgd/SuperDictate.git
cd SuperDictate
swift run -c debug --package-path swift Parakey --self-test all
./scripts/build-app.sh ./dist/SuperDictate.app
open ./dist/SuperDictate.app
```

По умолчанию локальная сборка подписывается ad-hoc. Чтобы использовать свой
сертификат, передайте его имя:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh ./dist/SuperDictate.app
```

Не перемещайте и не удаляйте `dist/SuperDictate.app`, пока фоновая служба
запущена из этой сборки. Для обычного использования предпочтительнее команда
с `SUPERDICTATE_BUILD_FROM_SOURCE=1`, которая ставит приложение в
`/Applications`.

## Проверки перед pull request

```bash
bash -n install.sh uninstall.sh scripts/build-app.sh
plutil -lint swift/Info.plist entitlements.plist
swift run -c debug --package-path swift Parakey --self-test all
./scripts/build-app.sh ./dist/SuperDictate.app
codesign --verify --deep --strict ./dist/SuperDictate.app
```

GitHub Actions повторяет самотесты, собирает bundle, прогоняет установщик на
чистом macOS runner и проверяет удаление.

## Ограничения

- Поддерживаются только Apple Silicon и macOS 14 или новее. Intel Mac,
  Windows и Linux пока не поддерживаются.
- Публичная сборка подписана ad-hoc и не нотарифицирована Apple. Установка
  через команду выше проверена, но ZIP, скачанный вручную через браузер, может
  вызвать предупреждение Gatekeeper.
- Из-за отсутствия стабильной Developer ID подписи macOS иногда повторно
  запрашивает разрешения после обновления. Нотаризация требует платного
  аккаунта Apple Developer.
- Первый запуск требует интернет для загрузки модели. Автопроверка обновлений,
  если включена, обращается к публичному GitHub API раз в шесть часов.
- Одна запись автоматически завершается через 20 минут. При аварийном
  завершении незаконченная запись сохраняется для восстановления истории.
- Защищённые поля паролей и приложения, которые скрывают Accessibility-данные,
  могут не отдавать координаты каретки. Это влияет на положение анимации, но
  не всегда мешает вставке текста.
- Ориентир по ресурсам на текущей сборке: около 460 МБ на диске для модели,
  примерно 100–150 МБ памяти в простое и до 500 МБ во время загрузки/работы
  модели. Значения зависят от macOS и длины записи.

## Данные и приватность

- История и настройки: `~/Library/Application Support/SuperDictate`.
- Модель FluidAudio: `~/Library/Application Support/FluidAudio/Models`.
- LaunchAgent: `~/Library/LaunchAgents/com.local.superdictate.agent.plist`.
- Логи: `~/Library/Logs/SuperDictate*`.
- Аналитики, аккаунтов и телеметрии нет.

Подробнее: [PRIVACY.md](PRIVACY.md).

## Удаление

```bash
curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/v0.2.21/uninstall.sh | bash
```

Приложение и фоновая служба удаляются. История, настройки и модель сохраняются,
чтобы случайно не потерять данные и не загружать модель повторно.

## Происхождение и лицензия

SuperDictate основан на открытом проекте
[Parakey](https://github.com/rcourtman/parakey) Richard Courtman. Исходный и
изменённый код распространяется по лицензии MIT. См. [LICENSE](LICENSE) и
[NOTICE.md](NOTICE.md).
