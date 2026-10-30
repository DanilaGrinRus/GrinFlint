#!/usr/bin/env bash
# Живые UI-переводы с настоящим FFI на симуляторе macOS.
#
# Требуется:
#   * macOS с Xcode 16+;
#   * запущенная floonet-нода на 127.0.0.1:13413 (без Basic Auth на foreign
#     API — приложение не хранит секрет ноды);
#   * собранный XCFramework FFI (артефакт CI `GrinWalletFFI.xcframework`);
#   * симулятор iPhone.
#
# Запуск:
#   GRIN_E2E_SEED="24 слова" GRIN_E2E_RESTORE_HEIGHT=3295124 \
#     ./scripts/ui-e2e-macos.sh
#
# Прогоняются два теста:
#   1. repost после живого сбоя публикации (через локальный прокси, который
#      валит первый push_transaction);
#   2. обычный перевод без сбоя.
# Без GRIN_E2E_RESTORE_HEIGHT берётся tip − 20 000 (быстро, но подходит только
# для кошелька с недавними выходами). Пустое значение = полный скан.
set -euo pipefail

: "${GRIN_E2E_SEED:?Задайте GRIN_E2E_SEED (seed funded-кошелька, 24 слова)}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

XCF="${XCF_FRAMEWORK:-$ROOT/ffi-artifact/GrinWalletFFI.xcframework}"
if [ ! -d "$XCF" ]; then
    XCF="$ROOT/ffi/GrinWalletFFI.xcframework"
fi
[ -d "$XCF" ] || {
    echo "нет XCFramework FFI: соберите rust-ios в CI или укажите XCF_FRAMEWORK"
    exit 1
}
SIM_LIB=$(find "$XCF" -name 'libgrin_wallet_ffi.a' -path '*sim*' | head -1)
HEADERS=$(find "$XCF" -type d -name Headers | head -1)
[ -n "$SIM_LIB" ] && [ -n "$HEADERS" ] || {
    echo "в XCFramework нет библиотеки симулятора или заголовков"
    exit 1
}

NODE="${GRIN_E2E_NODE_URL:-http://127.0.0.1:13413}"
TIP_JSON=$(curl -s -X POST "$NODE/v2/foreign" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"get_tip"}')
if ! echo "$TIP_JSON" | grep -q '"Ok"'; then
    echo "нода $NODE недоступна или требует auth: $TIP_JSON"
    exit 1
fi
TIP=$(echo "$TIP_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["Ok"]["height"])')
RESTORE_HEIGHT="${GRIN_E2E_RESTORE_HEIGHT:-$((TIP - 20000))}"
echo "нода: $NODE, высота $TIP, restore height $RESTORE_HEIGHT"

DEVICE=$(xcrun simctl list devices available \
    | grep -m1 -E 'iPhone' \
    | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')
[ -n "$DEVICE" ] || {
    echo "доступный симулятор iPhone не найден"
    exit 1
}
echo "симулятор: $DEVICE"
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b

export TEST_RUNNER_GRIN_E2E_SEED="$GRIN_E2E_SEED"
export TEST_RUNNER_GRIN_E2E_NODE_URL="$NODE"
export TEST_RUNNER_GRIN_E2E_RESTORE_HEIGHT="$RESTORE_HEIGHT"
if [ -n "${GRIN_E2E_API_SECRET:-}" ]; then
    export TEST_RUNNER_GRIN_E2E_API_SECRET="$GRIN_E2E_API_SECRET"
fi

run_test() {
    local only="$1"
    local result="$2"
    # Чистый онбординг перед каждым тестом.
    xcrun simctl uninstall "$DEVICE" com.dan.grinflint || true
    xcodebuild test \
        -project GrinFlintApp/GrinFlint.xcodeproj \
        -scheme GrinFlint \
        -derivedDataPath "$PWD/build" \
        -destination "platform=iOS Simulator,id=$DEVICE" \
        -only-testing:"GrinFlintUITests/RealFFITransferUITests/$only" \
        -resultBundlePath "$PWD/$result" \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) GRINFFI' \
        SWIFT_OBJC_BRIDGING_HEADER="$PWD/GrinFlintApp/GrinFlint/Services/FFI/GrinWalletFFI-Bridging-Header.h" \
        HEADER_SEARCH_PATHS="$HEADERS" \
        OTHER_LDFLAGS="-L$(dirname "$SIM_LIB") -lgrin_wallet_ffi -framework Security -framework CoreFoundation -liconv"
}

# 1) Живой сбой публикации: прокси валит первый push_transaction.
PROXY_PORT="${GRIN_E2E_PROXY_PORT:-13414}"
python3 "$ROOT/scripts/floonet-post-fail-proxy.py" \
    --listen "$PROXY_PORT" --target "$NODE" --fail-broadcasts 1 \
    > /tmp/grinflint-post-fail-proxy.log 2>&1 &
PROXY_PID=$!
trap 'kill "$PROXY_PID" 2>/dev/null || true' EXIT
sleep 1
export TEST_RUNNER_GRIN_E2E_PROXY_URL="http://127.0.0.1:$PROXY_PORT"

run_test testRepostAfterPostFailureThroughUI repost.xcresult

kill "$PROXY_PID" 2>/dev/null || true
wait "$PROXY_PID" 2>/dev/null || true
unset TEST_RUNNER_GRIN_E2E_PROXY_URL

# 2) Обычный перевод без сбоя.
run_test testTransferThroughUIWithRealFFI transfer.xcresult
