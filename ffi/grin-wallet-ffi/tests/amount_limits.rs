//! Границы суммы и комиссии: точное списание, Max с комиссией, 9 знаков, u64.
//! Требует funded-кошелёк (копию) и живую testnet-ноду:
//!   GRINFFI_LIMITS_WALLET_DIR, GRINFFI_LIMITS_WALLET_PASS,
//!   GRIN_E2E_NODE_URL (default 127.0.0.1:13413), GRIN_E2E_API_SECRET.

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

fn field(json: &str, name: &str) -> u64 {
    let key = format!("\"{name}\":");
    let start = json.find(&key).unwrap_or_else(|| panic!("нет {name}: {json}")) + key.len();
    let rest = &json[start..];
    let end = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len());
    rest[..end].parse().unwrap_or_else(|_| panic!("{name}: {rest}"))
}

fn unique_dir(tag: &str) -> String {
    let dir = std::env::temp_dir().join(format!("grinffi-limits-{tag}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("каталог");
    dir.to_string_lossy().into_owned()
}

#[test]
fn amount_and_fee_boundaries() {
    let dir = std::env::var("GRINFFI_LIMITS_WALLET_DIR")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| panic!("конфигурация: GRINFFI_LIMITS_WALLET_DIR не задан"));
    let pass = std::env::var("GRINFFI_LIMITS_WALLET_PASS")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| panic!("конфигурация: GRINFFI_LIMITS_WALLET_PASS не задан"));
    let node = std::env::var("GRIN_E2E_NODE_URL")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "http://127.0.0.1:13413".into());
    let secret = std::env::var("GRIN_E2E_API_SECRET").ok().filter(|s| !s.is_empty());
    let secret_c = secret.as_deref().map(cs);

    unsafe {
        // --- точность разбора (без ноды) ---
        let one_nano = take_string(grin_wallet_parse_amount(cs("0.000000001").as_ptr()))
            .expect("parse 1 nano");
        assert!(one_nano.contains("\"nano\":1"), "{one_nano}");
        let max = take_string(grin_wallet_parse_amount(
            cs("18446744073.709551615").as_ptr(),
        ))
        .expect("parse u64 max");
        assert!(max.contains("18446744073709551615"), "{max}");
        assert!(
            grin_wallet_parse_amount(cs("18446744073.709551616").as_ptr()).is_null(),
            "переполнение u64 должно отклоняться"
        );
        assert!(
            grin_wallet_parse_amount(cs("1.0000000001").as_ptr()).is_null(),
            "10 знаков после точки должно отклоняться"
        );

        // --- границы на реальном кошельке ---
        let h = grin_wallet_create(
            cs(&dir).as_ptr(),
            cs(&node).as_ptr(),
            cs("floonet").as_ptr(),
            secret_c.as_ref().map(|s| s.as_ptr()).unwrap_or(ptr::null()),
        );
        assert!(!h.is_null(), "create: {}", last_error());
        let open = take_string(grin_wallet_open(h, cs(&pass).as_ptr())).expect("open");
        let key = "tgrin";
        let start = open.find(key).expect("адрес");
        let end = open[start..].find('"').expect("конец");
        let address = &open[start..start + end];

        let bal = take_string(grin_wallet_balance(h, 1)).expect("balance");
        let spendable = field(&bal, "spendable");
        eprintln!("spendable={spendable}");
        assert!(spendable > 0);

        // ровно весь баланс без учёта комиссии — отказ
        assert!(
            grin_wallet_estimate_fee(h, spendable, cs(address).as_ptr()).is_null(),
            "сумма = spendable должна отклоняться (комиссия сверху)"
        );
        let e_spendable = last_error();
        assert!(
            e_spendable.contains("недостаточно средств") && !e_spendable.contains("panic"),
            "ожидалась понятная ошибка: {e_spendable}"
        );
        // больше баланса — отказ
        assert!(
            grin_wallet_estimate_fee(h, spendable + 1, cs(address).as_ptr()).is_null(),
            "сумма > spendable должна отклоняться"
        );
        let e_over = last_error();
        assert!(
            e_over.contains("недостаточно средств") && !e_over.contains("panic"),
            "ожидалась понятная ошибка: {e_over}"
        );
        // u64::MAX — отказ без паники
        assert!(
            grin_wallet_estimate_fee(h, u64::MAX, cs(address).as_ptr()).is_null(),
            "u64::MAX должен отклоняться"
        );
        let e_max = last_error();
        assert!(
            e_max.contains("недостаточно средств") && !e_max.contains("panic"),
            "ожидалась понятная ошибка: {e_max}"
        );

        // реальная комиссия для 1 tGRIN
        let fee_json = take_string(grin_wallet_estimate_fee(h, 1_000_000_000, cs(address).as_ptr()))
            .expect("оценка 1 tGRIN");
        let fee = field(&fee_json, "fee");
        let total = field(&fee_json, "total");
        eprintln!("fee={fee}, total={total}");
        assert!(fee > 0, "{fee_json}");
        assert_eq!(total, 1_000_000_000 + fee);

        // Max = spendable - комиссия: сумма проходит, списание <= spendable
        let max_amount = spendable - fee;
        let max_json = take_string(grin_wallet_estimate_fee(h, max_amount, cs(address).as_ptr()))
            .expect("оценка Max");
        let max_total = field(&max_json, "total");
        eprintln!("max_amount={max_amount}, max_total={max_total}");
        assert!(
            max_total <= spendable,
            "Max с комиссией превысил баланс: {max_total} > {spendable}"
        );

        // На единицу больше Max — отказ
        assert!(
            grin_wallet_estimate_fee(h, max_amount + 1, cs(address).as_ptr()).is_null(),
            "сумма Max+1 должна отклоняться"
        );
        let e_max1 = last_error();
        assert!(
            !e_max1.contains("panic"),
            "Max+1 не должен приводить к панике: {e_max1}"
        );

        // Оценки ничего не списывают и не блокируют.
        let after = take_string(grin_wallet_balance(h, 0)).expect("balance after");
        assert_eq!(field(&after, "spendable"), spendable);
        assert_eq!(field(&after, "locked"), 0);

        grin_wallet_destroy(h);
    }
}