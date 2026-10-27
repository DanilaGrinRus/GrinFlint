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

## Структура репозитория

| Путь | Содержимое |
|---|---|
| `GrinFlintApp/GrinFlint.xcodeproj` | Xcode-проект; синхронизированные группы — **новые .swift подхватываются автоматически**, pbxproj не править |
| `GrinFlintApp/GrinFlint/Theme.swift` | Все цвета/радиусы/шрифты (токены Flint) |
| `GrinFlintApp/GrinFlint/Views/` | Экраны: Portfolio, SendFlow, Receive, Transactions, Settings, Onboarding, LockScreen |
| `GrinFlintApp/GrinFlint/Services/` | `WalletService` (протокол), `MockWalletService` (демо), `WalletFactory`, `KeychainStore`, `BiometricAuth`, `SlatepackCodec`, `FFI/GrinWalletFFIService` (под флагом `GRINFFI`) |
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
  **2 passed** (2026-10-28).
- UI подключён к живому FFI (сборка с `GRINFFI`): `WalletFactory` отдаёт
  `GrinWalletFFIService`, у отправки появился шаг завершения ответным
  Slatepack, приём показывает ответный Slatepack, настройки честно
  показывают бэкенд. **На устройстве/симуляторе не проверялось** — только
  компиляция в CI (run 40588800281, зелёный). Демо-режим остаётся для
  сборок без `GRINFFI`.

## Тестовые активы

- **CI-кошелёк**: секрет `TEST_WALLET_SEED` (24 слова BIP39), на нём
  **48.929 tGRIN** (floonet, после прогона 40593127479 с возвратом B→A;
  до него было 48.977). E2E-тест восстанавливает его и шлёт с него.
  **Комиссия платится сверху**, поэтому сумма перевода обязана быть меньше
  баланса: в CI это 1 tGRIN (`GRIN_E2E_AMOUNT_NGRIN`). С ногой возврата
  (`GRIN_E2E_RETURN_TO_A=1`, включена в workflow) прогон стоит ~0.05 tGRIN
  (две комиссии ~0.023 + 0.025 не возвращается: остаётся на B сдачей и
  уходит в комиссию возврата); без возврата — сумму + ~0.02 tGRIN. Полные
  реквизиты (seed + пароль `e2e-test-password`):
  `C:\DHW\docs\grinflint-ci-wallet.txt` — доверять ему; рабочая копия
  `C:\DHW\.tmp\grinsend\ci-seed.txt` могла устареть.
- Проверка баланса кошелька против живой ноды: тест
  `ffi/grin-wallet-ffi/tests/check_funded_balance.rs` (env-gated:
  `GRIN_E2E_SEED_FUNDED`, `GRIN_E2E_NODE_URL`, `GRIN_E2E_API_SECRET`;
  образец `C:\DHW\.tmp\check-balance.ps1`). Первое обновление сканирует
  UTXO ~5-7 минут — это норма, а не зависание.
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
- `docs/mobile/ios/architecture.md`, `docs/mobile/ios/grin-wallet-integration.md`,
  `docs/mobile/ios/README.md`.

## Ближайшие открытые пункты

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

1. Проверить UI-флоу на устройстве/симуляторе (локального Xcode нет):
   онбординг → баланс с ноды → send → receive → finalize. Сейчас
   подтверждена только компиляция и сборка в CI.
2. Фаза 2 роадмапа: reorg-обработка, push-напоминания об интерактивных
   tx, аудит крипто-путей.
3. Вернуть текст сообщения к транзакции — только вместе с отдельным
   каналом передачи (Grinbox/Nostr, Фаза 5): slatepack 5.5.1 его не несёт.
4. Держать E2E «вечным»: нога B→A уже есть, следить за балансом A по логу
   `возврат подтверждён за N раунд(ов)`.
