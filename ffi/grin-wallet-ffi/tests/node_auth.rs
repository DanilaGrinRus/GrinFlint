//! Авторизация ноды доходит до реальных запросов.
//!
//! Поднимает локальный HTTP-сервер, который требует Basic Auth и отвечает
//! 401. Проверяет, что api_secret попадает в заголовок
//! `Authorization: Basic base64("grin:<secret>")`, а без секрета заголовка нет.

use grin_wallet_ffi::*;
use std::ffi::{CStr, CString};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::raw::c_char;
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

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
    let dir = std::env::temp_dir().join(format!("grinffi-auth-{tag}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("каталог");
    dir.to_string_lossy().into_owned()
}

/// Мини-сервер: собирает заголовки Authorization и всегда отвечает 401.
fn spawn_auth_probe() -> (u16, Arc<AtomicBool>, Arc<std::sync::atomic::AtomicUsize>, std::thread::JoinHandle<Vec<String>>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().expect("addr").port();
    listener.set_nonblocking(true).expect("nonblocking");
    let stop = Arc::new(AtomicBool::new(false));
    let stop_thread = stop.clone();
    let conns = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let conns_thread = conns.clone();
    let handle = std::thread::spawn(move || {
        let mut captured = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(30);
        while !stop_thread.load(Ordering::Relaxed) && Instant::now() < deadline {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    conns_thread.fetch_add(1, Ordering::Relaxed);
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                    let mut buf = [0u8; 16384];
                    let mut request = Vec::new();
                    // читаем до конца заголовков
                    loop {
                        match stream.read(&mut buf) {
                            Ok(0) => break,
                            Ok(n) => {
                                request.extend_from_slice(&buf[..n]);
                                if request.windows(4).any(|w| w == b"\r\n\r\n") {
                                    break;
                                }
                            }
                            Err(_) => break,
                        }
                    }
                    let text = String::from_utf8_lossy(&request);
                    for line in text.lines() {
                        if line.to_ascii_lowercase().starts_with("authorization:") {
                            captured.push(line.trim().to_string());
                        }
                    }
                    let _ = stream.write_all(
                        b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                    );
                }
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(_) => break,
            }
        }
        captured
    });
    (port, stop, conns, handle)
}

fn base64(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in input.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(TABLE[((n >> 18) & 63) as usize] as char);
        out.push(TABLE[((n >> 12) & 63) as usize] as char);
        out.push(if chunk.len() > 1 { TABLE[((n >> 6) & 63) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { TABLE[(n & 63) as usize] as char } else { '=' });
    }
    out
}

fn touch_node(secret: Option<&str>, tag: &str) -> (usize, Vec<String>) {
    let (port, stop, conns, probe) = spawn_auth_probe();
    let dir = unique_dir(tag);
    let node = format!("http://127.0.0.1:{port}");
    let secret_c = secret.map(cs);
    unsafe {
        let h = grin_wallet_create(
            cs(&dir).as_ptr(),
            cs(&node).as_ptr(),
            cs("floonet").as_ptr(),
            secret_c.as_ref().map(|s| s.as_ptr()).unwrap_or(ptr::null()),
        );
        assert!(!h.is_null(), "create: {}", last_error());
        take_string(grin_wallet_create_seed(h, cs("pass").as_ptr(), 24, ptr::null()))
            .unwrap_or_else(|| panic!("create_seed: {}", last_error()));
        take_string(grin_wallet_open(h, cs("pass").as_ptr()))
            .unwrap_or_else(|| panic!("open: {}", last_error()));
        // refresh=1 ходит на ноду; сервер отвечает 401.
        let bal = grin_wallet_balance(h, 1);
        let err = last_error();
        eprintln!("balance_null={}, error={err}", bal.is_null());
        let _ = take_string(bal);
        assert!(!err.is_empty() || bal.is_null());
        take_string(grin_wallet_parse_amount(cs("1").as_ptr())).expect("parse_amount");
        grin_wallet_destroy(h);
    }
    std::thread::sleep(Duration::from_millis(150));
    stop.store(true, Ordering::Relaxed);
    let headers = probe.join().expect("probe");
    (conns.load(Ordering::Relaxed), headers)
}

#[test]
fn api_secret_reaches_node_requests() {
    let secret = "s3cr3t-pass";
    let (connections, seen) = touch_node(Some(secret), "with");
    assert!(connections > 0, "нода не получила ни одного запроса");
    let expected = format!("Basic {}", base64(format!("grin:{secret}").as_bytes()));
    assert!(
        seen.iter().any(|h| h.eq_ignore_ascii_case(&format!("authorization: {expected}"))),
        "ожидался заголовок {expected}, получено: {seen:?}"
    );
}

#[test]
fn no_secret_means_no_authorization_header() {
    let (connections, seen) = touch_node(None, "without");
    assert!(connections > 0, "нода не получила ни одного запроса");
    assert!(
        seen.is_empty(),
        "без api_secret заголовок Authorization не должен отправляться: {seen:?}"
    );
}