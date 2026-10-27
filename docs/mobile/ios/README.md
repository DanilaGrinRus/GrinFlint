# GrinFlint (iOS) — описание проекта

**GrinFlint** — некастодиальный кошелёк криптовалюты Grin (Mimblewimble) для
iOS: SwiftUI, iOS 17+, MVVM. Дизайн и UX — по мотивам Flint Wallet; визуальная
тема синхронизирована с десктопным Flint (мятный акцент `#6ee7b7` на
графитово-синем). Блокчейн-слой — официальный grin-wallet v5.5.1 (Rust),
подключённый через собственный C-API (FFI), собранный в XCFramework.

## Это отдельная ветвь разработки

Проект является **самостоятельной линией развития идей Flint Wallet** и не
является частью десктопного проекта Flint. Десктопный Flint живёт в `C:\DHW`
(корень: `crates/`, `vendor/`, `.node/`, `target/` и т.д.) — **его каталоги
не редактировать**; читаются только `docs/`, `tools/` (по необходимости) и
один файл `crates/slint-ui/ui/theme.slint` (источник токенов темы).
Правила чужого проекта — в `C:\DHW\AGENTS.md`, они на нас не распространяются,
но их дерево — нетронуто.

GitHub: `github.com/DanilaGrinRus/GrinFlint` (ветка `main`, **публичный**
репозиторий → секреты только через GitHub Secrets, никогда в код/логи).

## Что уже работает (проверено)

- Rust FFI-крейт `ffi/grin-wallet-ffi`: init/recover/open/balance/txs/
  send/receive/finalize/cancel над grin-wallet 5.5.1; сборка в XCFramework
  для iOS (device+sim) в CI.
- Swift-обёртка `GrinWalletFFIService` компилируется в CI (флаг `GRINFFI`);
  в `GRINFFI`-сборке `WalletFactory` отдаёт именно её, экраны показывают
  реальный бэкенд. Отправка получила шаг завершения ответным Slatepack,
  приём — показ ответного Slatepack (run 40588800281, сборка зелёная).
  На устройстве/симуляторе флоу не проверялся.
- Смоук-тест lifecycle (оффлайн) — зелёный.
- **E2E roundtrip tGRIN против живой floonet-ноды** — проверен вживую
  локально (2026-10-27, 50 tGRIN) и вынесен в CI (`floonet-e2e.yml`);
  сумма в CI по умолчанию 1 tGRIN (`GRIN_E2E_AMOUNT_NGRIN`), иначе
  комиссия не покрывается из остатка баланса.
- Face ID/Touch ID на вход и подпись + автоблокировка — код написан, сборка
  зелёная; на устройстве не проверялось (симулятора нет).
- Тема Flint (мята/графит) применена к UI-демо (веб-рендер экранов).

## Ключевая инфраструктура CI (проверено болью — читать перед правками)

| Компонент | Значение |
|---|---|
| Директория данных тестнет-ноды | `~/.grin/test` (shortname цепи Testnet) |
| **API-порт тестнета** | **13413** (owner и foreign). Порт 3413 — mainnet! |
| Снапшоты цепи | release-ассеты `floonet-chain-part-*` в релизе `floonet-chain-YYYY-MM-DD`; создавать строго `gh release create ... ` и проверять, что релиз **не draft** (`--draft=false`) |
| Кеш цепи | ключ `testnet-chain-<год-W<номер>`; греет `floonet-chain-cache.yml` (вс 20:27 UTC), E2E только restore |
| E2E | `floonet-e2e.yml` (dispatch + cron пн 04:17 UTC) |
| Секреты ноды | `.api_secret` и `.foreign_api_secret` у кошелька должны **совпадать** (workflow уравнивает их при старте; иначе restore/refresh кошелька получает 401 и пустой баланс) |
| Тестовый кошелёк | секрет `TEST_WALLET_SEED`; файл `C:\DHW\docs\grinflint-ci-wallet.txt` (seed+пароль); баланс после зелёного E2E 48.977 tGRIN, прогон тратит 1 tGRIN + комиссию (~0.023) → хватает примерно на 47 прогонов |
| Нода по умолчанию | floonet-сборка: `http://127.0.0.1:13413` (`WalletFactory.floonetNodeURL`); mainnet-дефолт `https://grinnode.live:3413` — только для Фазы 4 |

## Локальная нода пользователя (для ручных прогонов)

- API `http://127.0.0.1:13413`, секрет `C:\DHW\.node\testnet\node\.api_secret`.
- Запуск/стоп: `C:\DHW\tools\run-testnet-node.ps1` не парсится в PowerShell 5.1;
  использовать `taskkill //PID <pid> //F` (pid в `C:\DHW\.node\testnet\node.pid`)
  и WMI-запуск helper'а `C:\DHW\tools\_start-node-hidden.ps1`
  (пример: `C:\DHW\.tmp\start-node.ps1`).
- Образец локального E2E: `C:\DHW\.tmp\grinsend\run-e2e.ps1`
  (cargo обязан запускаться с CWD вне `C:\DHW`, TMP=`C:\DHW\.tmp`).

## Документы

- [roadmap.md](roadmap.md) — фазы, критерии выхода, статусы (источник правды по плану).
- [architecture.md](architecture.md) — слои приложения, контракты, конвенции.
- [grin-wallet-integration.md](grin-wallet-integration.md) — контракт FFI;
  актуальная реализация — `ffi/grin-wallet-ffi/src/lib.rs`.
- [AGENTS.md](AGENTS.md) — правила для агентов: секреты, ловушки окружения,
  типовые задачи, открытые пункты. **Начинать работу с него.**

Xcode-проект: `GrinFlintApp/GrinFlint.xcodeproj`.

## Как продолжать работу (быстрый старт)

1. Прочитать [AGENTS.md](AGENTS.md) — там железные правила и ловушки.
2. Любое изменение Swift → push → ждать зелёный «iOS Build» (~20 мин).
3. Любое изменение FFI → смоук-тест в CI; локально cargo из `%TEMP%`.
4. Для E2E: сначала `floonet-chain-cache.yml` (прогрев, ~10 мин со снапшотом),
   затем `floonet-e2e.yml`. Следить за `poll N: <sync_status>` в логе.
5. Свежий снапшот цепи: остановить ноду (taskkill), скопировать
   `C:\DHW\.node\testnet\node\chain_data`, запустить ноду, `xz -3 -T8`,
   `split -b 1900m`, залить parts как **опубликованный** релиз
   `floonet-chain-YYYY-MM-DD`, обновить TAG в `floonet-chain-cache.yml`.
