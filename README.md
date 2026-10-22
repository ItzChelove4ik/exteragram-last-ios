# exteraGram Lite iOS port

Экспериментальный порт exteraGram Lite на настоящий клиент Telegram iOS.
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
Используются публичные API-параметры из исходников Telegram; свои можно указать через
GitHub Secrets `TELEGRAM_API_ID` и `TELEGRAM_API_HASH`.
Сертификаты Apple и provisioning profiles для сборки не требуются.

## Локальная сборка на Mac

```sh
python3 scripts/prepare_upstream.py
python3 scripts/build_ipa.py --build-number 1
```

На Windows можно работать с исходниками и запускать сборку в GitHub Actions.
Основной Telegram-код и зависимости загружаются из закреплённых upstream-репозиториев;
они не дублируются в этом репозитории. Условия лицензирования этих компонентов находятся
в их исходных репозиториях. Происхождение портированных данных описано в `provenance.json`
и `ios/ExteraExport/Provenance/evidence.json`.
