# AGENTS.md — GrinFlint (iOS-кошелёк Grin)

Рабочий корень: **`C:\DHW\IosProject`** (git-репозиторий, ветка `main`,
origin `github.com/DanilaGrinRus/GrinFlint`, **публичный**). Проект также
называют «IosFlint» — это одно и то же; при переименовании папки ничего
не ломается (все пути внутри репозитория относительные).

Дата актуализации: 2026-10-27.

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
2. **Старый testnet-seed** (файл `C:\DHW\Docs\testnet-funded.txt`,
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
  `cd %TEMP% && cargo test --manifest-path C:\DHW\IosProject\ffi\grin-wallet-ffi\Cargo.toml ...`.
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
| `.github/workflows/floonet-e2e.yml` | E2E: своя floonet-нода в раннере + roundtrip 50 tGRIN (dispatch + cron пн 04:17 UTC); цепь — только restore, сохраняет «прогрев» |
| `.github/workflows/floonet-chain-cache.yml` | Прогрев кеша цепи: синк ноды до 280 мин + save частичного прогресса всегда (`if: always()`); воскресенье 20:27 UTC + вручную |
| `docs/mobile/ios/` | README, architecture, grin-wallet-integration, roadmap, AGENTS.md (этот файл) |
| `ffi/include/grin_wallet_ffi.h` | C-заголовок для Swift (bridging header уже настроен) |

## C-API FFI (ffi/grin-wallet-ffi/src/lib.rs)

`grin_wallet_create(data_dir, node_url, chain, api_secret)` → handle.
`chain`: `"mainnet"` | `"floonet"` (внутри мапится на Testnet).
`api_secret`: NULL ок; для ноды с Basic Auth — секрет.

Далее: `grin_wallet_create_seed(h, pass, слова, фраза|NULL)`
(24 слова снаружи = 32 байта энтропии внутри!), `grin_wallet_open` →
`{"address"}`, `grin_wallet_balance(h, refresh)` (refresh=1 — опрос ноды),
`grin_wallet_txs`, `grin_wallet_send` → `{"slatepack","slate_id","fee"}`,
`grin_wallet_receive` → `{"slatepack"}`, `grin_wallet_finalize` (включает
post в ноду), `grin_wallet_cancel`. Ошибки: NULL / -1 + `grin_last_error()`.
Строки возвращённые — освобождать `grin_string_free`.

Известные ограничения FFI (техдолг):
- `grin_wallet_send` **игнорирует message** (`let _ = message;`) —
  сообщение не попадает в slatepack.
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
- UI-демо — на `MockWalletService`; к живому FFI в работающем приложении
  **вручную не стыковалось**. Веб-рендер экранов: см. «Превью».

## Тестовые активы

- **CI-кошелёк**: секрет `TEST_WALLET_SEED` (24 слова BIP39), на нём
  50 tGRIN (floonet, проверено 2026-10-28). E2E-тест восстанавливает его
  и шлёт с него. **Каждый зелёный прогон тратит эти 50** (перевод на
  свежий кошелёк B без обратной ноги) — после успеха кошелёк нужно
  пополнить заново. Полные реквизиты (seed + пароль `e2e-test-password`):
  `C:\DHW\Docs\grinflint-ci-wallet.txt` — доверять ему; рабочая копия
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

### Продолжение с 2026-10-28 (03:50 локаль = 20:50 UTC)

Текущий прогон E2E: **run 40581454614** (запущен 20:45 UTC, статус на
момент фиксации — in_progress). Первым делом проверить его итог:
`gh run view 40581454614 --repo DanilaGrinRus/GrinFlint --log`.

Что уже исправлено и запушено (коммиты 2026-10-27/28):
1. **Порт тестнет-API 13413** (было 3413 → сутки «стены»: нода слушала
   13413, опрос стучался на 3413, `sync_status` всегда пуст).
2. **Снапшот цепи** `floonet-chain-2026-10-28` (height ~3311500) — release
   опубликован (`--draft=false`; убитый таймаутом `gh release create`
   оставил draft, и CI его «не видел»).
3. **Прогрев кеша ЗЕЛЁНЫЙ** (run 40565586922): снапшот скачан, нода
   догнала, кеш `testnet-chain-2026-W44` сохранён. E2E стартует тёплым.
4. **Секрет TEST_WALLET_SEED обновлён** = фраза из
   `C:\DHW\Docs\grinflint-ci-wallet.txt` (кошелёк с 50 tGRIN, баланс
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

Если упадёт на «недостаточно средств на A»: E2E тратит 50 tGRIN за прогон
— пополнить кошелёк (см. «Пополнение» в
`C:\DHW\Docs\grinflint-ci-wallet.txt`). Если на пустых `poll` — смотреть
хвосты `grin-node.log`, которые workflow печатает при пустом ответе API.

### Дальше по плану

1. Стыковка UI с `GrinWalletFFIService` вместо мока (баланс с ноды,
   реальный send/receive) — проверять через CI-сборку и логи.
2. Техдолг FFI: message в send; тест восстановления на 12 слов.
3. Фаза 2 роадмапа: reorg-обработка, push-напоминания об интерактивных
   tx, аудит крипто-путей.
4. E2E одноразовый по деньгам: после зелёного прогона придумать цикл
   пополнения (вернуть с B / намайнить), либо B→A-ногу в тесте.
