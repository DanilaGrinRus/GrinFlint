# Аудит безопасности GrinFlint (iOS) — 2026-10-28

Статус: **DEV BUILD. Внешнего аудита не было, реальные средства
использовать нельзя.** Документ фиксирует, что проверено по коду и тестам,
что найдено и что осталось.

## Метод

- чтение Swift-кода `GrinFlintApp/GrinFlint/**` и Rust-обёртки
  `ffi/grin-wallet-ffi/src/lib.rs`;
- оффлайн-тесты FFI (`cargo test --test roundtrip` — 2 теста) и живой E2E
  roundtrip tGRIN;
- реальный запуск приложения на симуляторе в CI (`-SimSmoke`).

## Что проверено

| Проверка | Результат |
|---|---|
| Секреты в логах (`print`, `NSLog`, `os_log`, `Logger`) | вызовов нет ни одного |
| Seed/пароль в `UserDefaults` | нет: только `nodeURL`, `walletExists`, `requireBiometrics`, `autoLockInterval` |
| Пароль кошелька | 32 случайных байта, Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| Force-unwrap в сервисном слое | нет; единственный `!` — демо-константа `Decimal(string: "3.141592653")!` в `MockWalletService` |
| Seed на экране | показывается только при создании/восстановлении, не пишется в файлы приложения и не логируется |
| Keychain в CI-сборке | найден дефект: без подписи `SecItemAdd` → `-34018` (`errSecMissingEntitlement`) |
| Запуск на симуляторе | приложение стартует, FFI-стек проходит (см. смоук в `ios.yml`) |
| Refresh без ноды | раньше возвращал `ok` и нулевой баланс — теперь «нода недоступна: …» |

## Найдено и исправлено

1. **Молчаливый демо-фолбэк.** `WalletFactory` при сбое FFI отдавал
   `MockWalletService` — UI показывал фальшивый баланс 148 GRIN. Теперь
   возвращается `UnavailableWalletService`, а приложение показывает экран
   «Кошелёк не запустился» с причиной (`StartupErrorView`).
2. **Keychain без подписи.** CI собирал приложение с `CODE_SIGNING_ALLOWED=NO`,
   и Keychain отвечал `errSecMissingEntitlement`. Job смоука подписывает
   `.app` локальной подписью `-` с `SimulatorEntitlements.plist`
   (`application-identifier`, `keychain-access-groups`). Ошибка Keychain теперь
   объясняется по-русски, а не кодом `OSStatus`.
3. **Каталог данных кошелька.** `Documents/grin-wallet` не создавался до
   `grin_wallet_create`, а FFI пишет туда `grin-wallet.toml` — на первом
   запуске это ошибка. Каталог создаётся в `WalletFactory`.
4. **Reorg/отмена.** Откатившиеся транзакции (`Reverted`/`Cancelled`)
   выглядели как «Не подтверждено». Добавлен статус «Возвращено».
5. **Ложный ноль при недоступной ноде.** `grin_wallet_balance(refresh=1)`
   возвращал `ok` с нулевым балансом, если нода не отвечает (grin-wallet
   берёт данные из локальной БД). Теперь refresh сначала проверяет
   `get_chain_tip` и падает с «нода недоступна: …». Проверено негативным
   прогоном против `127.0.0.1:1`, положительным — против живой ноды
   (48.832 tGRIN) и E2E-прогоном 40609214248.
6. **Паника при открытии кошелька на другом потоке.** Симптом:
   `panic in grin_wallet_open: GLOBAL_CHAIN_TYPE and CHAIN_TYPE unset`.
   Причина: `grin_core` хранит сеть в thread-local, а FFI зовётся с разных
   потоков Swift-актора. Исправлено: контекст FFI помнит `chain_type` и
   ставит thread-local перед каждым вызовом, `create` инициализирует и
   глобальный. Регрессия — тест `wallet_open_on_another_thread`.

## Остаётся (риски)

| Риск | Влияние | Что делать |
|---|---|---|
| Пароль Keychain защищён биометрией только на устройстве | в симуляторе/CI элемент без `SecAccessControl`; на устройстве не проверялось | первый ручной прогон на iPhone: Face ID при чтении пароля, отмена и повтор |
| `BiometricAuth` fail-open | нет Face ID/код-пароля → проверка пропускается (осознанно, чтобы не блокировать безвыходно) | политика зависит от требований; минимум — предупреждение в настройках |
| Seed в памяти Swift | строка живёт до освобождения | не держать дольше экрана; `ZeroingString` только внутри Rust |
| Удалённая нода — точка доверия | видит запросы кошелька (не ключи), может отдавать ложные данные | свой узел / Tor (Фаза 5) |
| Нет внешнего аудита крипто-кода | неизвестные дефекты | аудит перед mainnet (Фаза 4) |
| Смоук не проверяет UI-навигацию | тапы/лейаут в CI не гоняются | XCUITest (сделан) + расширять сценарии |

### Биометрия и Keychain (2026-10-28)

`KeychainStore.savePassword` создаёт элемент с `SecAccessControl` и флагом
`.userPresence`, если на устройстве есть зарегистрированная биометрия:
прочитать пароль можно только после Face ID/Touch ID (или кода устройства),
текст запроса — «Разблокируйте кошелёк». `.biometryCurrentSet` не
используется: любая повторная регистрация Face ID делает элемент
нечитаемым, а пароль кошелька восстановить нельзя. На симуляторе (и в CI)
элемент создаётся по прежней политике `AfterFirstUnlockThisDeviceOnly`,
поэтому смоук и UI-тесты не зависят от биометрии.

## Как проверить самому

```powershell
# оффлайн-смоук FFI (Windows: cargo из %TEMP%, TMP=C:\DHW\.tmp)
cargo test --manifest-path C:\DHW\mobile\GrinFlint\ffi\grin-wallet-ffi\Cargo.toml --test roundtrip
```

В CI: workflow «iOS Build», шаг «Смоук на симуляторе (запуск app + FFI)» —
результат приложения лежит в `Documents/sim-smoke.json`, job требует
`ok: true`.
