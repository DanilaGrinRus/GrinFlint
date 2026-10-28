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

## Остаётся (риски)

| Риск | Влияние | Что делать |
|---|---|---|
| Пароль Keychain не привязан к биометрии | на разблокированном устройстве процесс может прочитать пароль | `kSecAccessControlBiometryCurrentSet` + `LAContext` при чтении |
| `BiometricAuth` fail-open | нет Face ID/код-пароля → проверка пропускается (осознанно, чтобы не блокировать безвыходно) | политика зависит от требований; минимум — предупреждение в настройках |
| Seed в памяти Swift | строка живёт до освобождения | не держать дольше экрана; `ZeroingString` только внутри Rust |
| Удалённая нода — точка доверия | видит запросы кошелька (не ключи), может отдавать ложные данные | свой узел / Tor (Фаза 5) |
| Нет внешнего аудита крипто-кода | неизвестные дефекты | аудит перед mainnet (Фаза 4) |
| Смоук не проверяет UI-навигацию | тапы/лейаут в CI не гоняются | XCUITest или ручной прогон на устройстве |

## Как проверить самому

```powershell
# оффлайн-смоук FFI (Windows: cargo из %TEMP%, TMP=C:\DHW\.tmp)
cargo test --manifest-path C:\DHW\mobile\GrinFlint\ffi\grin-wallet-ffi\Cargo.toml --test roundtrip
```

В CI: workflow «iOS Build», шаг «Смоук на симуляторе (запуск app + FFI)» —
результат приложения лежит в `Documents/sim-smoke.json`, job требует
`ok: true`.
