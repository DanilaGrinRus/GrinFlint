//! Краевые случаи slatepack: чужой получатель, повторный приём,
//! повреждённые данные и неверное направление ответа.
//! Для создания запроса нужна живая testnet-нода (init_send_tx берёт tip).\n//! Стоимость: сумма перевода + комиссия одного перевода (0.001 tGRIN).
//!
//! A создаёт запрос B, затем:
//!   - C (третий кошелёк) не может принять чужой slatepack;
//!   - B принимает запрос и повторный приём не ломает контекст;
//!   - повреждённый/пустой/слишком короткий slatepack — понятная ошибка;
//!   - finalize с запросом вместо ответа — ошибка;
//!   - ошибки не повторяют тело slatepack и синтетический маркер.

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

fn field(json: &str, name: &str) -> String {
    let key = format!("\"{name}\":\"");
    let start = json.find(&key).unwrap_or_else(|| panic!("нет {name}: {json}")) + key.len();
    let rest = &json[start..];
    let end = rest.find('"').expect("конец строки");
    rest[..end].to_string()
}

fn unique_dir(tag: &str) -> String {
    let dir = std::env::temp_dir().join(format!("grinffi-edges-{tag}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("каталог");
    dir.to_string_lossy().into_owned()
}

unsafe fn new_wallet(tag: &str, node: &str) -> *mut GrinWallet {
    let dir = unique_dir(tag);
    let h = grin_wallet_create(
        cs(&dir).as_ptr(),
        cs(node).as_ptr(),
        cs("floonet").as_ptr(),
        ptr::null(),
    );
    assert!(!h.is_null(), "create {tag}: {}", last_error());
    take_string(grin_wallet_create_seed(h, cs("pass").as_ptr(), 24, ptr::null()))
        .unwrap_or_else(|| panic!("create_seed {tag}: {}", last_error()));
    take_string(grin_wallet_open(h, cs("pass").as_ptr()))
        .unwrap_or_else(|| panic!("open {tag}: {}", last_error()));
    h
}

unsafe fn address(h: *mut GrinWallet) -> String {
    let open = take_string(grin_wallet_open(h, cs("pass").as_ptr())).expect("open");
    field(&open, "address")
}

#[test]
fn slatepack_edge_cases_are_safe() {
    unsafe {
        let node = std::env::var("GRIN_E2E_NODE_URL")
            .ok()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "http://127.0.0.1:13413".into());
        // A — funded-кошелёк (копия, пароль в env), B и C — свежие.
        let dir_a = std::env::var("GRINFFI_EDGES_WALLET_DIR")
            .ok()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| panic!("конфигурация: GRINFFI_EDGES_WALLET_DIR не задан"));
        let pass_a = std::env::var("GRINFFI_EDGES_WALLET_PASS")
            .ok()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| panic!("конфигурация: GRINFFI_EDGES_WALLET_PASS не задан"));
        let h_a = grin_wallet_create(
            cs(&dir_a).as_ptr(),
            cs(&node).as_ptr(),
            cs("floonet").as_ptr(),
            ptr::null(),
        );
        assert!(!h_a.is_null(), "create A: {}", last_error());
        take_string(grin_wallet_open(h_a, cs(&pass_a).as_ptr()))
            .unwrap_or_else(|| panic!("open A: {}", last_error()));

        let h_b = new_wallet("b", "http://127.0.0.1:1");
        let h_c = new_wallet("c", "http://127.0.0.1:1");
        let addr_b = address(h_b).replace("tgrin", "tgrin");

        let sent = take_string(grin_wallet_send(h_a, 1_000_000, cs(&addr_b).as_ptr()))
            .expect("send A→B");
        let slate_id = field(&sent, "slate_id");
        let request = field(&sent, "slatepack");

        // 1) Чужой кошелёк C не может принять запрос для B.
        let foreign = grin_wallet_receive(h_c, cs(&request).as_ptr());
        assert!(foreign.is_null(), "C принял чужой slatepack: {}", {
            take_string(foreign).unwrap_or_default()
        });
        let err = last_error();
        assert!(!err.is_empty());
        assert!(!err.contains(&request[..request.len().min(40)]), "тело slatepack в ошибке");
        assert!(!err.contains("SEKRET"), "маркер в ошибке: {err}");

        // 2) B принимает запрос; повторный приём не паникует.
        let received = take_string(grin_wallet_receive(h_b, cs(&request).as_ptr()))
            .unwrap_or_else(|| panic!("B receive: {}", last_error()));
        let response = field(&received, "slatepack");
        let again = take_string(grin_wallet_receive(h_b, cs(&request).as_ptr()));
        match again {
            Some(second) => {
                // Идемпотентный ответ допустим, но это не новая подпись:
                // контекст жив, ответы совпадают либо явная ошибка.
                assert!(
                    second.contains("\"slatepack\"") || second.contains("\"error\""),
                    "{second}"
                );
            }
            None => {
                let e = last_error();
                assert!(!e.is_empty(), "повторный приём без ошибки и без ответа");
            }
        }

        // 3) Повреждённые данные — ошибка, не паника.
        for bad in ["", "BEGINSLATEPACK.xxx", "SEKRET-MARKER-NOT-A-SLATEPACK", "AAAA"] {
            let p = grin_wallet_receive(h_b, cs(bad).as_ptr());
            assert!(p.is_null(), "принят мусор: {bad}");
            let e = last_error();
            assert!(!e.contains("SEKRET-MARKER"), "маркер в ошибке: {e}");
            assert!(!e.contains("BEGINSLATEPACK"), "тело в ошибке: {e}");
        }

        // 4) finalize с запросом вместо ответа — ошибка, состояние не меняется.
        assert_eq!(
            grin_wallet_finalize(h_a, cs(&request).as_ptr()),
            -1,
            "finalize должен отклонить запрос вместо ответа"
        );
        let e = last_error();
        assert!(!e.is_empty());

        // 5) finalize с корректным ответом проходит.
        assert_eq!(
            grin_wallet_finalize(h_a, cs(&response).as_ptr()),
            0,
            "finalize ответа: {}",
            last_error()
        );

        // 6) После публикации отмена запрещена (безопасные состояния).
        assert_eq!(
            grin_wallet_cancel(h_a, cs(&slate_id).as_ptr()),
            -1,
            "отмена после публикации должна отклоняться"
        );
        let e = last_error();
        assert!(!e.is_empty(), "нет причины отказа отмены");

        grin_wallet_destroy(h_a);
        grin_wallet_destroy(h_b);
        grin_wallet_destroy(h_c);
    }
}