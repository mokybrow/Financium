# Financium agent guide

Этот файл — стартовая точка для любого агента, который анализирует или меняет Financium. Сначала прочитай его целиком, затем открой только относящиеся к задаче файлы и комментарии рядом с изменяемым кодом.

## Быстрый старт

- Проект: нативное SwiftUI-приложение для iOS 26 с виджетом.
- Основной проект Xcode: `Financium.xcodeproj`.
- Основная схема: `Financium`; схема виджета: `FinanciumWidgetsExtension`.
- Внешних Swift Package Manager зависимостей нет. Модели — нативные Swift-структуры с `Codable`.
- В корне репозитория перед работой выполни `git status --short`. Рабочее дерево может содержать изменения пользователя: не откатывай, не перезаписывай и не форматируй несвязанные файлы.
- Для поиска используй `rg` и `rg --files`.
- Делай минимальную правку в существующей архитектуре. Не переписывай экран или сервис целиком без необходимости.

## Карта проекта

- `Financium/FinanciumApp.swift` — composition root и environment objects.
- `Financium/ContentView.swift` — авторизация, начальная загрузка, вкладки, scene lifecycle и deep links.
- `Financium/AppDelegate.swift` — APNs/CloudKit push и принятие `CKShare`.
- `Financium/Views/` — SwiftUI-экраны и редакторы.
- `Financium/Views/DesignSystem/FinanciumDesignSystem.swift` — общие токены и компоненты `FI*`. Сначала ищи подходящий компонент здесь, затем добавляй новый.
- `Financium/Services/FinanceStore.swift` — `@MainActor`-состояние UI и единая точка операций для views.
- `Financium/Services/FinanceBackend.swift` — контракт backend и локальный actor `LocalFinanceBackend`.
- `Financium/Services/FinanceLedger.swift` — расчёты балансов, бюджетов и целей.
- `Financium/Services/CloudKitFinanceBackend.swift` — local-first обёртка: пишет локально и запускает reconcile.
- `Financium/Services/CloudKitSyncCoordinator.swift` — `CKSyncEngine`, зоны, merge, push и sharing.
- `Financium/Services/CloudRecordMapping.swift` — преобразование нативных моделей в `CKRecord` и обратно.
- `Financium/Models/FinanceModels.swift` — удобные расширения нативных моделей и форматирование денег.
- `Financium/Models/Core/` — нативные модели, `FinanceArchive` (локальный JSON v2) и `LegacyFinanceCodec` для совместимости с существующими CloudKit payloads и миграции старых данных. Не меняй номера legacy-полей; неизвестные поля должны сохраняться.
- `Financium/en.lproj/Localizable.strings` и `Financium/ru.lproj/Localizable.strings` — локализации приложения.
- `FinanciumWidgets/` — WidgetKit extension, snapshot и локализации виджета.
- `Financium/Assets.xcassets` и `Financium/*.icon` — previews и исходники Icon Composer.

## Архитектурные инварианты

### Local-first данные

`LocalFinanceBackend` — источник данных, которые видит UI, и приложение должно оставаться рабочим офлайн. В режиме iCloud `CloudKitFinanceBackend` всё равно сначала читает и пишет локальный ledger; `CloudKitSyncCoordinator` лишь зеркалирует изменения и сливает удалённые записи обратно.

Поток изменения:

`View → FinanceStore → FinanceBackend → LocalFinanceBackend → CloudKit reconcile → FinanceStore.refresh()`

- View не должен напрямую обращаться к CloudKit или локальному файлу.
- После мутации обновляй экран через существующие методы `FinanceStore`; учитывай уже выполняющийся `refreshTask`.
- Не очищай UI при переключении local/iCloud: обе конфигурации используют один локальный ledger.
- Не добавляй polling для shared data: изменения приходят через CloudKit push и `CKSyncEngine`; activation refresh служит страховкой.

### Concurrency

У app target включён `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.

- UI stores и SwiftUI state остаются на `@MainActor`.
- Файловое хранилище и CloudKit coordinator — actors.
- Типы и helpers, вызываемые из actor/background-кода, при необходимости объявлены `nonisolated` и `Sendable`.
- Не лечи concurrency-warning бездумным `@unchecked Sendable`; сначала исправь владение состоянием или actor boundary.
- Не выполняй синхронный disk/network work на MainActor.

### Деньги и модели

- Хранимые суммы — `FinanceMoney.minorUnits` (`Int64`, две дробные цифры). На границах UI/backend используй `Decimal`, не `Double`.
- Для показа готовых значений используй `FinanceMoney.formatted` или `abbreviated`.
- Все редактируемые денежные поля должны использовать `FIAmountRow`; он группирует разряды, принимает локальные `.`/`,` и оставляет не более двух дробных цифр.
- Для разбора и начального текста используй `financeDecimal(from:)` и `financeAmountText(_:)`.
- `FinanceBudget` не содержит месяц: локальное хранилище держит `(month, budget)`. Не теряй `monthKey` при merge или миграции. При миграции JSON v1 создаётся `.v1.backup`; повреждённый архив нельзя заменять пустым ledger.
- Built-in категории хранят стабильный английский identifier и локализуются только для UI. Пользовательские категории хранятся как введены.

### CloudKit sharing

- Каждый счёт живёт в своей зоне `acct_<accountID>`; это позволяет расшарить всю зону через `CKShare`.
- Кнопка в toolbar использует нативный `ShareLink` + `CKShareTransferRepresentation`. Не возвращай ручной full-screen sheet, `UIActivityViewController`, prewarming при входе на экран или spinner на кнопке.
- Первый `CKShare` создаётся только после открытия системного collaboration UI; сохранённые shares кешируются для мгновенного повторного открытия.
- Ссылка сама по себе не означает, что счёт общий. Badge с двумя людьми показывается владельцу только когда есть ссылка и принят хотя бы один non-owner participant. Для приглашённого наличие зоны в shared database уже означает участие.
- Пункт «Сделать приватным» определяется наличием активной ссылки, а не видимым shared badge: владелец должен уметь отозвать ещё не принятую ссылку.
- Считай только участников с `acceptanceStatus == .accepted`; owner и pending participants не увеличивают `memberCount`.
- Thumbnail `CKShare` — PNG с прозрачностью и жёстким лимитом размера. Не конвертируй прозрачную app icon в opaque JPEG: углы станут чёрными. Старые Messages bubbles не обновляются задним числом.
- Реальное создание/принятие share нельзя полноценно проверить generic simulator build: для runtime-проверки нужен подписанный build, устройство и два iCloud-аккаунта.

### SwiftUI и дизайн

- Используй системные `NavigationStack`, toolbar, `ShareLink`, context menu, sheets, alerts, pickers и input methods.
- Переиспользуй `FITheme`, `FICard`, `FIListRow`, `FIAmountRow`, `FIToolbarAddButton` и другие `FI*`-компоненты.
- Не хардкодь цвета, размеры карточек и повторяющиеся row layouts в отдельных экранах, если для этого уже есть token/component.
- Сохраняй Dynamic Type, VoiceOver labels, keyboard type, focus, paste и системную семантику destructive/cancel actions.
- Пользовательские строки должны быть ключами локализации. Добавляй одновременно английский и русский варианты; для widget UI — также в обе локализации `FinanciumWidgets`.
- Существующие подробные комментарии фиксируют причины нетривиальных решений. При изменении поведения обнови комментарий, а не оставляй устаревшее объяснение.

## Как вносить изменения

1. Найди текущий путь данных/события от view до storage или обратно.
2. Проверь соседние реализации и общий design-system component.
3. Сформулируй минимальную первопричину перед правкой.
4. Измени только необходимые файлы; не затрагивай `project.pbxproj`, если новый файл автоматически попадает в synchronized group.
5. Для новой пользовательской строки обнови `en` и `ru`.
6. Для изменения модели проверь local persistence, CloudKit mapping, merge, widget snapshot и backward compatibility.
7. Для изменения sharing проверь отдельно: private owner, link without participant, owner with accepted participant, invited participant, make private и leave share.

## Проверка

Из корня репозитория:

```sh
git diff --check
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -quiet -project Financium.xcodeproj -scheme Financium -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Сборка основной схемы также компилирует embedded widget extension. При изолированной работе над виджетом можно дополнительно собрать схему `FinanciumWidgetsExtension` той же командой.

Сейчас отдельного XCTest target нет. Совместимость моделей и миграцию хранилища проверяй через `sh Scripts/check-finance-storage.sh` (67 эталонных записей старого формата и проверки JSON/backup). Обязательно выполняй build и описывай конкретную ручную проверку. Не заявляй, что CloudKit, APNs, Sign in with Apple, alternate icons или notifications проверены runtime, если был только simulator compile.

## Перед завершением

- `git diff --check` чист.
- Основная схема собирается.
- Нет случайных изменений пользователя или generated files.
- Локализации синхронны.
- Ошибки не замалчиваются и cancellation не показывается пользователю как failure.
- В итоговом сообщении перечислены изменённые области, проведённые проверки и всё, что требует проверки на реальном устройстве.

Системные логи вида `CFPrefsPlistSource` для Apple-owned domains и временные `UIHostedScene` warnings сами по себе не являются причиной добавлять private entitlements или обходить sandbox. Исправляй их только при доказанном пользовательском симптоме и связи с кодом приложения.
