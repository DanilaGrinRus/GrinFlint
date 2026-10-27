# Документация GrinFlint (iOS)

**Точка входа для агентов/инструментов: [../../AGENTS.md](../../AGENTS.md)** —
текущее состояние, правила секретов, ловушки окружения, типовые задачи.

- [roadmap.md](roadmap.md) — дорожная карта по фазам (демо → FFI → безопасность → релиз) и риски
- [architecture.md](architecture.md) — слои приложения, контракты, конвенции
- [grin-wallet-integration.md](grin-wallet-integration.md) — контракт FFI; актуальная реализация
  см. в `ffi/grin-wallet-ffi/src/lib.rs` и `../../AGENTS.md` (раздел «C-API FFI»)

Проект: `../GrinFlintApp/GrinFlint.xcodeproj` · README проекта: `../GrinFlintApp/README.md`

Статус на 2026-10-27: FFI собран и проверен вживую (roundtrip 50 tGRIN
floonet), Face ID/автоблокировка написаны (сборка зелёная, на устройстве
не проверялись), UI пока на моке. Подробности — в `../../AGENTS.md`.
