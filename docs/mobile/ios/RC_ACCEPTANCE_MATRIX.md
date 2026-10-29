# Матрица возможностей RC — GrinFlint iOS

Срез на 2026-10-29. PASS — подтверждено автоматической проверкой;
NOT VERIFIED — проверка не выполнялась (устройство/подпись/живой обмен);
FAIL — не работает. Зелёная сборка не означает работающий перевод на iPhone.

| Возможность | Доказательство | Статус |
|---|---|---|
| Создание кошелька (seed 24 слова) | `roundtrip`: `wallet_lifecycle_offline`; CI run 40782071527 | PASS |
| Открытие кошелька, адрес | там же (`open` → `address`) | PASS |
| Восстановление из фразы (12/24 слова) | `restore_from_12_words`, `wallet_lifecycle_offline` | PASS |
| Восстановление funded-кошелька в чистом каталоге | скан `check_funded_balance`: 48.735 tGRIN, адрес совпал (2026-10-29) | PASS |
| Строгая сеть в FFI (нет mainnet по умолчанию) | `chain_type_is_strict`, `chain_genesis_is_strict` | PASS |
| Проверка genesis-блока ноды (FFI-часть) | `chain_genesis_is_strict`; UI `NodeProbe` — только компиляция | PASS (FFI) / NOT VERIFIED (устройство) |
| Точность сумм (9 знаков, overflow) | `amount_parse_is_exact`, `contract_fixtures_are_shared` | PASS |
| Этапы/действия перевода по общему контракту | `transfer_state_follows_shared_contract` | PASS |
| Журнал незавершённых переводов (перезапуск, повреждённый файл) | unit-тесты `PendingOperationsStoreTests` (run 40777444199) | PASS |
| Миграция Keychain (политика, контрольное чтение) | unit-тесты `KeychainStoreTests` (run 40777444199) | PASS (симулятор) / NOT VERIFIED (ACL на устройстве) |
| Блокировка входа (отказ не снимает замок) | `testLockStaysClosedWhenAuthenticationFails` | PASS (симулятор) |
| Полный перевод: send → receive → finalize → post → подтверждение | E2E run 40747893309 (1 tGRIN, 3 раунда) | PASS (FFI, testnet) |
| Возврат B→A и подтверждение | там же (0.975 tGRIN, 1 раунд) | PASS (FFI, testnet) |
| Баланс и история после перевода | E2E + скан 48.735 tGRIN | PASS (FFI) |
| Навигация по экранам | 10 XCUITest (run 40782071527) | PASS |
| QR-адрес, лист приёма по ссылке | `testScannerFallback`, `testIncomingSlatepackSheet` | PASS (симулятор) |
| Share Extension | `.appex` в PlugIns, `share-services` в CI | PASS (сборка) / NOT VERIFIED (устройство) |
| Отмена перевода | `cancel` через FFI-тест ошибок; UI-отмена не реализована | FAIL (UI) |
| Повторная публикация после сбоя post_tx | не реализовано (журнал 2 стадии) | FAIL |
| Комиссия до подтверждения от backend | `grin_wallet_estimate_fee` + live-тест: fee 23 500 000, total 1 023 500 000, баланс не списан | PASS (FFI) / FAIL (UI: fee tiers) |
| Состояние «баланс неизвестен» (offline/401) | баннер ошибки, но нули возможны | FAIL |
| Восстановление после прерывания (этапы) | текст этапов есть; продолжение не проверено на устройстве | NOT VERIFIED |
| Face ID/Touch ID, код устройства на устройстве | см. DEVICE_ACCEPTANCE D1 | NOT VERIFIED |
| Keychain после обновления/перезагрузки | DEVICE_ACCEPTANCE D2 | NOT VERIFIED |
| Системные прерывания, snapshot | DEVICE_ACCEPTANCE D3 | NOT VERIFIED |
| Камера/QR на устройстве | DEVICE_ACCEPTANCE D4 | NOT VERIFIED |
| Share Extension из сторонних приложений | DEVICE_ACCEPTANCE D5 | NOT VERIFIED |
| Мобильная сеть/LAN-нода | DEVICE_ACCEPTANCE D6 | NOT VERIFIED |
| Dynamic Type, VoiceOver, ресурсы | DEVICE_ACCEPTANCE D7 | NOT VERIFIED |
| Release archive для устройства | CI `device-archive`: GrinFlint.xcarchive.zip 11.6 MB, sha256 ff9a9443…, appex + arm64 внутри, BUILD-INFO (commit/Xcode) | PASS (без подписи) / подпись — локально |

## Вывод

`READY_FOR_EXTERNAL_DEVICE_TESTS` **не присваивается**: в таблице есть FAIL
(отмена, repost, комиссия от backend, состояние неизвестного баланса,
Release archive) и открытые внутренние пункты, которые нельзя переносить в
аппаратный список.
