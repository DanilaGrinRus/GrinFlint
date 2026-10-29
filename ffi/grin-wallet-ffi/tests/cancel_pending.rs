//! Локальная проверка безопасной отмены: send блокирует средства,
//! cancel по slate_id снимает блокировку и переводит tx в canceled.
//!
//! Требует данные кошелька (копию!) и живую testnet-ноду:
//!   GRINFFI_CANCEL_WALLET_DIR, GRINFFI_CANCEL_WALLET_PASS,
//!   GRIN_E2E_NODE_URL (default 127.0.0.1:13413), GRIN_E2E_API_SECRET.
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
fn cancel_releases_locked_funds() {
    let dir = match std::env::var("GRINFFI_CANCEL_WALLET_DIR") {
        Ok(s) if !s.is_empty() => s,
        _ => panic!("конфигурация: GRINFFI_CANCEL_WALLET_DIR не задан"),
    };
    let pass = match std::env::var("GRINFFI_CANCEL_WALLET_PASS") {
        Ok(s) if !s.is_empty() => s,
        _ => panic!("конфигурация: GRINFFI_CANCEL_WALLET_PASS не задан"),
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

        // Обновление с ноды до блокировки.
        let before = take_string(grin_wallet_balance(h, 1)).expect("balance before");
        let before_json: serde_json::Value = serde_json::from_str(&before).expect("json");
        let spendable_before = before_json["spendable"].as_u64().unwrap_or(0);
        eprintln!("spendable до: {spendable_before}");
        assert!(spendable_before > 0, "нужен funded-кошелёк: {before}");

        // Небольшая отправка: блокирует средства.
        let amount: u64 = 1_000_000; // 0.001 tGRIN
        let sent = take_string(grin_wallet_send(h, amount, cs(&address).as_ptr()))
            .unwrap_or_else(|| panic!("send: {}", last_error()));
        let sent_json: serde_json::Value = serde_json::from_str(&sent).expect("json");
        let slate_id = sent_json["slate_id"].as_str().expect("slate_id").to_string();
        let fee = sent_json["fee"].as_u64().unwrap_or(0);
        eprintln!("send: slate_id={slate_id}, fee={fee}");

        let locked = take_string(grin_wallet_balance(h, 0)).expect("balance after send");
        let locked_json: serde_json::Value = serde_json::from_str(&locked).expect("json");
        let spendable_locked = locked_json["spendable"].as_u64().unwrap_or(0);
        let locked_amount = locked_json["locked"].as_u64().unwrap_or(0);
        eprintln!(
            "после send (refresh=0): spendable={spendable_locked}, locked={locked_amount}"
        );
        // send с selection_strategy use_all блокирует все выходы.
        assert!(
            spendable_locked < spendable_before || locked_amount > 0,
            "средства должны быть заблокированы: {locked}"
        );

        // Безопасная отмена.
        assert_eq!(
            grin_wallet_cancel(h, cs(&slate_id).as_ptr()),
            0,
            "cancel: {}",
            last_error()
        );

        let txs = take_string(grin_wallet_txs(h)).expect("txs");
        eprintln!("txs: {}", &txs[..txs.len().min(400)]);
        assert!(
            txs.to_lowercase().contains("cancel"),
            "ожидался статус canceled: {txs}"
        );

        // Средства разблокированы.
        let after = take_string(grin_wallet_balance(h, 1)).expect("balance after cancel");
        let after_json: serde_json::Value = serde_json::from_str(&after).expect("json");
        let spendable_after = after_json["spendable"].as_u64().unwrap_or(0);
        let locked_after = after_json["locked"].as_u64().unwrap_or(0);
        eprintln!(
            "после cancel: spendable={spendable_after}, locked={locked_after}"
        );
        assert_eq!(locked_after, 0, "после отмены не должно быть блокировок: {after}");
        assert!(
            spendable_after >= amount + fee,
            "средства отменённой отправки должны быть доступны: {after}"
        );

        grin_wallet_destroy(h);
    }
}