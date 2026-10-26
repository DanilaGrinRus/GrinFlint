# GrinFlint

Некастодиальный кошелёк **Grin (Mimblewimble)** для iOS, с дизайном и UX по мотивам Flint Wallet.

## Стек

- SwiftUI, iOS 17+, Swift 5
- Архитектура: MVVM (`@Observable` ViewModel + сервисный слой)
- Без внешних зависимостей — клонируется и собирается как есть

## Сборка

1. Откройте `GrinFlint.xcodeproj` в Xcode 16+ на macOS.
2. Выберите схему **GrinFlint** и симулятор (например, iPhone 15).
3. `Product → Run` (⌘R). Bundle ID: `com.dan.grinflint`.

## Экраны

| Экран | Что умеет |
|---|---|
| Портфель | Баланс (доступно / в ожидании / заблокировано), отправка, получение, последние операции, обновление («добыча блока») |
| Отправить | Сумма, сообщение, тариф комиссии (1/2/3), генерация Slatepack, блокировка средств |
| Получить | Grin-адрес кошелька, приём входящего Slatepack с зачислением |
| Транзакции | История с группировкой по дням, детали, экспорт неотправленного Slatepack |
| Настройки | Нода, seed-фраза (демо), Face ID, информация о приложении |

## Демо-режим и путь к продакшену

Блокчейн-слой сейчас заменён `MockWalletService`: состояние в памяти,
Slatepack формируется корректным bech32 с HRP `grinslate`, но полезная
нагрузка не зашифрована и в сеть ничего не уходит.

Протокол `WalletService` (`Services/WalletService.swift`) — точка
интеграции. Для реального кошелька:

1. Соберите [grin-wallet](https://github.com/mimblewimble/grin-wallet)
   как статическую библиотеку для `aarch64-apple-ios`
   (`cargo build --release --target aarch64-apple-ios`), упакуйте в `.xcframework`.
2. Сгенерируйте C-header (cbindgen) для операций:
   `wallet_init`, `wallet_recover`, `tx_create`, `tx_finalize`,
   `slatepack_encrypt`, `slatepack_decrypt`, `scan_outputs`.
3. Реализуйте `WalletService` в `actor GrinWalletFFIService`, вызывая FFI.
   Все вызовы Rust выполняйте вне главного потока (уже асинхронно через `async`).
4. Храните seed и выходы в зашифрованном контейнере (Keychain + SQLCipher),
   аналогично Flint Wallet.

Важно: Grin — интерактивная монета (транзакция завершается совместно через
Slatepack). Для удобства добавьте в продакшене приём Slatepack по ссылке
(`grinslate:` URL scheme) и QR.

## Структура

```
GrinFlint/
├── GrinFlintApp.swift        # точка входа
├── ContentView.swift         # TabView (портфель / транзакции / настройки)
├── Theme.swift               # тёмная тема, фирменный жёлтый Grin
├── Models/
│   └── WalletModels.swift    # Balance, TransactionRecord, FeeTier, форматирование
├── Services/
│   ├── WalletService.swift   # протокол + MockWalletService (+ инструкция FFI)
│   ├── Bech32.swift          # кодировщик bech32 (BIP-0173)
│   └── SlatepackCodec.swift  # формат Slatepack-сообщений
├── ViewModels/
│   └── WalletViewModel.swift # @Observable состояние
└── Views/                    # PortfolioView, SendFlowView, ReceiveView,
                              # TransactionsView, TxDetailView, SettingsView
```
