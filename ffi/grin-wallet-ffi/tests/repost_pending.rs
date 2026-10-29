//! Локальная проверка повторной публикации без повторной подписи.
//!
//! Требует funded-кошелёк (копию!) и живую testnet-ноду:
//!   GRINFFI_REPOST_WALLET_DIR, GRINFFI_REPOST_WALLET_PASS,
//!   GRIN_E2E_NODE_URL (default 127.0.0.1:13413), GRIN_E2E_API_SECRET.
//!
//! Сценарий: A отправляет B, B отвечает, A финализирует (подпись + публикация).
//! Подписанная tx сохраняется в <data>/repost/<slate_id>.json ДО post_tx;
//! повторный вызов repost публикует ровно её, без новых подписей.
//! Стоимость прогона — сумма перевода + комиссия (тестнет).

use grin_wallet_ffi::*;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::Path;
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

fn field(json: &str, name: &str) -> String {
    let key = format!("\"{name}\":\"");
    let start = json.find(&key).unwrap_or_else(|| panic!("нет {name}: {json}")) + key.len();
    let rest = &json[start..];
    let end = rest.find('"').expect("конец строки");
    rest[..end].to_string()
}

fn unique_dir(tag: &str) -> String {
    let dir = std::env::temp_dir().join(format!("grinffi-repost-{tag}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("каталог");
    dir.to_string_lossy().into_owned()
}

fn tx_count(h: *mut GrinWallet) -> usize {
    unsafe {
        let txs = take_string(grin_wallet_txs(h)).expect("txs");
        let json: serde_json::Value = serde_json::from_str(&txs).expect("json");
        json["txs"].as_array().map(|a| a.len()).unwrap_or(0)
    }
}

#[test]
fn repost_publishes_same_signed_tx() {
    let dir_a = match std::env::var("GRINFFI_REPOST_WALLET_DIR") {
        Ok(s) if !s.is_empty() => s,
        _ => panic!("конфигурация: GRINFFI_REPOST_WALLET_DIR не задан"),
    };
    let pass_a = match std::env::var("GRINFFI_REPOST_WALLET_PASS") {
        Ok(s) if !s.is_empty() => s,
        _ => panic!("конфигурация: GRINFFI_REPOST_WALLET_PASS не задан"),
    };
    let node = std::env::var("GRIN_E2E_NODE_URL")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "http://127.0.0.1:13413".into());
    let secret = std::env::var("GRIN_E2E_API_SECRET").ok().filter(|s| !s.is_empty());
    let secret_c = secret.as_deref().map(cs);
    let dir_b = unique_dir("b");

    unsafe {
        let h_a = grin_wallet_create(
            cs(&dir_a).as_ptr(),
            cs(&node).as_ptr(),
            cs("floonet").as_ptr(),
            secret_c.as_ref().map(|s| s.as_ptr()).unwrap_or(ptr::null()),
        );
        assert!(!h_a.is_null(), "create A: {}", last_error());
        let open_a = take_string(grin_wallet_open(h_a, cs(&pass_a).as_ptr())).expect("open A");
        let addr_a = field(&open_a, "address");
        assert!(addr_a.starts_with("tgrin"), "{addr_a}");

        let h_b = grin_wallet_create(
            cs(&dir_b).as_ptr(),
            cs("http://127.0.0.1:1").as_ptr(),
            cs("floonet").as_ptr(),
            ptr::null(),
        );
        assert!(!h_b.is_null(), "create B: {}", last_error());
        take_string(grin_wallet_create_seed(h_b, cs("pass").as_ptr(), 24, ptr::null()))
            .expect("seed B");
        let open_b = take_string(grin_wallet_open(h_b, cs("pass").as_ptr())).expect("open B");
        let addr_b = field(&open_b, "address");

        // 1) A → B: подписанный запрос.
        let sent = take_string(grin_wallet_send(h_a, 1_000_000, cs(&addr_b).as_ptr()))
            .unwrap_or_else(|| panic!("send: {}", last_error()));
        let slate_id = field(&sent, "slate_id");
        let request = field(&sent, "slatepack");
        eprintln!("send: slate_id={slate_id}");

        // 2) B отвечает.
        let received = take_string(grin_wallet_receive(h_b, cs(&request).as_ptr()))
            .unwrap_or_else(|| panic!("receive B: {}", last_error()));
        let response = field(&received, "slatepack");

        // 3) A финализирует и публикует; подписанная tx сохраняется на диск.
        assert_eq!(
            grin_wallet_finalize(h_a, cs(&response).as_ptr()),
            0,
            "finalize: {}",
            last_error()
        );
        let stored = Path::new(&dir_a).join("repost").join(format!("{slate_id}.json"));
        assert!(stored.exists(), "нет сохранённой tx: {}", stored.display());
        let stored_bytes = std::fs::read(&stored).expect("read stored");
        assert!(stored_bytes.len() > 100, "подозрительно маленький slate json");

        let before = tx_count(h_a);
        assert!(before > 0, "ожидалась хотя бы одна tx");

        // 4) Повторная публикация: либо нода принимает, либо сообщает,
        //    что tx уже известна — в обоих случаях это та же подпись.
        let rc = grin_wallet_repost(h_a, cs(&slate_id).as_ptr());
        let err = if rc == 0 { "<нет>".into() } else { last_error() };
        eprintln!("repost: rc={rc}, error={err}");
        if rc != 0 {
            let lower = err.to_lowercase();
            assert!(
                lower.contains("post_tx")
                    || lower.contains("already")
                    || lower.contains("mempool")
                    || lower.contains("known")
                    || lower.contains("существ"),
                "неожиданная ошибка repost: {err}"
            );
        }

        // Файл подписанной tx не изменился — повторной подписи не было.
        let after_bytes = std::fs::read(&stored).expect("read stored again");
        assert_eq!(stored_bytes, after_bytes, "сохранённая tx изменилась");
        // Новая транзакция не появилась.
        assert_eq!(tx_count(h_a), before, "repost создал новую транзакцию");

        // 5) Неизвестный slate_id — понятная ошибка.
        let unknown = uuid::Uuid::new_v4().to_string();
        assert_eq!(grin_wallet_repost(h_a, cs(&unknown).as_ptr()), -1);
        let e = last_error();
        assert!(e.contains("нет сохранённой"), "{e}");

        // 6) Повреждённый файл — ошибка, а не паника.
        let bad_id = uuid::Uuid::new_v4().to_string();
        let bad_path = Path::new(&dir_a).join("repost").join(format!("{bad_id}.json"));
        std::fs::write(&bad_path, "{ это не slate }").expect("write bad");
        assert_eq!(grin_wallet_repost(h_a, cs(&bad_id).as_ptr()), -1);
        let e = last_error();
        assert!(e.contains("повреждена"), "{e}");

        grin_wallet_destroy(h_a);
        grin_wallet_destroy(h_b);
    }
}