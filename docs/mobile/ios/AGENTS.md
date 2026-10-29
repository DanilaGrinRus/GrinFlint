# AGENTS.md — GrinFlint (iOS-кошелёк Grin)

Рабочий корень: **`C:\DHW\mobile\GrinFlint`** (git-репозиторий, ветка `main`,
origin `github.com/DanilaGrinRus/GrinFlint`, **публичный**). Проект также
называют «IosFlint» — это одно и то же; при переименовании папки ничего
не ломается (все пути внутри репозитория относительные).

Дата актуализации: 2026-10-28.

## Что за проект

Некастодиальный кошелёк Grin (Mimblewimble) для iOS (SwiftUI, iOS 17+, MVVM).
Дизайн и UX — по мотивам Flint Wallet; визуальная тема синхронизирована
с десктопным Flint (мятный акцент `#6ee7b7` на графитово-синем, токены
скопированы из `crates/slint-ui/ui/theme.slint` десктопного проекта).

Блокчейн-слой — официальный grin-wallet v5.5.1 (Rust), подключённый через
C-API (FFI) и собранный в XCFramework. Репозиторий публичный — **секретов
в коде нет, только в GitHub Secrets**.

## Железные правила

1. **Seed, пароли, API-секреты не попадают в код, коммиты, логи и сообщения
   об ошибках.** В репозитории-публичном это критично. Единственный
   допустимый канал — GitHub Secrets (см. «Тестовые активы»).
2. **Старый testnet-seed** (файл `C:\DHW\docs\testnet-funded.txt`,
   используется в другом проекте пользователя) — **не использовать и не
   копировать никуда**. С него списано 50 tGRIN на CI-кошелёк, дальше он
   чужой. Формат файла: фраза лежит в 6-й строке с префиксом `seed=`.
3. **Локального Xcode/симулятора нет.** Сборка и проверка — только через
   GitHub Actions (macos-15). Любое изменение Swift обязано пройти
   workflow «iOS Build» до того, как считаться готовым.
4. Не трогать чужие каталоги в `C:\DHW` (это корень десктопного проекта
   Flint: `crates/`, `vendor/`, `.node/`, `target/` и т.д. — читать можно
   только `docs/`, `tools/` по необходимости и один файл
   `crates/slint-ui/ui/theme.slint`).
5. `C:\DHW\AGENTS.md` — правила чужого проекта; нашему репозиторию они не
   мешают, но их каталоги не редактировать.
6. Язык: код и комментарии — как принято в файле; документация и
   UI-тексты — русский, тон фактический, без обещаний
   («проверено тестом» ≠ «работает»).

## Ловушки окружения (проверено болью)

- **Cargo конфликтует с родительским workspace.** `C:\DHW\Cargo.toml`
  (Flint) + `C:\DHW\.cargo\config.toml` (vendor + offline) ломают сборку
  нашего крейта, если запускать cargo из-под дерева `C:\DHW`.
  Решение: запускать cargo с CWD **вне** `C:\DHW`, например
  `cd %TEMP% && cargo test --manifest-path C:\DHW\mobile\GrinFlint\ffi\grin-wallet-ffi\Cargo.toml ...`.
  Крейт уже отсоединён пустой таблицей `[workspace]` в своём Cargo.toml.
- **MSVC требует короткий TMP.** Перед cargo build локально:
  `TMP=C:\DHW\.tmp TEMP=C:\DHW\.tmp` (иначе cc-rs падает на zstd-sys
  с exit code 2 — TMP по умолчанию на OneDrive с длинным путём).
- **grin-wallet CLI нескриптуем** на Windows: фразу читает только с
  консоли, пайпы не принимает. Все операции с кошельком — через наш FFI
  (тесты) или grin-wallet на Linux/macOS.
- **API тестнет-ноды — порт 13413, НЕ 3413** (3413 — mainnet). Из-за этой
  путаницы CI сутками опрашивал пустоту. Owner и foreign API живут на
  одном порту.
- **`.foreign_api_secret` должен совпадать с `.api_secret`** — кошелёк
  ходит на foreign API (restore/refresh/push tx) с owner-секретом; при
  расхождении нода отвечает 401, а кошелёк молча возвращает пустой
  баланс. Локальная нода пользователя работает, потому что её
  `.foreign_api_secret` пуст (foreign API без auth). Workflow уравнивает
  секреты при старте ноды.
- **Релизы-снапшоты не должны быть draft**: убитый таймаутом `gh release
  create` оставляет черновик, а `gh release view` с GITHUB_TOKEN в CI
  видит его как «release not found». Проверять `--json draft` после заливки.
- `gh` = `C:\DHW\tools\gh.exe` (не в PATH git-bash).
- Git Bash: пути `/c/...` → Windows `C:\...` через `pwd -W`.
- **Сумма перевода обязана быть меньше баланса**: комиссия платится сверху,
  и при `amount` = весь баланс `send` падает
  `Insufficient funds. Required: 50.012500000, Available: 50.000000000`
  (проверено на run 40581454614). В тесте сумма задаётся
  `GRIN_E2E_AMOUNT_NGRIN`, дефолт 1 tGRIN, в проверке учтён запас
  `FEE_HEADROOM` = 0.0125 tGRIN.
- **`git status` показывает все файлы `GrinFlintApp/` удалёнными** — это не
  удаление, а отключённое наследование прав Windows у каталога: песочница не
  может его прочитать, `git` считает файлы пропавшими (повтор случая
  2026-10-28 05:08). Лечение — вернуть наследование от родителя:
  `icacls GrinFlintApp /inheritance:e /t /c` (нужен токен владельца; из
  песочницы DSH не выйдет). Резервные копии SDDL и скрипт отката лежат в
  `C:\DHW\_acl-recovery\` (файлы `acl-backup-*.json` и каталоги
  `grinflintapp-<дата>\` с `rollback.ps1`). **Пока дерево в таком состоянии
  ничего не коммитить**: `git add -A` запишет удаление всего приложения.
- **Локальная нода догоняет сеть с задержкой в блок-два.** Замер баланса
  сразу после E2E может показать меньше реального: после прогона 40597688610
  первый скан дал 47.9055 вместо 48.8805 — блока с возвратом на ноде ещё не
  было. Лечение: дождаться роста `height` (`get_status`) и повторить скан
  (полный — ~6 мин). Вывод: баланс после прогона проверять не раньше чем
  через пару блоков.
- **Симулятор в CI англоязычный.** После включения локализации
  (`Localizable.xcstrings`) интерфейс в симуляторе стал английским, и
  XCUITest, ищущие русские строки, упали на «портфель не открылся» (run
  40704453668). Решение: тесты и скриншоты запускаются с
  `-AppleLanguages (ru) -AppleLocale ru_RU`, английский проверяется
  отдельным тестом `testEnglishLocalization`.

## Структура репозитория

| Путь | Содержимое |
|---|---|
| `GrinFlintApp/GrinFlint.xcodeproj` | Xcode-проект; синхронизированные группы — **новые .swift подхватываются автоматически**, pbxproj не править |
| `GrinFlintApp/GrinFlint/Theme.swift` | Все цвета/радиусы/шрифты (токены Flint) |
| `GrinFlintApp/GrinFlint/SimSmoke.swift` | Самопроверка для CI: запуск с `-SimSmoke` прогоняет Keychain → FFI → seed → open → refresh → восстановление, пишет `Documents/sim-smoke.json`. Кадры для CI: `-simDemo` (демо-данные) и `-simOpen <экран>` |
| `GrinFlintApp/GrinFlintUITests/` | XCUITest навигации (`NavigationUITests`): вкладки, отправка, приём; запускается в CI |
| `GrinFlintApp/Info.plist` | Info.plist приложения: `CFBundleURLTypes` со схемой `grinslate`, `CFBundleLocalizations` ru/en, launch screen, ориентации |
| `GrinFlintApp/ShareExtensionInfo.plist` | Info.plist Share Extension: `NSExtensionPointIdentifier = com.apple.share-services`, активация по тексту и web URL |
| `GrinFlintApp/GrinFlintShare/` | Share Extension (`ShareViewController`): открывает `grinslate://` из системного «Поделиться» |
| `GrinFlintApp/GrinFlint/Localizable.xcstrings` | Каталог строк: sourceLanguage `ru`, английские переводы |
| `GrinFlintApp/SimulatorEntitlements.plist` | Entitlements для ad-hoc подписи симуляторной сборки (без подписи Keychain даёт `-34018`) |
| `GrinFlintApp/GrinFlint/Views/` | Экраны: Portfolio, SendFlow, Receive, Transactions, Settings, Onboarding, LockScreen, StartupError |
| `GrinFlintApp/GrinFlint/Services/` | `WalletService` (протокол) + `UnavailableWalletService`, `MockWalletService` (демо), `WalletFactory`, `KeychainStore`, `BiometricAuth`, `SlatepackCodec`, `TxReminders` (локальные напоминания), `AddressBook` (контакты), `QRCode`, `FFI/GrinWalletFFIService` (под флагом `GRINFFI`) |
| `GrinFlintApp/GrinFlint/ViewModels/` | `AppState`, `WalletViewModel`, `AppLockManager` |
| `ffi/grin-wallet-ffi/` | Rust-крейт: C-API над grin-wallet 5.5.1 (`staticlib` + `rlib`), заголовок `ffi/include/grin_wallet_ffi.h`, тесты |
| `ffi/grin-wallet-ffi/tests/roundtrip.rs` | Смоук-тест lifecycle (оффлайн, macOS-раннер) |
| `ffi/grin-wallet-ffi/tests/e2e_floonet.rs` | Полный roundtrip tGRIN против живой ноды (env-gated) |
| `ffi/patches/` + `ffi/grin-wallet-ffi/.github`-патч-шаг | Патчи sysinfo и grin_wallet_impls для iOS-кросс-компиляции |
| `.github/workflows/ios.yml` | Сборка: cargo check → XCFramework (rust-ios) → приложение → смоук |
| `.github/workflows/floonet-e2e.yml` | E2E: своя floonet-нода в раннере + roundtrip tGRIN (в CI 1 tGRIN, `GRIN_E2E_AMOUNT_NGRIN`; dispatch + cron пн 04:17 UTC); цепь — только restore, сохраняет «прогрев» |
| `.github/workflows/floonet-chain-cache.yml` | Прогрев кеша цепи: синк ноды до 280 мин + save частичного прогресса всегда (`if: always()`); воскресенье 20:27 UTC + вручную |
| `docs/mobile/ios/` | README, architecture, grin-wallet-integration, roadmap, AGENTS.md (этот файл) |
| `ffi/include/grin_wallet_ffi.h` | C-заголовок для Swift (bridging header уже настроен) |

## C-API FFI (ffi/grin-wallet-ffi/src/lib.rs)

`grin_wallet_create(data_dir, node_url, chain, api_secret)` → handle.
`chain`: `"mainnet"` | `"floonet"` (внутри мапится на Testnet).
`api_secret`: NULL ок; для ноды с Basic Auth — секрет.

Далее: `grin_wallet_create_seed(h, pass, слова, фраза|NULL)`
(снаружи — число СЛОВ: 12/15/18/21/24, внутри — байты энтропии),
`grin_wallet_open` → `{"address"}`, `grin_wallet_balance(h, refresh)`
(refresh=1 — опрос ноды), `grin_wallet_txs`,
`grin_wallet_send(h, amount, dest)` → `{"slatepack","slate_id","fee"}`,
`grin_wallet_receive` → `{"slatepack"}`, `grin_wallet_finalize` (включает
post в ноду), `grin_wallet_cancel`. Ошибки: NULL / -1 + `grin_last_error()`.
Строки возвращённые — освобождать `grin_string_free`.

Известные ограничения FFI:
- **Текста сообщения в slatepack нет.** В grin-wallet 5.5.1 поле сообщения
  отсутствует в API: в `ParticipantData` только ключи и подпись, у
  `create_slatepack_message` нет параметра сообщения (проверено по исходникам
  крейта 5.5.1). Прежний параметр `message` у `grin_wallet_send` молча
  терялся — удалён 2026-10-28 вместе с полем в UI. Текст можно вернуть
  только отдельным каналом передачи (Фаза 5: Grinbox/Nostr).
- При `grin_wallet_create` пишется дефолтный `grin-wallet.toml` в data_dir
  (init_send_tx требует файл конфига).
- Без открытого кошелька (open) вызовы падают — сначала open.

## Состояние дел (что правда работает)

- FFI собирается для iOS (device+sim), Swift-обёртка компилируется в CI
  под флагом `GRINFFI`. Смоук-тест lifecycle зелёный.
- **Полный roundtrip tGRIN проверен вживую** (2026-10-27): нашим FFI через
  локальную ноду 5.5.2 отправлено 50 tGRIN между двумя реальными
  кошельками, подтверждено в цепи (~4,5 мин). Код — `e2e_floonet.rs`.
- Face ID/Touch ID на вход и на подпись + автоблокировка — код написан,
  сборка зелёная, **на устройстве не проверялось** (нет симулятора).
- Восстановление из фразы проверено тестами: 24 слова
  (`wallet_lifecycle_offline`) и 12 слов (`restore_from_12_words`) дают тот
  же slatepack-адрес. Локально на Windows: `cargo test --test roundtrip` —
  **3 passed** (2026-10-28).
- **Навигация по экранам проверена XCUITest** (2026-10-28, run 40686799752):
  `testPortfolioAndTabs` и `testSendAndReceiveScreens`, 0 падений.
- **Приложение реально запускается на симуляторе в CI** (2026-10-28, run
  40607181039): шаг «Смоук на симуляторе» ставит app, запускает с `-SimSmoke`
  и требует `ok: true`. Отчёт: `backend: grin-wallet 5.5.1 (FFI)`,
  `demo: false`, `keychain_password: true`, `mnemonic_words: 24`,
  `restore_address_matches: true`, `elapsed_ms: 437`. Навигация по экранам
  и сеть до ноды смоуком не проверяются (на раннере ноды нет).
- UI подключён к живому FFI (сборка с `GRINFFI`): `WalletFactory` отдаёт
  `GrinWalletFFIService`, у отправки появился шаг завершения ответным
  Slatepack, приём показывает ответный Slatepack, настройки честно
  показывают бэкенд. **На устройстве/симуляторе не проверялось** — только
  компиляция в CI (run 40588800281, зелёный). Демо-режим остаётся для
  сборок без `GRINFFI`.

## Тестовые активы

- **CI-кошелёк**: секрет `TEST_WALLET_SEED` (24 слова BIP39), на нём
  **48.735 tGRIN** (floonet, после прогонов 40593127479, 40597688610,
  40609214248, 40619696017 и 40747893309 с возвратом B→A; до них было 48.977). E2E-тест
  восстанавливает его и шлёт с него. **Комиссия платится сверху**, поэтому
  сумма перевода обязана быть меньше баланса: в CI это 1 tGRIN
  (`GRIN_E2E_AMOUNT_NGRIN`). С ногой возврата (`GRIN_E2E_RETURN_TO_A=1`,
  включена в workflow) прогон стоит ~0.05 tGRIN (измерено 0.0485: две
  комиссии ~0.023 + 0.025 не возвращается — остаётся на B сдачей и уходит
  в комиссию возврата); без возврата — сумму + ~0.02 tGRIN. Полные
  реквизиты (seed + пароль `e2e-test-password`):
  `C:\DHW\docs\grinflint-ci-wallet.txt` — доверять ему; рабочая копия
  `C:\DHW\.tmp\grinsend\ci-seed.txt` могла устареть.
- Проверка баланса кошелька против живой ноды: тест
  `ffi/grin-wallet-ffi/tests/check_funded_balance.rs` (env-gated:
  `GRIN_E2E_SEED_FUNDED`, `GRIN_E2E_NODE_URL`, `GRIN_E2E_API_SECRET`;
  образец `C:\DHW\.tmp\check-balance.ps1`). Первое обновление сканирует
  UTXO ~5-7 минут — это норма, а не зависание.
- **Копия данных CI-кошелька** (снята и обновлена 2026-10-28 сканом с живой
  ноды, после прогона 40597688610):
  `C:\DHW\mobile\grinflint-backups\2026-10-28\funded-wallet-a-data\`
  (`wallet_data` + `grin-wallet.toml`, пароль кошелька `pw` — так задаёт
  тест), рядом README, seed-документ (canonical и рабочая копия) и лог
  скана. Запасное состояние (история, выходы), а не источник истины: из
  seed-фразы кошелёк восстанавливается с нуля.
- Локальная testnet-нода Flint (другого проекта): API
  `http://127.0.0.1:13413` (не дефолтный 3413!), секрет
  `C:\DHW\.node\testnet\node\.api_secret`. Её можно использовать для
  локальных прогонов E2E.
- Публичный эндпоинт (mainnet): `https://grinnode.live:3413` — дефолт
  `WalletFactory.defaultNodeURL`.

## Как работать (типовые задачи)

- **Swift-изменение**: правка → commit → push → ждать «iOS Build»
  (≈20 мин; cargo check ~1 мин, XCFramework ~15 мин, приложение ~1 мин).
- **FFI-изменение**: то же + смоук-тест в CI. Локально: cargo из %TEMP%
  (см. «Ловушки»), `cargo test --test roundtrip`.
- **Проверка на симуляторе**: шаг «Смоук на симуляторе» в `ios.yml`
  (аргумент `-SimSmoke`, результат — `Documents/sim-smoke.json` в контейнере
  приложения). Локально без Xcode не запустить, только CI.
- **Скриншоты экранов**: тот же шаг после смоука снимает 8 кадров
  (`simctl io screenshot`) — артефакт `sim-screenshots` (14 дней). Управление:
  `-walletExists YES` (основной UI), `-simDemo` (демо-данные),
  `-simOpen send|receive|transactions|settings` (сразу экран). Локальная копия
  кадров: `C:\DHW\mobile\grinflint-backups\screenshots-*`.
- **UI-тесты**: шаг «UI-тесты на симуляторе (XCUITest)» в `ios.yml`
  (`xcodebuild test` с FFI-флагами, таргет `GrinFlintUITests`); результат —
  артефакт `uitest-results` (7 дней).
- **Запустить E2E в CI**: `gh workflow run floonet-e2e.yml` (dispatch) или
  ждать cron (пн 04:17 UTC). Первичный синк ноды с нуля — долго (было >100
  мин), поэтому цепь кеширует отдельный workflow `floonet-chain-cache.yml`
  (вс 20:27 UTC + вручную; save даже частичного прогресса, ключ
  `testnet-chain-<год-W<номер>`; повторный запуск продолжает с частичного
  кеша). Снапшот цепи (~5,8 ГБ, высота ~3 310 000 на 2026-10-27) лежит
  release-ассетами `floonet-chain-part-aa/ab/ac` в релизе
  `floonet-chain-2026-10-27` — `floonet-chain-cache.yml` скачивает и
  распаковывает его в `~/.grin/test` перед догоняющим синком. С тёплым
  кешем E2E доезжает за минуты.
- **Локальный прогон E2E**: скрипт-образец `C:\DHW\.tmp\grinsend\run-e2e.ps1`
  (env-переменные, seed из файла, cargo из %TEMP%).

## Превью интерфейса

Веб-рендер всех экранов по SwiftUI-коду (статика, python):
`C:\Users\nurli\OneDrive\Dokumen\kimi\tasks\2026-10-27\04-19-45-ffca3ee9\grinflint-ui-preview`
— `python serve.py --port 7100`. Тема — актуальная (мята/графит).

## Документация

- `docs/mobile/ios/roadmap.md` — фазы, критерии выхода, статусы (источник
  правды по плану).
- `docs/mobile/ios/security-audit.md` — что проверено по секретам/логам,
  найденные дефекты и остаточные риски.
- `docs/mobile/ios/architecture.md`, `docs/mobile/ios/grin-wallet-integration.md`,
  `docs/mobile/ios/README.md`.

## Ближайшие открытые пункты

### Продолжение с 2026-10-29 (07:35 локаль = 00:35 UTC 29.10)

**Безопасная отмена проверена на живой ноде (Windows, без Mac/CI).**
`tests/cancel_pending.rs` (env-gated: `GRINFFI_CANCEL_WALLET_DIR`,
`GRINFFI_CANCEL_WALLET_PASS`, `GRIN_E2E_NODE_URL`, `GRIN_E2E_API_SECRET`)
на копии funded-кошелька:
`spendable до: 97518500000` → `send(0.001 tGRIN, fee=24500000)` →
`после send: spendable=0, locked=97518500000` → `cancel` = 0 →
`после cancel: spendable=48735000000, locked=0`, в `txs` статус canceled.
Тест PASS: отмена возвращает средства и снимает блокировку.

**Найденное расхождение (важно).** Эта же копия БД при `refresh=1` до
отправки показывала 97.5 tGRIN, а после отмены и обновления — 48.735.
Значит копия содержит устаревшие/лишние выходы, и `refresh` не заменяет
локальную БД целиком. Для доказательства баланса использовать чистый
каталог + восстановление из seed (проверено: 48.735 tGRIN), а не копию
БД. Это же — аргумент за состояние «баланс устарел/неизвестен» в UI.
### Продолжение с 2026-10-29 (07:20 локаль = 00:20 UTC 29.10)

**Device Release archive собирается в CI (без подписи).** Новое задание
`device-archive` в `ios.yml`: `xcodebuild archive` для
`generic/platform=iOS`, конфигурация Release, настоящий FFI, Share
Extension. Проверки внутри задания: `.appex` в `PlugIns`, бинарник arm64,
BUILD-INFO (commit, run, Xcode), SHA-256 архива. Артефакт `device-archive`
(30 дней) — 11.6 MB, sha256 `ff9a9443c3a2b2b6f57ac60bc40e6b1736a97a26ce4cc71c143e524c23217fd3`,
BUILD-INFO: commit `b01b13e…`, run 40791161077, Xcode 16.4 (16F6).
Подпись Personal Team и установка — на Mac владельца (канал согласован).

**Иконка приложения.** Раньше `Assets.xcassets` отсутствовал — в архиве не
было иконки. Добавлен каталог с `AppIcon-1024.png` (мята на графите, тема
Flint) и `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. Launch screen
(`UILaunchScreen`) и privacy-строки (`NSCameraUsageDescription`) уже были.
### Продолжение с 2026-10-29 (07:05 локаль = 00:05 UTC 29.10)

**Комиссия от настоящего backend — FFI-часть закрыта локально.**
Добавлена `grin_wallet_estimate_fee(handle, amount, dest)`: `estimate_only`
в `init_send_tx` — ничего не подписывает, не блокирует средства и не создаёт
транзакцию. Возвращает `{"fee": <u64>, "total": <u64>}`, где `total` =
сумма + реальная комиссия (не сумма выбранных входов).

Проверено локально против живой testnet-ноды на **копии** funded-кошелька
(бэкап 2026-10-28, каталог `C:\DHW\.tmp\fee-wallet`, пароль не в репозитории):
`оценка: fee=23500000, total=1023500000`, `spendable` до и после —
48 783 500 000 (оценка не списывает). Тест `tests/fee_estimate.rs`
конфигурируется через `GRINFFI_FEE_WALLET_DIR` / `GRINFFI_FEE_WALLET_PASS` /
`GRIN_E2E_NODE_URL`; без них — ошибка конфигурации.

Остаётся UI-часть (Swift): убрать декоративные fee tiers/ETA, показывать
реальную комиссию до подтверждения, Max считать с ней. Это требует iOS Build.
### Продолжение с 2026-10-29 (06:25 локаль = 23:25 UTC 28.10)

**Локальные (без iPhone и без Xcode) закрытые пункты приёмки.**

1. Online-тесты больше не «проходят» без обязательных параметров:
   `e2e_floonet` и `check_funded_balance` падают конфигурационной ошибкой
   («GRIN_E2E_SEED_FUNDED не задан — прогон без него не является проверкой»).
   Проверено локально: `test floonet_roundtrip_send_receive ... FAILED`,
   `test result: FAILED. 0 passed; 1 failed`. Дефолтный адрес ноды в E2E
   исправлен с mainnet-порта 3413 на testnet 13413.
2. FFI: нулевой handle больше не разыменовывается — все 8 функций берут
   контекст через проверяемый `wallet_mut`, возвращая «handle is null».
   `grin_wallet_destroy(NULL)` и `grin_string_free(NULL)` — безопасные no-op.
   Тест `ffi_rejects_null_handles_and_arguments` покрывает open/txs/balance/
   cancel/transfer_state/parse_amount.
3. Rust-тесты: **9 passed** локально (`cargo test --test roundtrip`).

Остаётся локально закрываемым (Rust/конфиг, без устройства): владение
строками и двойное освобождение в тестах, последовательность вызовов до
`open`, проверка отсутствия секретов в ошибках на синтетических маркерах.### Продолжение с 2026-10-29 (06:10 локаль = 23:10 UTC 28.10)

**Общий контракт desktop → iOS подключён.** В `ffi/transfer-contract`
вендорен пакет `flint-transfer-contract-1.0.0.zip` (sha256
`ca7ebbc51a73fd1275422b9e5b697028879264d16ec5501e92d0c4395ac6d377`,
исходник — `crates/transfer-contract` desktop-проекта, schema 1,
GPL-3.0-only). CI собирает iOS из этого каталога, доступа к `C:\DHW` не
требуется.

Что реально используется:
- `grin_wallet_create` разбирает сеть через `Network::parse` контракта —
  неизвестная строка по-прежнему ошибка, mainnet молча не выбирается;
- `grin_wallet_parse_amount` — точный разбор суммы (до 9 знаков, checked
  overflow) для отправки; Swift передаёт текст суммы, наногрины считает
  Rust, `Decimal→UInt64(truncating:)` из пути отправки убран;
- `grin_wallet_transfer_state` — этап/next_action/can_* по общим правилам
  (posted ≠ confirmed, отмена после публикации запрещена).

Тесты: `cargo test --test roundtrip` — **8 passed** локально, включая
`contract_fixtures_are_shared` (те же fixtures `send_posted.json` и
`receive_response_ready.json`, что у desktop), `amount_parse_is_exact`,
`transfer_state_follows_shared_contract`.

**Канал установки RC зафиксирован:** бесплатный Apple ID (Personal Team)
через Xcode на Mac пользователя; CI готовит неподписанный Release archive +
device XCFramework, подпись/установка — локально (7 дней). TestFlight/Ad Hoc
требуют платного Apple Developer Program и в этот RC не входят.### Продолжение с 2026-10-29 (05:30 локаль = 22:30 UTC 28.10)

**Юнит-тесты вместо «только UI».** Добавлен таргет `GrinFlintTests`
(`com.apple.product-type.bundle.unit-test`, `TEST_HOST` = приложение) и шаг
CI «Юнит-тесты (Keychain, журнал операций)» с артефактом
`unit-test-results`. Прогон 40777444199: **16 тестов, 0 падений**.

Что покрыто:
- `KeychainStore`: матрица политики миграции (`plan` — 4 ветки), создание
  и повторное использование пароля, **перенос старого пароля без потери
  записи** (старая удаляется только после контрольного чтения, при отмене
  остаётся), приоритет защищённой записи, тексты ошибок (OSStatus, без
  «пересоздайте кошелёк»).
- `PendingOperationsStore`: сохранение между экземплярами (перезапуск),
  `latest`/`awaitingSend`/`operation(txID:)`/`remove`, повреждённый файл
  даёт пустой журнал, Codable round-trip.
- `WalletError.pendingOperationExists`: сообщение объясняет, что повторная
  подпись не создаётся (проверка не зависит от языка хоста).

Для тестируемости: у `KeychainStore` появился параметр `service` (тесты
используют отдельный элемент и не трогают боевой), политика защиты
подменяется только в симуляторе (`testSetProtectionAvailable`). Реальный
`SecAccessControl .userPresence` в симуляторе не применяется — сама ACL
по-прежнему **NOT VERIFIED** на устройстве.

**Локализация новых строк.** В `Localizable.xcstrings` +86 строк
(всего **181**): журнал незавершённых переводов, проверка ноды и её ошибки,
этапы перевода, прогресс восстановления, диагностика Keychain, подписи
портфеля/настроек/истории, предупреждения о буфере обмена. Составные
литералы (`"a " + "b"`) склеены в один — иначе ключ каталога не совпадал,
и перевод не подхватывался.

`HEAD` после этих правок проверен run 40777444199 (10 UI-тестов + 16
юнит-тестов + смоук, всё зелёное).
### Продолжение с 2026-10-29 (02:10 локаль = 19:10 UTC 28.10)

Разбор замечаний к текущей реализации (статический разбор + правки).

**1. Защита входа — исправлено.** `BiometricAuth.require` больше не
«пропускает» при недоступной аутентификации и незнакомых ошибках: отказ,
отмена, отсутствие кода-пароля и ошибки LAError дают `throw`, а не успех.
`AppLockManager.unlock` снимает замок **только** после успешного
подтверждения; ошибка/отмена оставляют экран блокировки и показывают
причину (`lock.error`). Экран блокировки вынесен в отдельное окно
(`LockScreenPresenter`, уровень alert) — он закрывает и открытые sheet,
чего не делал `.overlay`. Тестовые переопределения `-simBiometric
allow|deny|cancel` действуют только в симуляторе; на устройстве код
переопределения не выполняется.

**2. Миграция Keychain — исправлено.** Новая запись `wallet-password-v2`
с `SecAccessControl` `.userPresence` (`WhenUnlockedThisDeviceOnly`).
Старый пароль `wallet-password` читается один раз, переносится, проверяется
контрольным чтением и только потом удаляется; при отмене подтверждения
новая запись удаляется, старая остаётся — единственный пароль не теряется.
Устройство с кодом, но без биометрии: `deviceOwnerAuthentication` даёт
фолбэк на код; если кода нет вообще — защита не навязывается, в настройках
видна диагностика `Keychain: код-пароль не задан…`. Новый пароль
создаётся только при `errSecItemNotFound`; ошибки чтения больше не
приводят к генерации нового пароля. Текст ошибок содержит OSStatus и
безопасные действия вместо «пересоздайте кошелёк/переустановите».

**3. Незавершённые переводы — исправлено.** `PendingOperationsStore`
(файл `pending-operations.json` в каталоге кошелька) хранит этап
(`awaitingResponse`/`responseReady`) и Slatepack; журнал переживает
перезапуск. `GrinWalletFFIService.exportSlatepack` берёт данные из журнала,
а не из истории (`mapTx` по-прежнему отдаёт `nil`, но экспорт от него больше
не зависит). Второй `prepareSend` при незавершённой отправке отклоняется
(`WalletError.pendingOperationExists`) — повторной подписи нет. На
портфеле карточка «Незавершённый перевод»: этап, запрос/ответ, ShareLink,
завершение ответом. В демо журнал тоже на диске — это проверяется XCUITest.

**4. Сеть — исправлено.** В `grin_wallet_create` сеть обязательна:
NULL и неизвестная строка дают ошибку (`неизвестная сеть …`), mainnet
больше не выбирается молча. Добавлен `grin_wallet_chain_genesis(chain)` —
genesis-хеш сети для проверки ноды. Демо-флаг `-simDemo` действует только
в симуляторе; при ошибке FFI возвращается `UnavailableWalletService`, а не
демо.

**5. Seed — исправлено.** Кнопка копирования seed-фразы из онбординга
удалена; основной сценарий — записать вручную (текст предупреждает, что
буфер не используется). Адрес/Slatepack копируются через
`Clipboard.copyLocalOnly` (`localOnly` + `expirationDate` 60 с) — без
обещаний «полного удаления» из системы.

**6. Подключение и удобство — частично.** Проверка ноды (`NodeProbe`):
доступность + совместимость сети по genesis-блоку (foreign `get_header`
высоты 0 против `grin_wallet_chain_genesis`), `127.0.0.1` на устройстве
отсекается с объяснением (в симуляторе допустим). В переводах показан
этап (1/3…3/3), добавлены ShareLink и импорт из файла; на приёме — файл и
QR. Восстановление показывает этапы (создание → открытие → скан выходов),
прерывание продолжается без повторного создания кошелька.

**Проверки (offline):** `cargo test --test roundtrip` — 5 passed, включая
`chain_type_is_strict` и `chain_genesis_is_strict`. Негативная онлайн-проверка
(нода `127.0.0.1:1`) — FAIL с «нода недоступна: нет ответа get_chain_tip»
(так и должно быть). Позитивная: восстановление seed в чистом каталоге
`grinffi-balance-check` — `spendable = 48783500000` (48.7835 tGRIN), адрес
совпал с прежним; после онлайн-прогона повторный скан в чистом каталоге
дал `spendable = 48735000000` (48.735 tGRIN), то есть списано 0.0485 —
баланс восстановленной копии сходится. Онлайн E2E (run 40747893309): перевод 1 tGRIN подтверждён
за 3 раунда, возврат B→A 0.975 tGRIN подтверждён за 1 раунд — PASS.

**NOT VERIFIED (нужен iPhone):** Face ID/код на входе и подписи, миграция
Keychain на реальном устройстве, блокировка поверх открытых sheet,
Share Extension из системного меню. Шаги: (1) установить сборку на iPhone
с код-паролем и Face ID; (2) включить «Требовать Face ID при входе»,
свернуть/развернуть приложение и убедиться, что замок поверх открытого
экрана отправки; (3) отменить Face ID — экран должен остаться закрытым;
(4) открыть старую сборку с незащищённым Keychain, затем новую — в
настройках должно быть «пароль перенесён под защиту Face ID»; (5) из
«Поделиться» отправить текст в GrinFlint — откроется лист приёма.
### Продолжение с 2026-10-29 (01:30 локаль = 18:30 UTC 28.10)

**Сканер QR камерой.** `QRScannerView` (AVCaptureSession +
AVCaptureMetadataOutput, первый распознанный QR отдаётся строкой). Кнопки:
отправка (`send.scan` — подставляется адрес) и приём (`receive.scan` —
подставляется Slatepack). В Info.plist добавлен `NSCameraUsageDescription`.
В симуляторе камеры нет: если устройства нет, доступ не запрашиваем и сразу
показываем «Камера недоступна — вставьте текст вручную» — иначе системный
запрос доступа перекрывал экран и тест падал. Проверено XCUITest
`testScannerFallback` (run 40743280868).

**Локализация интерполированных строк.** В `Localizable.xcstrings` добавлены
ключи с форматами (`Требовать %@ при входе`, `Доступно: %@`, `Слов: %lld`,
`Кошелёк не открылся: %@`, `Недостаточно средств: нужно %@, доступно %@.` и
др.), ошибки `WalletError` и баннер открытия переведены на
`String(localized:)`. В каталоге 95 строк. Проверено английским тестом:
на экране отправки строка начинается с `Available:` (run 40743280868).

**XCUITest — 7 тестов, 0 падений** (run 40743280868): вкладки, отправка/приём,
QR-адрес, детали транзакции, лист по ссылке, адресная книга, английская
локализация, недоступная камера.
### Продолжение с 2026-10-28 (21:15 локаль = 14:15 UTC)

**Share Extension.** Новый таргет `GrinFlintShare`
(`com.apple.product-type.app-extension`, synchronized group), встроен в
приложение фазой Embed Foundation Extensions; приложение зависит от
расширения. `ShareViewController` берёт текст или URL из `NSExtensionItem`
и открывает `grinslate://receive?text=<url-encoded>` — App Group не нужен,
данные идут через URL. Кодирование — всё, кроме `A-Za-z0-9-._~`, чтобы
`+`, `=` и `/` из Slatepack не терялись в query. Активация — текст и web
URL. Проверка в CI: `.appex` лежит в `PlugIns`, а
`NSExtensionPointIdentifier` печатается как `com.apple.share-services`
(run 40700203870).

**Адресная книга.** `AddressBook` (имя + Grin-адрес, UserDefaults, не
секрет), `ContactsView` (список/добавление/удаление), вход из настроек
(`settings.addressBook`), чипы контактов в отправке подставляют адрес
(`send.contact`).

**Локализация RU/EN.** `Localizable.xcstrings` (sourceLanguage `ru`,
83 строки с английским переводом), `CFBundleLocalizations` ru/en. Русские
строки остаются ключами в коде; английский приходит из каталога. Строки с
интерполяцией (`"Требовать \(…)"`) пока не локализованы — их надо
переводить через формат-строки отдельно.

**Что нашлось при проверке локализации (важно для будущих правок):**

- В бандле сборки появляется только `en.lproj`: русский не собирается как
  отдельная локализация, он работает как **регион разработки**
  (`developmentRegion = ru`), поэтому русские ключи показываются как есть.
  Если понадобится настоящий `ru.lproj` — добавить ru-локализацию в
  `Localizable.xcstrings`.
- Симулятор в CI англоязычный, поэтому основной набор XCUITest и скриншоты
  запускаются с `-AppleLanguages (ru) -AppleLocale ru_RU`, а
  `testEnglishLocalization` — с `(en)`.
- Строка адресной книги в настройках: у `NavigationLink` со
  `.buttonStyle(.plain)` тап ловился только по тексту, центр строки
  (`Spacer`) не нажимался. Добавлен `.contentShape(Rectangle())`.

**XCUITest — 6 тестов, 0 падений** (run 40732073714): адресная книга,
английская локализация, ссылка `grinslate://`, вкладки, отправка/приём, детали.

### Продолжение с 2026-10-28 (20:15 локаль = 13:15 UTC)

**URL scheme `grinslate:`.** Кастомный `GrinFlintApp/Info.plist`
(`CFBundleURLTypes`, схема `grinslate`), app-таргет переключён на
`INFOPLIST_FILE` вместо генерации. Формат:
`grinslate://receive?text=<url-encoded slatepack>` (поддерживается и
`grinslate://<данные>`). `ContentView.onOpenURL` разбирает ссылку через
`AppState.slatepack(from:)` и открывает лист приёма с подставленным текстом
(`ReceiveView(initialSlatepack:)`). Проверено XCUITest
`testIncomingSlatepackSheet` и `xcrun simctl openurl` в CI — система
показывает «Open in GrinFlint?» (кадр `url-scheme-prompt.png`), то есть
схема зарегистрирована.

**QR адреса.** `QRCode.swift` (CoreImage) + QR на экране приёма (белая
подложка, идентификатор `receive.qr`), пересчёт при смене адреса.

**Пароль Keychain под биометрией.** Элемент создаётся с `SecAccessControl`
`.userPresence` (Face ID/Touch ID, фолбэк на код устройства); чтение идёт
через системный запрос «Разблокируйте кошелёк», отмена объясняется
по-русски. `.biometryCurrentSet` **сознательно не используется**: после
сброса/новой регистрации Face ID элемент становится нечитаемым, и пароль
кошелька теряется безвозвратно. На симуляторе — прежняя политика (Face ID
там нет), смоук в CI не ломается. **На устройстве не проверялось** —
это первый кандидат на ручную проверку.

**XCUITest расширен до 4 тестов** (run 40691875916, 0 падений): вкладки,
отправка/приём (с QR), лист приёма по ссылке, детали транзакции.

**Осталось из пункта «Фаза 3»:** адресная книга и локализация; Share
Extension (приём из системного «Поделиться») — отдельная задача.

### Продолжение с 2026-10-28 (19:30 локаль = 12:30 UTC)

**XCUITest на навигацию — работает.** В проект добавлен таргет
`GrinFlintUITests` (`com.apple.product-type.bundle.ui-testing`,
synchronized group), в схему — TestAction с TestableReference, в `ios.yml` —
шаг «UI-тесты на симуляторе (XCUITest)»: `xcodebuild test` с теми же
FFI-флагами, что и сборка. Прогон **40686799752 — success**:
`testPortfolioAndTabs` (20.2 с) и `testSendAndReceiveScreens` (12.4 с),
2 теста, 0 падений. Результат-бандл — артефакт `uitest-results` (7 дней),
при падении тест прикладывает скриншот и печатает иерархию.

Тест идёт с `-walletExists YES -simDemo` (основной UI без сети и онбординга).
Для устойчивых тапов у кнопок портфеля есть идентификаторы
`portfolio.send` / `portfolio.receive`.

**Найдено тестом и исправлено:** тап по таб-бару не переключал вкладку,
хотя кнопки внутри экранов нажимались. Причина — `TapGesture` на корне
`ContentView` (сброс таймера автоблокировки) перехватывал касания
UIKit-таббара. Жест перенесён на контент каждой вкладки; автоблокировка
работает как раньше.

### Продолжение с 2026-10-28 (09:25 локаль = 02:25 UTC)

**Сделано после смоука:**

1. **Скриншоты реальных экранов в CI.** Шаг «Смоук на симуляторе» снимает
   8 кадров (`simctl io screenshot`) и публикует артефактом `sim-screenshots`
   (14 дней). Флаги идут аргументами запуска: `-walletExists YES` включает
   основной UI, `-simDemo` подменяет сервис демо-данными, `-simOpen
   send|receive|transactions|settings` сразу открывает экран. Первый зелёный
   прогон — 40616616122; кадры: онбординг, портфель (реальный и демо),
   отправка, приём, история, настройки, системный запрос кода устройства.
2. **Баннер ошибки старта.** `AppState.activate()` глотал ошибку `open()` —
   портфель показывал нули без причины. Теперь ошибка уходит в баннер
   («Кошелёк не открылся: …»), а сам баннер через `safeAreaInset` сдвигает
   контент, а не накрывает карточку баланса.
3. **Найдено этим баннером: паника при повторном открытии кошелька.**
   Текст: `panic in grin_wallet_open: GLOBAL_CHAIN_TYPE and CHAIN_TYPE unset`.
   Причина: `grin_core` хранит сеть в thread-local, а FFI зовётся с разных
   потоков Swift-актора. Фикс (коммит `9479616`): `GrinWallet` помнит
   `chain_type`, перед каждым вызовом ставит thread-local, `create`
   инициализирует и глобальный. Регрессия — тест
   `wallet_open_on_another_thread`; локально `cargo test --test roundtrip` —
   **3 passed**.

**Результаты (проверено 18:48 локаль):**

- iOS Build 40619667812 (`9479616`) — **success**; 40620723363 (`433ec7f`) —
  **success**.
- E2E 40619696017 (`9479616`) — **success**: возврат B→A отработал. Баланс A
  после прогона — **48.7835 tGRIN** (`spendable = 48783500000`, скан с живой
  ноды 18:47); до прогона было 48.832, списано 0.0485.
- Локально: `cargo test --test roundtrip` — **3 passed** (включая
  `wallet_open_on_another_thread`).
- Копия данных кошелька обновлена под 48.7835:
  `C:\DHW\mobile\grinflint-backups\2026-10-28\`.

**Дальше по плану:** XCUITest на навигацию; URL scheme `grinslate:` и
Share Extension (нужен новый target и правка pbxproj — только с согласия);
привязать пароль Keychain к биометрии.

### Продолжение с 2026-10-28 (07:25 локаль = 00:25 UTC)

Работа по списку «что дальше»: симуляторный смоук, аудит, UX интерактивных tx.

**Смоук на симуляторе — работает (run 40607181039, success).** Шаг «Смоук
на симуляторе» в `ios.yml`: app ставится на iPhone 16 Pro (simulator),
запускается с `-SimSmoke`, отчёт — `Documents/sim-smoke.json`. Отчёт:
`backend: grin-wallet 5.5.1 (FFI)`, `demo: false`, `keychain_password: true`,
`mnemonic_words: 24`, `restore_address_matches: true`, `elapsed_ms: 437`,
`ok: true`. Что нашлось по дороге:
1. **Keychain `-34018`** (`errSecMissingEntitlement`): сборка шла с
   `CODE_SIGNING_ALLOWED=NO`, а без подписи `SecItemAdd` в симуляторе не
   работает. Убрали флаг — Xcode подписывает ad-hoc сам. Вариант «подписать
   вручную с entitlements» оставлен только как fallback: с ним SpringBoard
   отказывал в запуске (`SBMainWorkspace`, code=1).
2. **`refresh` без ноды отдавал `ok` и нулевой баланс** — grin-wallet берёт
   локальную БД, а `node_height` глотает сетевую ошибку. Добавлена проверка
   `get_chain_tip` по флагу `updated_from_node`: теперь «нода недоступна: …»
   (коммит `e3cb933`, проверено негативным прогоном на `127.0.0.1:1` и
   положительным — на живой ноде). После правки смоук честно пишет
   `refresh: error: нода недоступна: нет ответа get_chain_tip` (ноды на
   раннере нет) и по-прежнему `ok: true`.
3. **E2E после правки FFI — run 40609214248, success** (00:30–00:46 UTC,
   тест 764.56 с): `подтверждено за 7 раунд(ов)`, `возврат B→A: 975000000`,
   `возврат подтверждён за 1 раунд(ов)`. Баланс A — **48.832 tGRIN**
   (проверено сканом с живой ноды: `spendable = 48832000000`); прогон
   стоил 0.0485.

**Аудит — `docs/mobile/ios/security-audit.md`.** Секретов в логах и
UserDefaults нет, force-unwrap один (демо-константа). Исправлено: молчаливый
демо-фолбэк (`UnavailableWalletService` + `StartupErrorView`) и каталог
данных до `grin_wallet_create`. Остаток (биометрия на пароль Keychain,
fail-open `BiometricAuth`) — в таблице рисков документа.

**UX интерактивных tx.** Статус «Возвращено» для `Reverted`/`Cancelled`;
`TxReminders` — локальное напоминание через 10 минут после незавершённой
транзакции, снимается после finalize. Доставка на устройстве не проверялась.

Не делали: URL scheme `grinslate:` и Share Extension — нужен новый target и
правка pbxproj, это отдельная задача.

### Продолжение с 2026-10-28 (05:13 локаль = 22:13 UTC)

Поверх `bfa81ef` запушены три коммита; техдолг FFI из прошлого списка закрыт.

1. **`0ca6819` — `message` в `grin_wallet_send`.** В grin-wallet 5.5.1 у
   slatepack нет поля сообщения (проверено по исходникам `grin_wallet_libwallet-5.5.1`:
   в `ParticipantData` только ключи/подпись, у `create_slatepack_message`
   параметра сообщения нет), поэтому текст не мог попасть в slatepack.
   Параметр удалён из C-API, заголовка и вызовов. Добавлен оффлайн-тест
   `restore_from_12_words` (12 слов = 16 байт энтропии; адрес после
   восстановления совпадает). Локально на Windows
   `cargo test --test roundtrip`: **2 passed** (2026-10-28 05:12).
2. **`19b5b49` — поле сообщения убрано из UI.** `SendFlowView` («Сообщение»),
   `ReceiveView` («Комментарий»), `WalletService`/`WalletViewModel`/
   `MockWalletService`/`GrinWalletFFIService`, демо-`SlatepackCodec`. Поле
   выглядело рабочим, но текст никуда не уходил. Вернуть — только с
   отдельным каналом (Фаза 5: Grinbox/Nostr).
3. **`232151e` — E2E с ногой возврата B→A** (`GRIN_E2E_RETURN_TO_A=1`
   в workflow): после подтверждения у B кошелёк B отправляет сумму минус
   две комиссии обратно на адрес A, тест ждёт подтверждённый входящий
   (`grin_wallet_txs` + `confirmed`). Прогон стоит ~0.05 tGRIN вместо ~1.04
   (измерено: 48.977 → 48.929).

CI по этим коммитам:
- **iOS Build — run 40593119197, success.** Все четыре задания зелёные:
  `cargo check`, смоук-тест FFI на macOS (оба теста, включая 12 слов),
  XCFramework и «Сборка GrinFlint (симулятор + FFI)» — Swift собрался с
  новой сигнатурой `grin_wallet_send`.
- **E2E — run 40593127479, success** (22:13:25–22:31:09 UTC, сам тест
  870.77 с). Опорные строки лога: `poll 1` — пусто, `poll 2` — `body_sync`,
  `poll 3` — `no_sync`; `перевод 1000000000 наногрин (комиссия сверху)`;
  `подтверждено за 12 раунд(ов): B spendable = 1000000000`;
  `возврат B→A: 975000000 наногрин (комиссия сверху)`;
  `возврат подтверждён за 1 раунд(ов): A получил 975000000`.
  Нога возврата стоила один лишний раунд опроса (20 с). Баланс A после
  прогона — **48.929 tGRIN** (проверено локально `check_funded_balance`
  против ноды 127.0.0.1:13413: `spendable = 48929000000`); прогон списал
  0.048 tGRIN, а не сумму перевода.
- **Повторный E2E на HEAD `0c96a17` — run 40597688610, success**
  (22:49:21–23:04:26 UTC, тест 728.07 с): `подтверждено за 10 раунд(ов):
  B spendable = 1000000000`, `возврат B→A: 975000000`,
  `возврат подтверждён за 1 раунд(ов): A получил 975000000`.
  Баланс после двух прогонов — **48.8805 tGRIN** (`spendable = 48880500000`):
  один прогон стоит 0.0485. Первый замер сразу после прогона дал 47.9055 —
  локальная нода ещё не получила блок с возвратом; повторный скан после
  догона ноды сошёлся с расчётом.

### Продолжение с 2026-10-28 (03:50 локаль = 20:50 UTC)

**E2E ЗЕЛЁНЫЙ: run 40584267368** (коммит `522122f`, 2026-10-27 21:31:16 UTC,
960 с). Опорные строки лога: `poll 1` — пусто, `poll 2` — `body_sync`,
`poll 3` — `no_sync`; `перевод 1000000000 наногрин (комиссия сверху)`;
`подтверждено за 17 раунд(ов): B spendable = 1000000000`.

Предыдущий прогон **40581454614 упал** (643 с) на
`Insufficient funds. Required: 50.012500000, Available: 50.000000000`:
тест слал ровно весь баланс, а комиссия платится сверху. Деньги не были
потрачены.

Исправление в `522122f` (запушено): сумма перевода конфигурируемая —
`GRIN_E2E_AMOUNT_NGRIN`, дефолт 1 tGRIN; в проверке баланса учтён
`FEE_HEADROOM` = 0.0125 tGRIN; `floonet-e2e.yml` передаёт 1 tGRIN явно.

**UI → FFI:** коммит `ecc6f02` (finalize ответным Slatepack, честный бэкенд
в настройках, floonet-нода по умолчанию 127.0.0.1:13413); `iOS Build`
**зелёный** — run 40588800281, «Сборка (с реальным FFI)» прошла.
Баланс CI-кошелька после зелёного E2E: 48.977 tGRIN.

Что уже исправлено и запушено (коммиты 2026-10-27/28):
1. **Порт тестнет-API 13413** (было 3413 → сутки «стены»: нода слушала
   13413, опрос стучался на 3413, `sync_status` всегда пуст).
2. **Снапшот цепи** `floonet-chain-2026-10-28` (height ~3311500) — release
   опубликован (`--draft=false`; убитый таймаутом `gh release create`
   оставил draft, и CI его «не видел»).
3. **Прогрев кеша ЗЕЛЁНЫЙ** (run 40565586922): снапшот скачан, нода
   догнала, кеш `testnet-chain-2026-W44` сохранён. E2E стартует тёплым.
4. **Секрет TEST_WALLET_SEED обновлён** = фраза из
   `C:\DHW\docs\grinflint-ci-wallet.txt` (кошелёк с 50 tGRIN, баланс
   проверен вживую 2026-10-28; см. раздел «Тестовые активы»).
5. **Уравнивание owner/foreign API-секретов ноды** при старте: иначе
   кошелёк получает 401 на foreign API и возвращает пустой баланс
   (restore/refresh/send используют foreign API с owner-секретом;
   локальная нода работает лишь потому, что её `.foreign_api_secret`
   пуст).
6. **Детерминированный перезапуск ноды** (pkill -9 + ожидание смерти
   процесса): раньше второй старт падал с «Failed to lock grin.lock»,
   после чего не оставалось ни одной живой ноды.

Ожидаемое поведение текущего прогона: restore кеша ~2 мин → boot/kill/
restart ноды ~2 мин → догон ~5 мин → compile ~3 мин → тест: refresh
кошелька ~6 мин + send/receive/finalize + ожидание подтверждения
(30 раундов × 20 с ≈ 10 мин). Итого ~30 мин. Ловить в логе: строки
`poll N: <sync_status>`, затем `подтверждено за N раунд(ов)` или панику.

Если упадёт на «недостаточно средств на A»: прогон тратит сумму перевода
+ комиссию (~0.0125 tGRIN). При дефолте 1 tGRIN 50 tGRIN на кошельке
хватает примерно на 49 прогонов; когда кончится — пополнить (см.
«Пополнение» в `C:\DHW\docs\grinflint-ci-wallet.txt`). Если на пустых
`poll` — смотреть хвосты `grin-node.log`, которые workflow печатает при
пустом ответе API.

### Дальше по плану

1. **Ручная проверка на iPhone (NOT VERIFIED):** Face ID/код на входе и
   подписи, миграция Keychain, блокировка поверх открытых sheet, Share
   Extension, сканер QR. Шаги — в разделе 02:10 выше.
2. Проверить `NodeProbe` на устройстве с реальной LAN-нодой: `127.0.0.1`
   должен отклоняться, своя нода — подключаться; genesis-проверка не
   должна пропускать mainnet-ноду в floonet-сборке.
3. Расширять XCUITest: отмена транзакции, пустые состояния, ошибки.
4. Юнит-тесты для `NodeProbe` (парсинг JSON-RPC и отсечения) и `AddressBook`
   (персистентность контактов).
5. Вернуть текст сообщения к транзакции — только вместе с отдельным каналом
   передачи (Grinbox/Nostr, Фаза 5): slatepack 5.5.1 его не несёт.
6. Фаза 4: внешний аудит крипто-кода перед mainnet.
