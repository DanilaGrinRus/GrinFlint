//! Стресс владения строками и освобождения памяти в FFI.
//!
//! Контракт: каждая возвращённая `*mut c_char` освобождается ровно один раз
//! через `grin_string_free`; `grin_last_error` — thread-local строка,
//! которую вызывающий НЕ освобождает. Двойное освобождение — UB по контракту,
//! поэтому оно не выполняется; проверяется, что одиночное освобождение
//! не портит контекст, ошибки и соседние строки.

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

fn unique_dir(tag: &str) -> String {
    let dir = std::env::temp_dir().join(format!("grinffi-mem-{tag}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("каталог");
    dir.to_string_lossy().into_owned()
}

/// Многократный цикл: каждая строка освобождается сразу, контекст жив.
#[test]
fn repeated_lifecycle_keeps_strings_valid() {
    for i in 0..5 {
        let dir = unique_dir(&format!("loop-{i}"));
        unsafe {
            let h = grin_wallet_create(
                cs(&dir).as_ptr(),
                cs("http://127.0.0.1:1").as_ptr(),
                cs("floonet").as_ptr(),
                ptr::null(),
            );
            assert!(!h.is_null(), "create #{i}: {}", last_error());

            let seed = take_string(grin_wallet_create_seed(
                h,
                cs("pass").as_ptr(),
                24,
                ptr::null(),
            ))
            .expect("create_seed");
            assert_eq!(seed.matches(' ').count() + 1, 24, "{seed}");

            let open =
                take_string(grin_wallet_open(h, cs("pass").as_ptr())).expect("open");
            assert!(open.contains("tgrin"), "{open}");

            for round in 0..5 {
                let bal = take_string(grin_wallet_balance(h, 0)).expect("balance");
                assert!(bal.contains("spendable"), "round {round}: {bal}");

                let txs = take_string(grin_wallet_txs(h)).expect("txs");
                assert!(txs.contains("txs"), "round {round}: {txs}");

                let amount =
                    take_string(grin_wallet_parse_amount(cs("0.000000001").as_ptr()))
                        .expect("parse_amount");
                assert!(amount.contains("\"nano\":1"), "{amount}");

                let state = take_string(grin_wallet_transfer_state(
                    cs("receive").as_ptr(),
                    cs("response_received").as_ptr(),
                    1,
                    1,
                    cs("tgrin1peer").as_ptr(),
                    cs("id-1").as_ptr(),
                    ptr::null(),
                ))
                .expect("transfer_state");
                assert!(state.contains("\"stage\":\"response_ready\""), "{state}");
            }

            grin_wallet_destroy(h);
        }
    }
}

/// Строки, созданные в другом потоке, освобождаются так же корректно;
/// ошибки в новом потоке не перетирают контекст основного.
#[test]
fn strings_are_owned_across_threads() {
    unsafe {
        let dir = unique_dir("thread");
        let h = grin_wallet_create(
            cs(&dir).as_ptr(),
            cs("http://127.0.0.1:1").as_ptr(),
            cs("floonet").as_ptr(),
            ptr::null(),
        );
        assert!(!h.is_null(), "create: {}", last_error());
        take_string(grin_wallet_create_seed(h, cs("pass").as_ptr(), 24, ptr::null()))
            .expect("create_seed");
        take_string(grin_wallet_open(h, cs("pass").as_ptr())).expect("open");

        let addr = h as usize;
        let worker = std::thread::spawn(move || {
            let h = addr as *mut GrinWallet;
            let bal = take_string(grin_wallet_balance(h, 0)).expect("balance в потоке");
            assert!(bal.contains("spendable"), "{bal}");
            let txs = take_string(grin_wallet_txs(h)).expect("txs в потоке");
            assert!(txs.contains("txs"), "{txs}");
            // Ошибку в потоке читаем, но не освобождаем (thread-local).
            let _ = last_error();
        });
        worker.join().expect("поток не упал");

        // Контекст после чужого потока по-прежнему работает.
        let bal = take_string(grin_wallet_balance(h, 0)).expect("balance после потока");
        assert!(bal.contains("spendable"), "{bal}");
        grin_wallet_destroy(h);
    }
}

/// `grin_last_error` — thread-local: повторное чтение стабильно,
/// освобождать её нельзя (проверяем только чтение).
#[test]
fn last_error_is_stable_and_not_freed() {
    unsafe {
        let p = grin_last_error();
        let first = if p.is_null() {
            String::new()
        } else {
            CStr::from_ptr(p).to_string_lossy().into_owned()
        };
        let p2 = grin_last_error();
        let second = if p2.is_null() {
            String::new()
        } else {
            CStr::from_ptr(p2).to_string_lossy().into_owned()
        };
        assert_eq!(first, second, "содержимое ошибки нестабильно");
    }
}

/// Освобождение NULL допустимо и не влияет на следующие вызовы.
#[test]
fn freeing_null_is_noop() {
    unsafe {
        grin_string_free(ptr::null_mut());
        let amount = take_string(grin_wallet_parse_amount(cs("1").as_ptr())).expect("amount");
        assert!(amount.contains("\"nano\":1000000000"), "{amount}");
        grin_wallet_destroy(ptr::null_mut());
    }
}