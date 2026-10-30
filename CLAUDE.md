# Atoll — кастомный форк

Личный форк [Ebullioscopic/Atoll](https://github.com/Ebullioscopic/Atoll) (Dynamic Island для MacBook, SwiftUI, GPLv3).
Ставится вместо официального приложения в `/Applications/Atoll.app` с тем же bundle id `com.Ebullioscopic.Atoll`,
поэтому настройки и история буфера общие с официальной версией.

## Ветки и upstream

- `upstream` — оригинальный репозиторий, его основная ветка `dev` (релизы режутся из неё).
- `custom/clipboard-tab` — наши изменения поверх `upstream/dev`.
- Подтянуть обновления: `git fetch upstream && git rebase upstream/dev`. Конфликты чаще всего в
  `DynamicIsland/models/Constants.swift`, `NotchClipboardView.swift` и `DynamicIsland/Localizable.xcstrings`.
- После обновления из upstream заново проверь, что не появилось новых сетевых адресов и SDK аналитики:
  `grep -rhoE 'https?://[A-Za-z0-9._-]+' DynamicIsland --include='*.swift' | sort -u`.

## Сборка и установка

```bash
scripts/build-custom.sh            # Release-сборка + проверка подписи
scripts/build-custom.sh --install  # + бэкап установленного в build/backup/, замена и перезапуск
```

- Нужен Xcode с Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`), иначе падает `visualizer.metal`.
- Подпись — локальный Apple Development сертификат из `scripts/custom-build.local.env` (в .gitignore):
  `ATOLL_SIGN_IDENTITY` (SHA-1) и `ATOLL_TEAM_ID`. Стабильная подпись сохраняет разрешения macOS
  (Универсальный доступ, Запись экрана) между пересборками; ad-hoc подпись их сбрасывает.
- Быстрая проверка компиляции без подписи:
  `xcodebuild build -project DynamicIsland.xcodeproj -scheme DynamicIsland -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO`
- Ставить сборку в `/Applications` только с явного согласия пользователя.
- Осторожно с Debug-сборкой и тестами: Debug (`com.Ebullioscopic.Atoll.dev`) делит с релизом папку
  `~/Documents/ClipboardData`, а `ClipboardManager` при старте удаляет из неё картинки, которых нет в
  его истории — запуск Debug-приложения стирает картинки буфера установленного Atoll. Тесты запускают
  Debug-приложение как хост; не гонять их на машине пользователя без его согласия.
- Откат на официальную версию: `ditto build/backup/<бэкап>.app /Applications/Atoll.app` или DMG из релизов upstream.

## Где что лежит

- `DynamicIsland/DynamicIslandApp.swift` — AppDelegate: запуск, горячие клавиши, миграции настроек, Sparkle.
- `DynamicIsland/ContentView.swift` — раскладка выреза, высота открытого выреза по вкладке, `switch coordinator.currentView`.
- `DynamicIsland/DynamicIslandViewCoordinator.swift` — текущая вкладка (`currentView`), направление анимации
  переключения (по порядку бара), sneak peek под закрытым вырезом (`toggleSneakPeek`, `SneakContentType`).
- `DynamicIsland/components/Tabs/NotchTabCatalog.swift` — единый источник вкладок: `NotchTabKind` (стабильные ключи),
  какие включены по функциям, порядок и убранные (`notchTabOrder`, `hiddenNotchTabs`). Его используют бар,
  `enabledStandardTabCount()` (минимальная ширина выреза) и настройки — новую вкладку добавлять только сюда.
- `DynamicIsland/sizing/matters.swift` — `recommendedMinimumNotchWidth`: шапка делит открытый вырез на равные половины
  вокруг проёма под камеру, бар вкладок — в левой. Минимум ширины учитывает ширину бара (иконка ~20 pt + 24 pt
  промежутка), иначе лишние вкладки уезжают под камеру.
- `DynamicIsland/components/Tabs/TabSelectionView.swift` — бар: тап выбирает, удержание 0.3 с поднимает вкладку,
  ведение вбок переставляет, вниз на 48 pt (с сопротивлением) — убирает (Главная не убирается); в контекстном меню — «Вернуть убранные вкладки».
- `DynamicIsland/models/Constants.swift` — все ключи `Defaults` и одноразовые миграции (`migrate…`).
- `DynamicIsland/enums/generic.swift` — `NotchViews` (список вкладок выреза).
- Проект использует синхронизируемые папки Xcode: новые файлы в `DynamicIsland/` попадают в таргет сами.

### Буфер обмена

- `managers/ClipboardManager.swift` — опрос `NSPasteboard.changeCount` раз в 0.5 с, история и избранное
  в UserDefaults (`ClipboardHistory`, `ClipboardPinnedItems`), картинки — PNG в `~/Documents/ClipboardData`.
  Дубликаты картинок сравниваются по `contentHash` (SHA-256 при захвате), а не чтением файлов с диска.
- `components/Notch/NotchClipboardView.swift` — вкладка буфера в вырезе: фильтры, поиск, лента карточек.
- `components/Clipboard/ClipboardThumbnailLoader.swift` — превью: ImageIO-даунсемплинг и QuickLook вне
  главного потока, кэш `NSCache` по id элемента.
- `components/Clipboard/ClipboardDragging.swift` — перетаскивание карточек в другие приложения.
- `ClipboardPanel` / `ClipboardPopover` / `ClipboardWindow` — старые оконные режимы, остаются выбираемыми в настройках.

### Claude Code

- `managers/ClaudeCode/ClaudeCodeSession.swift` — модель сессии и чтение хвоста транскрипта
  `~/.claude/projects/<проект>/<uuid>.jsonl` (записи `custom-title`, `last-prompt`, `cost-state`, поле `cwd`;
  `entrypoint == "claude-desktop"` — сессия приложения). Формат внутренний, может меняться между версиями.
- `managers/ClaudeCode/ClaudeCodeSessionMonitor.swift` — FSEvents на папку проектов и папку событий, обновление
  не чаще раза в секунду, кэш снимков по дате/размеру файла; статус из хуков, без хуков — по свежести файла;
  sneak peek при «ждёт разрешения» и «готово». Открытие: приложение Claude или `.command`-файл с `claude --resume`.
- `managers/ClaudeCode/ClaudeCodeHooks.swift` — подключение хуков в `~/.claude/settings.json` (слияние с
  чужими хуками, бэкап `settings.json.atoll-backup`, отказ при битом JSON) и скрипт `atoll-hook.sh`, который
  пишет в `~/Library/Application Support/Atoll/ClaudeCode/events` только имя события, id сессии и текст
  уведомления. Хуки Claude Code читает при старте сессии — открытые сессии подхватят их после перезапуска.
- `components/Notch/NotchClaudeView.swift` — вкладка; `components/Settings/ClaudeCodeSettings.swift`,
  `NotchTabsSettings.swift` — разделы настроек.

### Скриншоты и медиа

- `managers/ScreenshotsMonitor.swift` — снимки и записи экрана по атрибуту `kMDItemIsScreenCapture` в папке
  сохранения (`com.apple.screencapture` → `location`, при отсутствии папки macOS пишет на Рабочий стол) и на
  Рабочем столе; FSEvents, до 60 штук. Смена папки пишет тот же ключ, что Screenshot.app. Монитор стартует при
  первом открытии вкладки — тогда же macOS спрашивает доступ к папкам.
- `components/Notch/NotchScreenshotsView.swift` — вкладка: клик копирует, перетаскивание отдаёт файл,
  меню папки сохранения. Превью — через `ClipboardThumbnailLoader.preview(forFileAt:)`.
- `helpers/BrowserMediaTab.swift` — клик по обложке переключает на вкладку браузера, где играет трек (AppleScript).
- `MediaControllers/NowPlayingController.swift` — помощник `mediaremote-adapter.pl` перезапускается при падении
  (2→30 с) и гасится при выходе из Atoll.
- `MusicManager.showsActiveSession` — `hasActiveSession` с задержкой скрытия 2.5 с, чтобы плеер не мигал
  календарём при смене трека.

## Отличия форка от upstream

1. Буфер обмена — вкладка в верхнем баре выреза (режим `.notchTab`, он же новый default; одноразовая
   миграция `migrateClipboardToNotchTab` переводит с окна/поповера). Кнопка буфера в шапке в этом режиме скрыта.
2. Вкладка: фильтры Все/Текст/Ссылки/Фото/Файлы/Избранное со счётчиками, поиск, карточки по типу контента
   (фото — настоящие миниатюры, ссылки — домен и путь, файлы — превью QuickLook), избранное и удаление по наведению.
3. Мониторинг буфера стартует при запуске приложения, а не при первом открытии выреза.
4. Вырез открывается на последней вкладке («Remember last tab» включён по умолчанию и важнее
   «открывать полку»), а фильтр, поиск и позиция прокрутки вкладки буфера живут в `ClipboardTabState`
   и переживают закрытие выреза. Новая копия, сделанная при закрытом вырезе, сбрасывает прокрутку к началу.
5. История по умолчанию 25 элементов (варианты до 50).
6. Производительность: превью не декодируются в главном потоке; тип содержимого буфера проверяется по
   `pasteboard.types`, без чтения данных; дубли картинок — по хэшу.
7. Sparkle выключен (`AtollCustomBuild` в Info.plist → `AppRuntimeEnvironment.isCustomBuild`): иначе
   автообновление заменит сборку официальной.
8. Исправлены русские переводы: «All» был «Выравнивание», «Done» — «Поддержать», плейсхолдер поиска был
   «Строк обратной прокрутки».
9. Вкладки бара переставляются удержанием и перетаскиванием, убираются утягиванием вниз; управление и возврат —
   Настройки → Вкладки.
10. Вкладка Claude Code: сессии за 7 дней из терминала и приложения, живой статус через хуки (подключаются кнопкой
    во вкладке или в настройках), уведомления под закрытым вырезом, открытие/продолжение сессии по клику.

11. Вкладка «Скриншоты» с выбором папки сохранения; переход на вкладку браузера по обложке; помощник
    Now Playing перезапускается; плеер не мигает при смене трека.
## Правила

- В новых файлах — GPL-заголовок как в соседних файлах.
- Новые ключи настроек — только в `Constants.swift`; смена поведения у существующих установок — через миграцию с флагом.
- Строки интерфейса — английский ключ в коде, перевод в `DynamicIsland/Localizable.xcstrings` (минимум `ru`).
  Корневой `Localizable.xcstrings` в таргет не входит. Править каталог, сохраняя формат Xcode
  (`json.dumps(indent=2, ensure_ascii=False, separators=(",", " : "))` без перевода строки в конце).
- В `body` не декодировать картинки и не читать файлы — только через `ClipboardThumbnailLoader` или `.task`.
- Пользовательский текст выводить через `Text(String)` (verbatim), не через строковые литералы с интерполяцией.
- Не включать Sparkle и не добавлять сетевые запросы без явной просьбы.
- Хук-скрипт Claude Code обязан всегда завершаться с кодом 0, не блокировать сессию и не сохранять запросы,
  ввод/вывод инструментов. Установщик хуков проверять на копии с подменённым домашним каталогом
  (`homeDirectoryForCurrentUser` не смотрит на `$HOME`), а не на реальном `~/.claude/settings.json`.
