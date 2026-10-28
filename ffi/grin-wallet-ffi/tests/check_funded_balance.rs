//! Диагностика: баланс кошелька из GRIN_E2E_SEED_FUNDED против живой ноды.
//! Запуск (локально, seed только из env):
//!   GRIN_E2E_NODE_URL=http://127.0.0.1:13413 \
//!   GRIN_E2E_API_SECRET=$(cat ~/.grin/test/.api_secret) \
//!   GRIN_E2E_SEED_FUNDED="24 слова..." \
//!   cargo test --test check_funded_balance -- --nocapture
//! Без env тест пропускается.

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
    // grin_last_error() отдаёт указатель на thread-local строку: освобождать
    // его через grin_string_free нельзя (двойное освобождение).
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
fn funded_balance() {
    // Диагностический прогон без seed — ошибка конфигурации, а не «ok».
    let seed = match std::env::var("GRIN_E2E_SEED_FUNDED") {
        Ok(s) if !s.is_empty() => s,
        _ => panic!("конфигурация: GRIN_E2E_SEED_FUNDED не задан — проверка баланса не выполнялась"),
    };
    let node = std::env::var("GRIN_E2E_NODE_URL").unwrap_or_else(|_| "127.0.0.1:13413".into());
    let secret = std::env::var("GRIN_E2E_API_SECRET").ok();

    let dir = std::env::temp_dir().join("grinffi-balance-check");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();

    unsafe {
        let secret_c = secret.as_deref().map(cs);
        let h = grin_wallet_create(
            cs(dir.to_str().unwrap()).as_ptr(),
            cs(&node).as_ptr(),
            cs("floonet").as_ptr(),
            secret_c
                .as_ref()
                .map(|s| s.as_ptr())
                .unwrap_or(ptr::null()),
        );
        assert!(!h.is_null(), "create: {}", last_error());
        let j = take_string(grin_wallet_create_seed(h, cs("pw").as_ptr(), 24, cs(&seed).as_ptr()))
            .unwrap_or_else(|| panic!("create_seed: {}", last_error()));
        drop(j);
        let open = take_string(grin_wallet_open(h, cs("pw").as_ptr()))
            .unwrap_or_else(|| panic!("open: {}", last_error()));
        println!("open: {open}");
        let bal = take_string(grin_wallet_balance(h, 1))
            .unwrap_or_else(|| panic!("balance: {}", last_error()));
        println!("balance: {bal}");
        grin_wallet_destroy(h);
    }
}
