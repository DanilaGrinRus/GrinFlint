//! Локальная проверка оценки комиссии от настоящего backend.
//!
//! Требует данные существующего кошелька (не коммитятся):
//!   GRINFFI_FEE_WALLET_DIR  — каталог с wallet_data (копия!)
//!   GRINFFI_FEE_WALLET_PASS — пароль кошелька
//!   GRIN_E2E_NODE_URL       — живая testnet-нода (default 127.0.0.1:13413)
//!   GRIN_E2E_API_SECRET     — секрет ноды, если нужен
//!
//! Без обязательных переменных — ошибка конфигурации, не PASS.

use grin_wallet_ffi::*;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

fn cs(s: &str) -> CString {
    CString::new(s).expect("CString")
}

unsafe fn last_error() -> String {
    let p = grin_last_error();
    if p.is_null() {
        return "<нет ошибки>".into();
    }
    CStr::from_ptr(p).to_string_lossy().into_owned()
}

unsafe fn take_string(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = CStr::from_ptr(p).to_string_lossy().into_owned();
    grin_string_free(p);
    Some(s)
}

#[test]
fn fee_estimate_comes_from_backend() {
    let dir = match std::env::var("GRINFFI_FEE_WALLET_DIR") {
        Ok(s) if !s.is_empty() => s,
        _ => panic!("конфигурация: GRINFFI_FEE_WALLET_DIR не задан"),
    };
    let pass = match std::env::var("GRINFFI_FEE_WALLET_PASS") {
        Ok(s) if !s.is_empty() => s,
        _ => panic!("конфигурация: GRINFFI_FEE_WALLET_PASS не задан"),
    };
    let node = std::env::var("GRIN_E2E_NODE_URL")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "http://127.0.0.1:13413".into());
    let secret = std::env::var("GRIN_E2E_API_SECRET").ok().filter(|s| !s.is_empty());
    let secret_c = secret.as_deref().map(cs);

    unsafe {
        let h = grin_wallet_create(
            cs(&dir).as_ptr(),
            cs(&node).as_ptr(),
            cs("floonet").as_ptr(),
            secret_c.as_ref().map(|s| s.as_ptr()).unwrap_or(ptr::null()),
        );
        assert!(!h.is_null(), "create: {}", last_error());

        let open = take_string(grin_wallet_open(h, cs(&pass).as_ptr())).expect("open");
        let address = open
            .split('"')
            .skip_while(|p| !p.contains("tgrin"))
            .next()
            .unwrap_or_else(|| panic!("адрес не найден: {open}"))
            .to_string();

        let amount: u64 = 1_000_000_000;
        let estimate = take_string(grin_wallet_estimate_fee(h, amount, cs(&address).as_ptr()))
            .expect("estimate_fee");
        let json: serde_json::Value = serde_json::from_str(&estimate).expect("json");
        let fee = json["fee"].as_u64().expect("fee");
        let total = json["total"].as_u64().expect("total");
        eprintln!("оценка: fee={fee}, total={total}");
        assert!(fee > 0, "комиссия должна быть получена от backend: {estimate}");
        assert_eq!(total, amount + fee, "итог = сумма + комиссия: {estimate}");

        // Оценка не блокирует средства: баланс не меняется (spendable).
        let bal = take_string(grin_wallet_balance(h, 0)).expect("balance");
        let bal_json: serde_json::Value = serde_json::from_str(&bal).expect("json");
        let spendable = bal_json["spendable"].as_u64().unwrap_or(0);
        eprintln!("spendable после оценки: {spendable}");
        assert!(spendable >= amount, "оценка не должна списывать средства: {bal}");

        grin_wallet_destroy(h);
    }
}