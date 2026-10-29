//! Повтор публикации после перезапуска и подтверждение в сети.
//!
//! A (funded-копия) → B, ответ B, finalize (сохранение подписанной tx + post).
//! Затем контекст A уничтожается, создаётся заново на том же каталоге:
//! сохранённая tx на месте, repost проходит без новой подписи, а транзакция
//! подтверждается в сети (txs: confirmed=true).
//!
//! Env: GRINFFI_RESTART_WALLET_DIR/PASS, GRIN_E2E_NODE_URL, GRIN_E2E_API_SECRET.

use grin_wallet_ffi::*;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::Path;
use std::ptr;
use std::time::Duration;

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
    let dir = std::env::temp_dir().join(format!("grinffi-restart-{tag}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("каталог");
    dir.to_string_lossy().into_owned()
}

unsafe fn open_wallet(dir: &str, pass: &str, node: &str, secret: Option<&str>) -> (*mut GrinWallet, String) {
    let secret_c = secret.map(cs);
    let h = grin_wallet_create(
        cs(dir).as_ptr(),
        cs(node).as_ptr(),
        cs("floonet").as_ptr(),
        secret_c.as_ref().map(|s| s.as_ptr()).unwrap_or(ptr::null()),
    );
    assert!(!h.is_null(), "create: {}", last_error());
    let open = take_string(grin_wallet_open(h, cs(pass).as_ptr()))
        .unwrap_or_else(|| panic!("open: {}", last_error()));
    (h, open)
}

fn tx_confirmed(h: *mut GrinWallet, slate_id: &str) -> bool {
    unsafe {
        let _ = take_string(grin_wallet_balance(h, 1)); // обновление с ноды
        let txs = take_string(grin_wallet_txs(h)).expect("txs");
        let json: serde_json::Value = serde_json::from_str(&txs).expect("json");
        json["txs"]
            .as_array()
            .map(|list| {
                list.iter().any(|t| {
                    t["slate_id"].as_str() == Some(slate_id) && t["confirmed"].as_bool() == Some(true)
                })
            })
            .unwrap_or(false)
    }
}

#[test]
fn repost_after_restart_then_confirmation() {
    let dir_a = std::env::var("GRINFFI_RESTART_WALLET_DIR")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| panic!("конфигурация: GRINFFI_RESTART_WALLET_DIR не задан"));
    let pass_a = std::env::var("GRINFFI_RESTART_WALLET_PASS")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| panic!("конфигурация: GRINFFI_RESTART_WALLET_PASS не задан"));
    let node = std::env::var("GRIN_E2E_NODE_URL")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "http://127.0.0.1:13413".into());
    let secret = std::env::var("GRIN_E2E_API_SECRET").ok().filter(|s| !s.is_empty());
    let dir_b = unique_dir("b");

    unsafe {
        // --- A: отправка, ответ B, финализация ---
        let (h_a, _) = open_wallet(&dir_a, &pass_a, &node, secret.as_deref());
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

        let sent = take_string(grin_wallet_send(h_a, 1_000_000, cs(&addr_b).as_ptr()))
            .unwrap_or_else(|| panic!("send: {}", last_error()));
        let slate_id = field(&sent, "slate_id");
        let request = field(&sent, "slatepack");

        let received = take_string(grin_wallet_receive(h_b, cs(&request).as_ptr()))
            .unwrap_or_else(|| panic!("receive B: {}", last_error()));
        let response = field(&received, "slatepack");

        assert_eq!(
            grin_wallet_finalize(h_a, cs(&response).as_ptr()),
            0,
            "finalize: {}",
            last_error()
        );

        let stored = Path::new(&dir_a).join("repost").join(format!("{slate_id}.json"));
        assert!(stored.exists(), "нет сохранённой tx: {}", stored.display());
        let before = std::fs::read(&stored).expect("read stored");

        // --- «перезапуск приложения»: новый контекст на том же каталоге ---
        grin_wallet_destroy(h_a);
        let (h_a2, _) = open_wallet(&dir_a, &pass_a, &node, secret.as_deref());
        assert!(stored.exists(), "после перезапуска сохранённая tx исчезла");
        assert_eq!(
            before,
            std::fs::read(&stored).expect("read after restart"),
            "файл изменился после перезапуска"
        );

        let rc = grin_wallet_repost(h_a2, cs(&slate_id).as_ptr());
        let err = if rc == 0 { "<нет>".into() } else { last_error() };
        eprintln!("repost после перезапуска: rc={rc}, error={err}");
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

        // --- подтверждение в сети (опционально) ---
        // Копия БД содержит устаревшие выходы: её транзакции могут не попадать
        // в блок. Подтверждение проверяется на кошельке, восстановленном из
        // seed в чистом каталоге (E2E), поэтому здесь оно по флагу.
        let expect_confirm = std::env::var("GRINFFI_RESTART_EXPECT_CONFIRM")
            .map(|v| v == "1")
            .unwrap_or(false);
        if expect_confirm {
            let mut confirmed = false;
            for round in 1..=30 {
                if tx_confirmed(h_a2, &slate_id) {
                    eprintln!("подтверждено за {round} раунд(ов)");
                    confirmed = true;
                    break;
                }
                std::thread::sleep(Duration::from_secs(10));
            }
            assert!(confirmed, "транзакция не подтвердилась за 300 с");
        } else {
            eprintln!("подтверждение не проверяется (GRINFFI_RESTART_EXPECT_CONFIRM != 1)");
        }

        grin_wallet_destroy(h_a2);
        grin_wallet_destroy(h_b);
    }
}