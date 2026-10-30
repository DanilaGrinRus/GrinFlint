//! Полный цикл на кошельке, восстановленном из seed в ЧИСТОМ каталоге:
//! адрес совпадает с исходным, полный скан находит средства, перевод
//! подтверждается в сети. Старая копия БД для этого не годится (фантомные
//! выходы), поэтому используется restore.
//!
//! Env: GRINFFI_CYCLE_SEED (фраза), GRINFFI_CYCLE_PASS,
//! GRIN_E2E_NODE_URL (default 127.0.0.1:13413), GRIN_E2E_API_SECRET,
//! GRINFFI_CYCLE_EXPECT_ADDRESS (опционально), GRINFFI_CYCLE_AMOUNT_NGRIN,
//! GRINFFI_CYCLE_RESTORE_HEIGHT (опционально; 0 — скан с генезиса).
//! Без обязательных переменных — ошибка конфигурации, не PASS.

use grin_wallet_ffi::*;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
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
    let start = json.find(&key).unwrap_or_else(|| panic!("нет {name} в ответе")) + key.len();
    let rest = &json[start..];
    let end = rest.find('"').expect("конец строки");
    rest[..end].to_string()
}

fn field_u64(json: &str, name: &str) -> u64 {
    let key = format!("\"{name}\":");
    let start = json.find(&key).unwrap_or_else(|| panic!("нет {name} в ответе")) + key.len();
    let rest = &json[start..];
    let end = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len());
    rest[..end].parse().unwrap_or_else(|_| panic!("{name}: {rest}"))
}

fn unique_dir(tag: &str) -> String {
    let dir = std::env::temp_dir().join(format!("grinffi-cycle-{tag}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("каталог");
    dir.to_string_lossy().into_owned()
}

fn balance(h: *mut GrinWallet) -> (u64, u64) {
    unsafe {
        let bal = take_string(grin_wallet_balance(h, 1)).expect("balance");
        (field_u64(&bal, "spendable"), field_u64(&bal, "locked"))
    }
}

fn tx_confirmed(h: *mut GrinWallet, slate_id: &str) -> bool {
    unsafe {
        let txs = take_string(grin_wallet_txs(h)).expect("txs");
        let json: serde_json::Value = serde_json::from_str(&txs).expect("json");
        json["txs"]
            .as_array()
            .map(|list| {
                list.iter().any(|t| {
                    t["slate_id"].as_str() == Some(slate_id)
                        && t["confirmed"].as_bool() == Some(true)
                })
            })
            .unwrap_or(false)
    }
}

#[test]
fn restore_clean_dir_then_confirmed_transfer() {
    let seed = match std::env::var("GRINFFI_CYCLE_SEED") {
        Ok(s) if !s.is_empty() => s,
        _ => panic!("конфигурация: GRINFFI_CYCLE_SEED не задан"),
    };
    let pass = match std::env::var("GRINFFI_CYCLE_PASS") {
        Ok(s) if !s.is_empty() => s,
        _ => panic!("конфигурация: GRINFFI_CYCLE_PASS не задан"),
    };
    let node = std::env::var("GRIN_E2E_NODE_URL")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "http://127.0.0.1:13413".into());
    let secret = std::env::var("GRIN_E2E_API_SECRET").ok().filter(|s| !s.is_empty());
    let secret_c = secret.as_deref().map(cs);
    let amount: u64 = std::env::var("GRINFFI_CYCLE_AMOUNT_NGRIN")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(1_000_000);
    let expect_address = std::env::var("GRINFFI_CYCLE_EXPECT_ADDRESS").ok();
    // 0 — полный скан с генезиса; иначе скан начинается с этой высоты.
    let restore_height: u64 = std::env::var("GRINFFI_CYCLE_RESTORE_HEIGHT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);

    let dir_a = unique_dir("a");
    let dir_b = unique_dir("b");

    unsafe {
        // --- 1) восстановление из фразы в чистый каталог ---
        let h_a = grin_wallet_create(
            cs(&dir_a).as_ptr(),
            cs(&node).as_ptr(),
            cs("floonet").as_ptr(),
            secret_c.as_ref().map(|s| s.as_ptr()).unwrap_or(ptr::null()),
        );
        assert!(!h_a.is_null(), "create: {}", last_error());

        // JSON с mnemonic не печатаем и не сохраняем.
        eprintln!("restore_height={restore_height}");
        let restored = take_string(grin_wallet_create_seed_at(
            h_a,
            cs(&pass).as_ptr(),
            24,
            cs(&seed).as_ptr(),
            restore_height,
        ));
        assert!(restored.is_some(), "restore: {}", last_error());

        let open = take_string(grin_wallet_open(h_a, cs(&pass).as_ptr()))
            .unwrap_or_else(|| panic!("open: {}", last_error()));
        let address = field(&open, "address");
        eprintln!("адрес восстановленного кошелька совпадает: {}", address.starts_with("tgrin"));
        if let Some(expected) = expect_address.as_deref().filter(|s| !s.is_empty()) {
            assert_eq!(address, expected, "адрес восстановленного кошелька не совпал");
        }

        // --- 2) полный скан: ждём появления средств ---
        let mut spendable = 0;
        for round in 1..=40 {
            let (s, locked) = balance(h_a);
            eprintln!("скан {round}: spendable={s}, locked={locked}");
            spendable = s;
            if s > 0 {
                break;
            }
            std::thread::sleep(Duration::from_secs(15));
        }
        assert!(spendable > 0, "средства не найдены после восстановления");

        let balance_json = take_string(grin_wallet_balance(h_a, 1))
            .unwrap_or_else(|| panic!("balance refresh: {}", last_error()));
        let balance_value: serde_json::Value =
            serde_json::from_str(&balance_json).expect("balance json");
        assert_eq!(
            balance_value["fresh"], true,
            "нода не подтвердила обновление состояния: {balance_json}"
        );

        // --- 3) B и перевод ---
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

        let sent = take_string(grin_wallet_send(h_a, amount, cs(&addr_b).as_ptr()))
            .unwrap_or_else(|| panic!("send: {}", last_error()));
        let slate_id = field(&sent, "slate_id");
        let request = field(&sent, "slatepack");
        eprintln!("send: slate_id={slate_id}");

        let received = take_string(grin_wallet_receive(h_b, cs(&request).as_ptr()))
            .unwrap_or_else(|| panic!("receive B: {}", last_error()));
        let response = field(&received, "slatepack");

        // Двухфазная финализация: prepare подписывает и сохраняет Slate,
        // статус подтверждает, что файл для repost на месте, repost публикует.
        let prepared = take_string(grin_wallet_finalize_prepare(h_a, cs(&response).as_ptr()))
            .unwrap_or_else(|| panic!("finalize_prepare: {}", last_error()));
        assert_eq!(field(&prepared, "slate_id"), slate_id, "slate_id не совпал");
        let status = take_string(grin_wallet_transfer_status(h_a, cs(&slate_id).as_ptr()))
            .unwrap_or_else(|| panic!("transfer_status: {}", last_error()));
        let value: serde_json::Value = serde_json::from_str(&status).expect("status json");
        assert_eq!(value["found"], true, "{status}");
        assert_eq!(
            value["has_repost"], true,
            "подписанный Slate не сохранён: {status}"
        );
        eprintln!("status после prepare: {status}");
        assert_eq!(
            grin_wallet_repost(h_a, cs(&slate_id).as_ptr()),
            0,
            "repost: {}",
            last_error()
        );

        // --- 4) подтверждение в сети ---
        let mut confirmed = false;
        for round in 1..=40 {
            if tx_confirmed(h_a, &slate_id) {
                eprintln!("подтверждено за {round} раунд(ов)");
                confirmed = true;
                break;
            }
            std::thread::sleep(Duration::from_secs(10));
        }
        assert!(confirmed, "перевод не подтвердился за 400 с");

        // --- 5) после подтверждения отмена запрещена ---
        assert_eq!(
            grin_wallet_cancel(h_a, cs(&slate_id).as_ptr()),
            -1,
            "отмена подтверждённой транзакции должна отклоняться"
        );
        let err = last_error();
        assert!(!err.is_empty());

        grin_wallet_destroy(h_a);
        grin_wallet_destroy(h_b);
    }
}