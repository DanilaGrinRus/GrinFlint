//! Смоук-тест FFI на хосте (macOS-раннер в CI): жизненный цикл кошелька
//! без сети. Проверяет: создание seed, open (slatepack-адрес), баланс
//! (без обращения к ноде), корректность ошибки send без средств,
//! детерминированность восстановления (тот же адрес из той же фразы).

use grin_wallet_ffi::*;
use std::ffi::{c_char, CStr, CString};
use std::ptr;

fn cs(s: &str) -> CString {
    CString::new(s).expect("строка с NUL")
}

unsafe fn take_string(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = CStr::from_ptr(p).to_string_lossy().into_owned();
    grin_string_free(p);
    Some(s)
}

unsafe fn last_error() -> String {
    CStr::from_ptr(grin_last_error()).to_string_lossy().into_owned()
}

fn unique_dir(tag: &str) -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!(
        "grinffi-{}-{}-{}",
        tag,
        std::process::id(),
        nanos
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir.to_string_lossy().into_owned()
}

fn field(json: &str, name: &str) -> String {
    serde_json::from_str::<serde_json::Value>(json).unwrap()[name]
        .as_str()
        .unwrap_or_else(|| panic!("поле {name} не строка в {json}"))
        .to_owned()
}

#[test]
fn wallet_lifecycle_offline() {
    unsafe {
        // Мёртвый адрес ноды: сети в тесте нет, ошибки send ожидаемы.
        let node = "http://127.0.0.1:1";
        let dir_a = unique_dir("a");
        let h = grin_wallet_create(
            cs(&dir_a).as_ptr(),
            cs(node).as_ptr(),
            cs("floonet").as_ptr(),
            ptr::null(),
        );
        assert!(!h.is_null(), "grin_wallet_create: {}", last_error());

        // 1) новый seed — 24 слова
        let seed_json = take_string(grin_wallet_create_seed(
            h,
            cs("pass").as_ptr(),
            24,
            ptr::null(),
        ))
        .expect("create_seed вернул NULL");
        let mnemonic = field(&seed_json, "mnemonic");
        assert_eq!(
            mnemonic.split_whitespace().count(),
            24,
            "ожидалось 24 слова: {mnemonic}"
        );

        // 2) open → slatepack-адрес
        let open_json =
            take_string(grin_wallet_open(h, cs("pass").as_ptr())).expect("open вернул NULL");
        let address = field(&open_json, "address");
        assert!(
            address.len() > 10 && address.contains('1'),
            "подозрительный адрес: {address}"
        );

        // 3) баланс без обращения к ноде (refresh=0) — нули
        let bal_json = take_string(grin_wallet_balance(h, 0)).expect("balance вернул NULL");
        let bal: serde_json::Value = serde_json::from_str(&bal_json).unwrap();
        assert_eq!(bal["spendable"].as_u64().unwrap(), 0, "bal: {bal_json}");

        // 4) send без средств и с мёртвой нодой обязан упасть,
        //    но с понятной (непустой) ошибкой — это и есть проверка plumbing.
        let sent = grin_wallet_send(h, 1_000_000_000, cs(&address).as_ptr());
        assert!(sent.is_null(), "send не должен проходить в оффлайн-пустом кошельке");
        let err = last_error();
        assert!(!err.is_empty(), "ошибка send не должна быть пустой");
        println!("send error (ожидаемо): {err}");

        grin_wallet_destroy(h);

        // 5) восстановление из той же фразы → тот же адрес
        let dir_b = unique_dir("b");
        let h2 = grin_wallet_create(
            cs(&dir_b).as_ptr(),
            cs(node).as_ptr(),
            cs("floonet").as_ptr(),
            ptr::null(),
        );
        assert!(!h2.is_null(), "grin_wallet_create (b): {}", last_error());
        let rec_json = take_string(grin_wallet_create_seed(
            h2,
            cs("pass").as_ptr(),
            24,
            cs(&mnemonic).as_ptr(),
        ))
        .expect("restore create_seed вернул NULL");
        assert_eq!(field(&rec_json, "mnemonic"), mnemonic);
        let open2 =
            take_string(grin_wallet_open(h2, cs("pass").as_ptr())).expect("open (b) вернул NULL");
        let address2 = field(&open2, "address");
        assert_eq!(
            address, address2,
            "адрес после восстановления должен совпадать с исходным"
        );
        grin_wallet_destroy(h2);

        let _ = std::fs::remove_dir_all(&dir_a);
        let _ = std::fs::remove_dir_all(&dir_b);
    }
}

/// Восстановление кошелька из фразы в 12 слов (128 бит энтропии).
///
/// Снаружи FFI принимает число СЛОВ, внутри grin-wallet ждёт БАЙТЫ энтропии
/// (12 слов = 16 байт). Тест закрепляет и маппинг длины, и то, что из
/// 12-словной фразы восстанавливается тот же кошелёк (тот же slatepack-адрес).
#[test]
fn restore_from_12_words() {
    unsafe {
        let node = "http://127.0.0.1:1";

        // A: новый кошелёк на 12 слов
        let dir_a = unique_dir("w12a");
        let h_a = grin_wallet_create(
            cs(&dir_a).as_ptr(),
            cs(node).as_ptr(),
            cs("floonet").as_ptr(),
            ptr::null(),
        );
        assert!(!h_a.is_null(), "grin_wallet_create (12 слов, a): {}", last_error());

        let seed_json = take_string(grin_wallet_create_seed(
            h_a,
            cs("pass").as_ptr(),
            12,
            ptr::null(),
        ))
        .expect("create_seed (12 слов) вернул NULL");
        let mnemonic = field(&seed_json, "mnemonic");
        assert_eq!(
            mnemonic.split_whitespace().count(),
            12,
            "ожидалось 12 слов: {mnemonic}"
        );

        let open_json =
            take_string(grin_wallet_open(h_a, cs("pass").as_ptr())).expect("open (12 слов, a)");
        let address = field(&open_json, "address");
        grin_wallet_destroy(h_a);

        // B: восстановление из тех же 12 слов → тот же адрес
        let dir_b = unique_dir("w12b");
        let h_b = grin_wallet_create(
            cs(&dir_b).as_ptr(),
            cs(node).as_ptr(),
            cs("floonet").as_ptr(),
            ptr::null(),
        );
        assert!(!h_b.is_null(), "grin_wallet_create (12 слов, b): {}", last_error());

        let rec_json = take_string(grin_wallet_create_seed(
            h_b,
            cs("pass").as_ptr(),
            12,
            cs(&mnemonic).as_ptr(),
        ))
        .expect("create_seed (восстановление из 12 слов) вернул NULL");
        assert_eq!(
            field(&rec_json, "mnemonic"),
            mnemonic,
            "фраза после восстановления отличается от исходной"
        );

        let open2 = take_string(grin_wallet_open(h_b, cs("pass").as_ptr()))
            .expect("open (12 слов, b) вернул NULL");
        assert_eq!(
            address,
            field(&open2, "address"),
            "адрес из 12-словной фразы не совпал с исходным"
        );
        grin_wallet_destroy(h_b);

        let _ = std::fs::remove_dir_all(&dir_a);
        let _ = std::fs::remove_dir_all(&dir_b);
    }
}

/// FFI зовут с разных потоков (Swift actor): chain type в grin_core хранится
/// в thread-local. До фикса `open` на новом потоке паниковал
/// «GLOBAL_CHAIN_TYPE and CHAIN_TYPE unset» — на симуляторе это выглядело как
/// «Кошелёк не открылся: panic in grin_wallet_open».
#[test]
fn wallet_open_on_another_thread() {
    unsafe {
        let dir = unique_dir("threads");
        let node = "http://127.0.0.1:1";

        // Создание кошелька — на отдельном потоке.
        let created = std::thread::spawn({
            let dir = dir.clone();
            move || {
                let h = grin_wallet_create(
                    cs(&dir).as_ptr(),
                    cs(node).as_ptr(),
                    cs("floonet").as_ptr(),
                    ptr::null(),
                );
                assert!(!h.is_null(), "create (поток 1): {}", last_error());
                let seed = take_string(grin_wallet_create_seed(
                    h,
                    cs("pass").as_ptr(),
                    24,
                    ptr::null(),
                ))
                .expect("create_seed (поток 1) вернул NULL");
                (h as usize, seed)
            }
        })
        .join()
        .expect("поток создания запаниковал");

        let (handle, mnemonic) = created;
        let h = handle as *mut GrinWallet;

        // Открытие — на текущем (другом) потоке.
        let open = take_string(grin_wallet_open(h, cs("pass").as_ptr()));
        assert!(open.is_some(), "open на другом потоке: {}", last_error());
        let address = field(&open.unwrap(), "address");
        assert!(!address.is_empty(), "пустой адрес после open");

        grin_wallet_destroy(h);
        let _ = std::fs::remove_dir_all(&dir);
        drop(mnemonic);
    }
}

/// Сеть задаётся строго: NULL и неизвестная строка — ошибка, а не mainnet.
#[test]
fn chain_type_is_strict() {
    unsafe {
        let dir = unique_dir("chain");
        let url = cs("http://127.0.0.1:1");

        let h = grin_wallet_create(cs(&dir).as_ptr(), url.as_ptr(), ptr::null(), ptr::null());
        assert!(h.is_null(), "create без сети должен вернуть NULL");
        let err = last_error();
        assert!(err.contains("сеть"), "ошибка без сети: {err}");

        let h = grin_wallet_create(
            cs(&dir).as_ptr(),
            url.as_ptr(),
            cs("regtest").as_ptr(),
            ptr::null(),
        );
        assert!(h.is_null(), "create с неизвестной сетью должен вернуть NULL");
        let err = last_error();
        assert!(err.contains("regtest"), "ошибка с неизвестной сетью: {err}");

        let h = grin_wallet_create(
            cs(&dir).as_ptr(),
            url.as_ptr(),
            cs("testnet").as_ptr(),
            ptr::null(),
        );
        assert!(!h.is_null(), "create с testnet: {}", last_error());

        grin_wallet_destroy(h);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
/// Genesis-хеш сети: строгая сеть и разные хеши у mainnet/testnet.
#[test]
fn chain_genesis_is_strict() {
    unsafe {
        let p = grin_wallet_chain_genesis(cs("testnet").as_ptr());
        assert!(!p.is_null(), "chain_genesis(testnet): {}", last_error());
        let test = take_string(p).expect("ответ NULL");
        assert!(test.contains("\"chain\":\"testnet\""), "ответ: {test}");

        let p = grin_wallet_chain_genesis(cs("mainnet").as_ptr());
        assert!(!p.is_null(), "chain_genesis(mainnet): {}", last_error());
        let main = take_string(p).expect("ответ NULL");
        assert!(main.contains("\"chain\":\"mainnet\""), "ответ: {main}");
        assert_ne!(test, main, "genesis-хеши сетей не должны совпадать");

        let p = grin_wallet_chain_genesis(cs("regtest").as_ptr());
        assert!(p.is_null(), "неизвестная сеть должна вернуть NULL");
        assert!(last_error().contains("regtest"), "ошибка: {}", last_error());

        let p = grin_wallet_chain_genesis(ptr::null());
        assert!(p.is_null(), "NULL-сеть должна вернуть NULL");
    }
}