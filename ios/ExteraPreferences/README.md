# ExteraPreferences

Модуль хранения настроек GlowGram на основе портированных настроек exteraGram Lite. Сам модуль не является клиентом Telegram.

`ExteraSettings.swift` содержит 125 скалярных определений. `ExteraEnums.swift` дополняет их девятью enum-параметрами с исходными ordinal, двумя параметрами двойного нажатия с sanitizer и значением `useGoogleCrashlytics` конкретной release-сборки. Вместе представлены все 137 preference delegates главного конфига. Происхождение каждого значения записано в `provenance.json`. Наличие определения настройки не включает соответствующий функционал.

`cameraType(androidDevicePerformanceClass:)` требует явного выбора политики, поскольку исходное условие зависит от классификации Android-устройства (`2` → CameraX, иначе Camera1). Эти enum сохраняют идентичности Android-конфига и не обозначают доступные камеры iOS. Интеграция должна отдельно сопоставить их с AVCapture. Исходный `BuildVars.DEBUG_VERSION` в данном APK равен `false`, поэтому `useGoogleCrashlytics` по умолчанию также `false`; SDK телеметрии не подключён.

Воспроизведены load-once cache, `invalidate`, `invalidateAll` и пропуск повторной записи уже загруженного значения. Как в APK BasePref, sanitizer применяется при чтении сохранённого значения и при записи, а свежее присвоение остаётся в кеше в первоначальном виде до инвалидирования. Для двух DoubleTap-параметров диапазон сохраняемого значения — `0...9`. `ExteraDoubleTap` также сохраняет различие действий для собственного и чужого сообщения.

Хранилище использует JSON-данные в UserDefaults с отдельным префиксом. Android backup и миграция SharedPreferences ещё не реализованы. Служебные параметры плагинов сохранены в схеме потому, что они присутствуют в APK; движок плагинов Lite отсутствует.

```swift
import ExteraPreferences
let settings = ExteraPreferences(defaults: .standard)
let enabled = settings.value(for: ExteraSettings.inAppVibration)
try settings.set(false, for: ExteraSettings.inAppVibration)
```

Для приложения доступен общий экземпляр `ExteraPreferences.standard`. Изменения и сброс публикуют `Notification.Name.exteraPreferencesDidChange` с `userInfo["key"]` после освобождения блокировки. Модель кеша защищена NSLock; Foundation UserDefaults допускает конкурентное обращение. Поэтому общий экземпляр обозначен `@unchecked Sendable` с явно защищённым изменяемым состоянием.

125 скалярных определений происходят из `recover_defaults.py` и `port_preferences.py` локального исследования. Остальные типы и правила восстановлены отдельно из девяти enum и DoubleTapUtils. Источники родительского анализа не входят в этот Swift Package. Восстановленные defaults требуют проверки при интеграции с потребителями параметров; дополнительные UI-правила getters и внешние конфиги других модулей ещё не перенесены.

Подготовлены XCTest-проверки сохранения, сброса, optional-строк, повреждённых данных, enum ordinal/fallback, sanitizer/cache, действий двойного нажатия и уведомлений. В текущей Windows-среде нет Swift-компилятора; результаты GitHub macOS CI должны проверяться отдельно. В среде macOS выполнить `swift test`, затем проверить интеграцию на iPhone.
