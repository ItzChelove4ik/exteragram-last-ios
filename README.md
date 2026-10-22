# GlowGram iOS

GlowGram — экспериментальный клиент на базе Telegram iOS с портированными возможностями exteraGram Lite.
Исходная Android-версия: **12.10.6 Lite**. База iOS и её точный commit зафиксированы в `port/manifest.json`.
Полное совпадение возможностей Android и iOS ещё не подтверждено.

В `ios/` находятся Swift-модули настроек, локализаций, перевода, экспорта и распознавания речи.
В `port/` находятся патчи и дополнительные исходники для интеграции в Telegram.
Скрипт подготовки проверяет точное количество совпадений каждого патча до изменения файлов.

## IPA

GitHub Actions **Build IPA** проверяет Swift-модули и собирает приложение на macOS/Xcode 26 для iPhone/iPad (arm64, iOS 15+).
При успешной сборке IPA доступен в **Releases** и в артефактах Actions.
Это **IPA без подписи**: перед установкой его нужно подписать, например через Sideloadly или AltStore.
Расширения отключены для этой сборки. Push и App Groups зависят от профиля подписи.

Сборка запускается при push в `main` или вручную в Actions → Build IPA → Run workflow.
Перед сборкой нужно задать **свои** API-параметры приложения с [my.telegram.org/apps](https://my.telegram.org/apps)
в GitHub → Settings → Secrets and variables → Actions:
`TELEGRAM_API_ID` и `TELEGRAM_API_HASH`. Укажи оба значения от одного приложения.
Параметры официального Telegram iOS больше не используются как запасной вариант:
его проверка входа через APNS не подходит переподписанной IPA и может закончиться ошибкой «нет соединения».
Без корректных параметров проверка останавливает workflow до компиляции.
При входе приложение запрашивает обычную доставку кода без push-подтверждения;
способ доставки выбирает Telegram (например, код в уже открытом клиенте).
Сертификаты Apple и provisioning profiles для сборки не требуются.

## Локальная сборка на Mac

```sh
python3 -m venv .build/port-tools
source .build/port-tools/bin/activate
python3 -m pip install -r scripts/requirements.txt
export TELEGRAM_API_ID="<api_id своего приложения>"
export TELEGRAM_API_HASH="<api_hash того же приложения>"
python3 scripts/build_configuration.py --check
python3 scripts/prepare_upstream.py
python3 scripts/check_ios_assets.py
python3 scripts/build_ipa.py --build-number 1
```

На Windows можно работать с исходниками и запускать сборку в GitHub Actions.
Основной Telegram-код и зависимости загружаются из закреплённых upstream-репозиториев;
они не дублируются в этом репозитории. Условия лицензирования этих компонентов находятся
в их исходных репозиториях. Происхождение портированных данных описано в `provenance.json`
и `ios/ExteraExport/Provenance/evidence.json`.

## Название и иконки

Имя приложения, раздел настроек и локализации используют название **GlowGram**.
Основная иконка берётся из `assets/icon.png` (непрозрачный PNG 1024×1024).
`assets/foreground.png` используется для прозрачного значка быстрых команд.
Скрипт подготовки подключает иконку к Icon Composer, создаёт размеры для iPhone/iPad
и обновляет превью в настройках. Имя файла будущей сборки — `GlowGram-unsigned.ipa`.
Перед полной сборкой каталоги ресурсов проверяются компилятором Xcode `actool`.
Bundle ID сохранён для обновления уже установленного приложения.
Имена внутренних Swift-модулей и записи о происхождении Android-ресурсов сохранены.
