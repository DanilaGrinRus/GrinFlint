//! E2E-тест: полный roundtrip tGRIN в тестнете между двумя кошельками.
//!
//! Сценарий (соответствует критерию выхода Фазы 1 роадмапа):
//!   A (funded) → send → slatepack → B.receive → response → A.finalize+post
//!   → ждём подтверждения → у B spendable > 0.
//!
//! Запускается только когда заданы env-переменные (в обычном CI смоук-прогоне
//! тест компилируется, но пропускается):
//!   GRIN_E2E_NODE_URL       — адрес ноды (default http://127.0.0.1:3413)
//!   GRIN_E2E_API_SECRET     — Basic Auth секрет ноды (optional)
//!   GRIN_E2E_SEED_FUNDED    — seed-фраза кошелька A (24 слова, через пробел)
//!   GRIN_E2E_SEED_B         — seed-фраза кошелька B; если не задана — B создаётся
//!                             новым и фраза сохраняется в GRIN_E2E_SEED_B_OUT
//!   GRIN_E2E_SEED_B_OUT     — файл для записи фразы нового кошелька B
//!   GRIN_E2E_CONFIRM_ROUNDS — лимит опроса подтверждения (default 24 × 20 c)
//!   GRIN_E2E_AMOUNT_NGRIN   — сумма перевода в наногрин (default 1 tGRIN)
//!
//! ВНИМАНИЕ: seed-фразы читаются только из env и никогда не печатаются
//! (в т.ч. в сообщениях assert'ов) — правило «seed не попадает в логи».

use grin_wallet_ffi::*;
use std::ffi::{c_char, CStr, CString};
use std::ptr;

fn cs(s: &str) -> CString {
    CString::new(s).expect("строка с NUL")
}

unsafe fn take_string(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = CStr::from_ptr(p).to_string_lossy().into_owned();
    grin_string_free(p);
    Some(s)
}

unsafe fn last_error() -> String {
    CStr::from_ptr(grin_last_error()).to_string_lossy().into_owned()
}

fn unique_dir(tag: &str) -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!(
        "grine2e-{}-{}-{}",
        tag,
        std::process::id(),
        nanos
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir.to_string_lossy().into_owned()
}

fn field(json: &str, name: &str) -> String {
    serde_json::from_str::<serde_json::Value>(json).unwrap()[name]
        .as_str()
        .unwrap_or_else(|| panic!("поле {name} не строка"))
        .to_owned()
}

fn bal(json: &str, name: &str) -> u64 {
    serde_json::from_str::<serde_json::Value>(json).unwrap()[name]
        .as_u64()
        .unwrap_or_else(|| panic!("поле {name} не u64"))
}

#[test]
fn floonet_roundtrip_send_receive() {
    let seed_funded = match std::env::var("GRIN_E2E_SEED_FUNDED") {
        Ok(s) if !s.is_empty() => s,
        _ => {
            eprintln!("GRIN_E2E_SEED_FUNDED не задан — E2E пропущен");
            return;
        }
    };
    let node_url =
        std::env::var("GRIN_E2E_NODE_URL").unwrap_or_else(|_| "http://127.0.0.1:3413".into());
    let api_secret = std::env::var("GRIN_E2E_API_SECRET").ok().filter(|s| !s.is_empty());
    let seed_b = std::env::var("GRIN_E2E_SEED_B").ok().filter(|s| !s.is_empty());
    let seed_b_out = std::env::var("GRIN_E2E_SEED_B_OUT").ok().filter(|s| !s.is_empty());
    let rounds: u32 = std::env::var("GRIN_E2E_CONFIRM_ROUNDS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(24);
    // Сумма перевода. Комиссия платится сверху, поэтому сумма обязана быть
    // меньше баланса A: при сумме, равной балансу, send падает
    // «Insufficient funds» (Required = сумма + комиссия). По умолчанию 1 tGRIN —
    // одного пополнения на 50 tGRIN хватает примерно на 49 прогонов.
    const AMOUNT_DEFAULT: u64 = 1_000_000_000; // 1 tGRIN
    // Запас на комиссию за 1 вход / 2 выхода: 0.0125 tGRIN.
    const FEE_HEADROOM: u64 = 12_500_000;
    let amount: u64 = std::env::var("GRIN_E2E_AMOUNT_NGRIN")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(AMOUNT_DEFAULT);
    const PASSWORD: &str = "e2e-test-password";

    // A — funded-кошелёк (восстановление из env-фразы)
    let dir_a = unique_dir("a");
    let node = cs(&node_url);
    let chain = cs("floonet");
    let secret_a = api_secret.as_deref().map(cs);
    let h_a = unsafe {
        let h = grin_wallet_create(
            cs(&dir_a).as_ptr(),
            node.as_ptr(),
            chain.as_ptr(),
            secret_a
                .as_ref()
                .map(|s| s.as_ptr())
                .unwrap_or(ptr::null()),
        );
        assert!(!h.is_null(), "grin_wallet_create (a): {}", last_error());
        let j = take_string(grin_wallet_create_seed(
            h,
            cs(PASSWORD).as_ptr(),
            24,
            cs(&seed_funded).as_ptr(),
        ))
        .unwrap_or_else(|| panic!("create_seed (a) вернул NULL: {}", last_error()));
        drop(j);
        let open = take_string(grin_wallet_open(h, cs(PASSWORD).as_ptr()))
            .unwrap_or_else(|| panic!("open (a) вернул NULL: {}", last_error()));
        drop(open);
        h
    };

    // B — либо восстановленный, либо новый (фраза сохраняется в seed_b_out)
    let dir_b = unique_dir("b");
    let node_b = cs(&node_url);
    let chain_b = cs("floonet");
    let secret_b = api_secret.as_deref().map(cs);
    let (h_b, mnemonic_b, address_b) = unsafe {
        let h = grin_wallet_create(
            cs(&dir_b).as_ptr(),
            node_b.as_ptr(),
            chain_b.as_ptr(),
            secret_b
                .as_ref()
                .map(|s| s.as_ptr())
                .unwrap_or(ptr::null()),
        );
        assert!(!h.is_null(), "grin_wallet_create (b): {}", last_error());
        let mnemonic_b_c = seed_b.as_deref().map(cs);
        let j = take_string(grin_wallet_create_seed(
            h,
            cs(PASSWORD).as_ptr(),
            24,
            mnemonic_b_c
                .as_ref()
                .map(|s| s.as_ptr())
                .unwrap_or(ptr::null()),
        ))
        .unwrap_or_else(|| panic!("create_seed (b) вернул NULL: {}", last_error()));
        let mnemonic = field(&j, "mnemonic");
        if let Some(out_path) = &seed_b_out {
            std::fs::write(out_path, &mnemonic)
                .unwrap_or_else(|e| panic!("запись seed-фразы (b): {e}"));
        }
        let open = take_string(grin_wallet_open(h, cs(PASSWORD).as_ptr()))
            .unwrap_or_else(|| panic!("open (b) вернул NULL: {}", last_error()));
        let address = field(&open, "address");
        (h, mnemonic, address)
    };

    // 1) A: баланс с обновлением от ноды — должны быть средства
    let bal_a = unsafe {
        take_string(grin_wallet_balance(h_a, 1))
            .unwrap_or_else(|| panic!("balance (a, refresh) вернул NULL: {}", last_error()))
    };
    let spendable_a = bal(&bal_a, "spendable");
    assert!(
        spendable_a >= amount + FEE_HEADROOM,
        "недостаточно средств на A: spendable {spendable_a}, нужно {amount} + комиссия {FEE_HEADROOM}"
    );

    // 2) A: send → slatepack
    eprintln!("перевод {amount} наногрин (комиссия сверху)");
    let sent = unsafe {
        take_string(grin_wallet_send(
            h_a,
            amount,
            cs(&address_b).as_ptr(),
            cs("grinflint e2e transfer").as_ptr(),
        ))
        .unwrap_or_else(|| panic!("send вернул NULL: {}", last_error()))
    };
    let slatepack = field(&sent, "slatepack");
    assert!(
        slatepack.starts_with("BEGINSLATEPACK"),
        "slatepack не начинается с BEGINSLATEPACK"
    );

    // 3) B: receive → ответ
    let received = unsafe {
        take_string(grin_wallet_receive(h_b, cs(&slatepack).as_ptr()))
            .unwrap_or_else(|| panic!("receive вернул NULL: {}", last_error()))
    };
    let response = field(&received, "slatepack");
    assert!(
        response.starts_with("BEGINSLATEPACK"),
        "ответ получателя не slatepack"
    );

    // 4) A: finalize + post в ноду
    let rc = grin_wallet_finalize(h_a, cs(&response).as_ptr());
    assert_eq!(rc, 0, "finalize/post: {}", unsafe { last_error() });

    // 5) ждём подтверждения у B (awaiting → spendable)
    let mut confirmed = false;
    for i in 1..=rounds {
        std::thread::sleep(std::time::Duration::from_secs(20));
        let bal_b = unsafe {
            take_string(grin_wallet_balance(h_b, 1))
                .unwrap_or_else(|| panic!("balance (b, раунд {i}) вернул NULL: {}", last_error()))
        };
        let spendable = bal(&bal_b, "spendable");
        if spendable >= amount {
            eprintln!("подтверждено за {i} раунд(ов): B spendable = {spendable}");
            confirmed = true;
            break;
        }
        if i % 3 == 0 {
            eprintln!("раунд {i}: B spendable = {spendable}, ждём…");
        }
    }
    assert!(confirmed, "транзакция не подтвердилась за {rounds} раундов");

    unsafe {
        grin_wallet_destroy(h_a);
        grin_wallet_destroy(h_b);
    }
    let _ = std::fs::remove_dir_all(&dir_a);
    let _ = std::fs::remove_dir_all(&dir_b);
    let _ = mnemonic_b; // фраза B не печатается; сохранена в seed_b_out, если задан
}
