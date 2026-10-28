//! C-обёртка (FFI) над grin-wallet v5.5.x.
//!
//! Все функции возвращают JSON-строку (`*mut c_char`, освобождается через
//! `grin_string_free`) либо NULL при ошибке — текст ошибки доступен через
//! `grin_last_error()`. Все вызовы `catch_unwind`-защищены.

use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::PathBuf;

use grin_wallet_api::{Foreign, Owner};
use grin_wallet_config::WalletConfig;
use grin_wallet_impls::{DefaultLCProvider, DefaultWalletImpl, HTTPNodeClient};
use grin_wallet_libwallet::{
    InitTxArgs, InitTxSendArgs, SlatepackAddress, WalletInst,
};
use grin_core::global::{self, ChainTypes};
use grin_keychain::ExtKeychain;
use grin_util::secp::key::SecretKey;
use grin_util::ZeroingString;
use serde_json::json;

type Lc = DefaultLCProvider<HTTPNodeClient, ExtKeychain>;
type WalletBox = Box<dyn WalletInst<'static, Lc, HTTPNodeClient, ExtKeychain>>;

pub struct GrinWallet {
    owner: Owner<Lc, HTTPNodeClient, ExtKeychain>,
    mask: Option<SecretKey>,
    config_path: PathBuf,
}

// ---------- ошибки ----------

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::new("").unwrap());
}

fn set_error(msg: String) {
    LAST_ERROR.with(|e| {
        *e.borrow_mut() = CString::new(msg).unwrap_or_else(|_| CString::new("unknown error").unwrap());
    });
}

fn c_str(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok().map(|s| s.to_owned())
}

fn ok_json(v: serde_json::Value) -> *mut c_char {
    match serde_json::to_string(&v)
        .ok()
        .and_then(|s| CString::new(s).ok())
    {
        Some(s) => s.into_raw(),
        None => {
            set_error("JSON encode failed".into());
            std::ptr::null_mut()
        }
    }
}

fn fail<T>() -> *mut T {
    std::ptr::null_mut()
}

/// catch_unwind с AssertUnwindSafe (сырые указатели не RefUnwindSafe).
fn guarded<T, F>(f: F) -> std::thread::Result<T>
where
    F: FnOnce() -> T,
{
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f))
}

/// Последняя ошибка (потоко-локальная копия). Не освобождать.
#[no_mangle]
pub extern "C" fn grin_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}

/// Освобождение строк, возвращённых функциями API.
#[no_mangle]
pub unsafe extern "C" fn grin_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

// ---------- создание / открытие ----------

/// Создать контекст кошелька (не открывает seed-файл).
/// chain: "mainnet" | "floonet". api_secret: NULL или пароль Basic Auth ноды
/// (например, для grinnode.live — см. https://grinnode.live).
#[no_mangle]
pub extern "C" fn grin_wallet_create(
    data_dir: *const c_char,
    node_url: *const c_char,
    chain: *const c_char,
    api_secret: *const c_char,
) -> *mut GrinWallet {
    let result = guarded(|| {
        let data_dir = c_str(data_dir).unwrap_or_else(|| ".".into());
        let node_url = c_str(node_url)
            .unwrap_or_else(|| "https://grinnode.live:3413".into());
        let chain = c_str(chain).unwrap_or_else(|| "mainnet".into());
        let api_secret = c_str(api_secret).filter(|s| !s.is_empty());

        let chain_type = match chain.as_str() {
            // В grin 5.5.2 тестовая сеть называется Testnet (бывш. Floonet)
            "testnet" | "floonet" => ChainTypes::Testnet,
            _ => ChainTypes::Mainnet,
        };
        global::set_local_chain_type(chain_type);

        let mut config = WalletConfig::default();
        config.data_file_dir = data_dir.clone();
        config.check_node_api_http_addr = node_url;
        config.chain_type = Some(chain_type);

        let node_client = HTTPNodeClient::new(
            &config.check_node_api_http_addr,
            api_secret,
            std::time::Duration::from_secs(30),
        )
        .map_err(|e| format!("node client: {e}"))?;

        // instantiate wallet (копия inst_wallet из CLI grin-wallet)
        let wallet_impl = DefaultWalletImpl::new(node_client.clone())
            .map_err(|e| format!("wallet impl: {e}"))?;
        let mut wallet: WalletBox = Box::new(wallet_impl) as WalletBox;
        let lc = wallet.lc_provider().map_err(|e| format!("lc: {e}"))?;
        let _ = lc.set_top_level_directory(&config.data_file_dir);

        // init_send_tx и ряд других вызовов читают конфиг из файла —
        // пишем дефолтный grin-wallet.toml, если его нет.
        let config_path = PathBuf::from(&config.data_file_dir).join("grin-wallet.toml");
        if !config_path.exists() {
            let toml_str = toml::to_string(&config)
                .map_err(|e| format!("config serialize: {e}"))?;
            std::fs::write(&config_path, toml_str)
                .map_err(|e| format!("config write {}: {e}", config_path.display()))?;
        }
        let owner = Owner::new(std::sync::Arc::new(grin_util::Mutex::new(wallet)), None, config_path.clone());
        Ok(GrinWallet { owner, mask: None, config_path })
    });
    match result {
        Ok(Ok(w)) => Box::into_raw(Box::new(w)),
        Ok(Err(e)) => {
            set_error(e);
            fail()
        }
        Err(_) => {
            set_error("panic in grin_wallet_create".into());
            fail()
        }
    }
}

/// Закрыть и освободить контекст.
#[no_mangle]
pub unsafe extern "C" fn grin_wallet_destroy(handle: *mut GrinWallet) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

/// Открыть кошелек паролем; возвращает {"address": <slatepack-адрес>}.
#[no_mangle]
pub extern "C" fn grin_wallet_open(handle: *mut GrinWallet, password: *const c_char) -> *mut c_char {
    let result = guarded(|| -> Result<serde_json::Value, String> {
        let w = unsafe { &mut *handle };
        let password = ZeroingString::from(c_str(password).ok_or("password is null")?);
        let mask = w
            .owner
            .open_wallet(None, password, false)
            .map_err(|e| format!("open_wallet: {e}"))?;
        w.mask = mask;
        let addr = w
            .owner
            .get_slatepack_address(w.mask.as_ref(), 0)
            .map_err(|e| format!("get_slatepack_address: {e}"))?;
        Ok(json!({ "address": addr.to_string() }))
    });
    match result {
        Ok(Ok(v)) => ok_json(v),
        Ok(Err(e)) => {
            set_error(e);
            fail()
        }
        Err(_) => {
            set_error("panic in grin_wallet_open".into());
            fail()
        }
    }
}

/// Создать новый кошелек; возвращает {"mnemonic": "..."}.
/// mnemonic = NULL — создать новый seed, иначе восстановить из фразы.
#[no_mangle]
pub extern "C" fn grin_wallet_create_seed(
    handle: *mut GrinWallet,
    password: *const c_char,
    mnemonic_length: u32,
    mnemonic: *const c_char,
) -> *mut c_char {
    let result = guarded(|| -> Result<serde_json::Value, String> {
        let w = unsafe { &mut *handle };
        let password = ZeroingString::from(c_str(password).ok_or("password is null")?);
        let mnemonic = c_str(mnemonic).map(ZeroingString::from);
        // В grin-wallet аргумент mnemonic_length у create_wallet — это
        // БАЙТЫ энтропии (32 байта = 256 бит = 24 слова; 16 = 128 бит = 12).
        // Снаружи (Swift/UI) принимаем количество СЛОВ и конвертируем.
        let entropy_bytes = match mnemonic_length {
            12 => 16,
            15 => 20,
            18 => 24,
            21 => 28,
            24 => 32,
            other => return Err(format!(
                "bad mnemonic_length {other}: use word count 12/15/18/21/24"
            )),
        };
        w.owner
            .create_wallet(None, mnemonic, entropy_bytes, password.clone())
            .map_err(|e| format!("create_wallet: {e}"))?;
        let mask = w
            .owner
            .open_wallet(None, password.clone(), false)
            .map_err(|e| format!("open_wallet: {e}"))?;
        w.mask = mask;
        let phrase = w
            .owner
            .get_mnemonic(None, password)
            .map_err(|e| format!("get_mnemonic: {e}"))?;
        Ok(json!({ "mnemonic": phrase.to_string() }))
    });
    match result {
        Ok(Ok(v)) => ok_json(v),
        Ok(Err(e)) => {
            set_error(e);
            fail()
        }
        Err(_) => {
            set_error("panic in grin_wallet_create_seed".into());
            fail()
        }
    }
}

// ---------- баланс / история ----------

/// Баланс {"spendable","awaiting","locked","total"} (наногрин).
/// refresh = 1 — сначала опросить ноду.
#[no_mangle]
pub extern "C" fn grin_wallet_balance(
    handle: *mut GrinWallet,
    refresh: i32,
) -> *mut c_char {
    let result = guarded(|| -> Result<serde_json::Value, String> {
        let w = unsafe { &mut *handle };
        if refresh == 1 {
            // Явная проверка ноды. Без неё grin-wallet при недоступной ноде
            // молча отдаёт баланс из локальной БД (выглядит как «пусто»),
            // а при 401 на foreign API — заниженный баланс. Пусть лучше
            // вернётся внятная ошибка, чем ложный ноль.
            //
            // node_height сам глотает сетевую ошибку и возвращает локальную
            // высоту с updated_from_node = false — проверяем этот флаг.
            let height = w
                .owner
                .node_height(w.mask.as_ref())
                .map_err(|e| format!("нода недоступна: {e}"))?;
            if !height.updated_from_node {
                return Err("нода недоступна: нет ответа get_chain_tip".into());
            }
        }
        let (_updated, info) = w
            .owner
            .retrieve_summary_info(w.mask.as_ref(), refresh == 1, 2)
            .map_err(|e| format!("retrieve_summary_info: {e}"))?;
        Ok(json!({
            "spendable": info.amount_currently_spendable,
            "awaiting": info.amount_awaiting_confirmation,
            "locked": info.amount_locked,
            "total": info.amount_currently_spendable
                + info.amount_awaiting_confirmation
                + info.amount_locked
                + info.amount_immature,
        }))
    });
    match result {
        Ok(Ok(v)) => ok_json(v),
        Ok(Err(e)) => {
            set_error(e);
            fail()
        }
        Err(_) => {
            set_error("panic in grin_wallet_balance".into());
            fail()
        }
    }
}

/// История транзакций: [{"id","type","status","amount","fee","message","creation_ts"}].
#[no_mangle]
pub extern "C" fn grin_wallet_txs(handle: *mut GrinWallet) -> *mut c_char {
    let result = guarded(|| -> Result<serde_json::Value, String> {
        let w = unsafe { &mut *handle };
        let (_updated, txs) = w
            .owner
            .retrieve_txs(w.mask.as_ref(), true, None, None, None)
            .map_err(|e| format!("retrieve_txs: {e}"))?;
        let list: Vec<serde_json::Value> = txs
            .iter()
            .map(|t| {
                let type_str = format!("{:?}", t.tx_type);
                let cancelled = type_str.contains("Cancelled") || type_str.contains("Reverted");
                let fee = t.fee.as_ref().map(|f| f.fee()).unwrap_or(0);
                // получено: credited; отправлено: debited минус комиссия
                let amount = if t.amount_credited > 0 {
                    t.amount_credited
                } else {
                    t.amount_debited.saturating_sub(fee)
                };
                json!({
                    "id": t.id,
                    "type": type_str,
                    "confirmed": t.confirmed && !cancelled,
                    "amount": amount,
                    "fee": fee,
                    "creation_ts": t.creation_ts.to_rfc3339(),
                    "slate_id": t.tx_slate_id.map(|u| u.to_string()),
                })
            })
            .collect();
        Ok(json!({ "txs": list }))
    });
    match result {
        Ok(Ok(v)) => ok_json(v),
        Ok(Err(e)) => {
            set_error(e);
            fail()
        }
        Err(_) => {
            set_error("panic in grin_wallet_txs".into());
            fail()
        }
    }
}

// ---------- транзакции ----------

/// Создать исходящую транзакцию; возвращает {"slatepack","slate_id","fee"}.
/// amount в наногринах, dest — slatepack-адрес получателя (grin1...).
///
/// Текста сообщения здесь нет намеренно: в grin-wallet 5.5.1 у slatepack нет
/// поля сообщения (из API оно удалено), и прежний параметр `message` молча
/// терялся. Текст, если он нужен, передаётся отдельным каналом.
#[no_mangle]
pub extern "C" fn grin_wallet_send(
    handle: *mut GrinWallet,
    amount_nanogrin: u64,
    dest: *const c_char,
) -> *mut c_char {
    let result = guarded(|| -> Result<serde_json::Value, String> {
        let w = unsafe { &mut *handle };
        let dest = c_str(dest).ok_or("dest is null")?;
        SlatepackAddress::try_from(dest.as_str()).map_err(|e| format!("bad dest: {e}"))?;

        let args = InitTxArgs {
            src_acct_name: None,
            amount: amount_nanogrin,
            amount_includes_fee: Some(false),
            minimum_confirmations: 2,
            max_outputs: 500,
            num_change_outputs: 1,
            selection_strategy_is_use_all: true,
            refresh_outputs_from_node: true,
            target_slate_version: None,
            ttl_blocks: None,
            payment_proof_recipient_address: None,
            estimate_only: Some(false),
            late_lock: Some(false),
            send_args: Some(InitTxSendArgs {
                dest: dest.clone(),
                post_tx: false,
                fluff: false,
                skip_tor: Some(true),
            }),
        };
        let slate = w
            .owner
            .init_send_tx(w.mask.as_ref(), args)
            .map_err(|e| format!("init_send_tx: {e}"))?;
        w.owner
            .tx_lock_outputs(w.mask.as_ref(), &slate)
            .map_err(|e| format!("tx_lock_outputs: {e}"))?;
        let fee = slate.fee_fields.fee();
        let recipient = SlatepackAddress::try_from(dest.as_str()).unwrap();
        let slatepack = w
            .owner
            .create_slatepack_message(w.mask.as_ref(), &slate, None, vec![recipient])
            .map_err(|e| format!("create_slatepack_message: {e}"))?;
        Ok(json!({
            "slatepack": slatepack,
            "slate_id": slate.id.to_string(),
            "fee": fee,
        }))
    });
    match result {
        Ok(Ok(v)) => ok_json(v),
        Ok(Err(e)) => {
            set_error(e);
            fail()
        }
        Err(_) => {
            set_error("panic in grin_wallet_send".into());
            fail()
        }
    }
}

/// Принять slatepack отправителя; возвращает {"slatepack": <ответ получателя>}.
#[no_mangle]
pub extern "C" fn grin_wallet_receive(
    handle: *mut GrinWallet,
    slatepack: *const c_char,
) -> *mut c_char {
    let result = guarded(|| -> Result<serde_json::Value, String> {
        let w = unsafe { &mut *handle };
        let slatepack = c_str(slatepack).ok_or("slatepack is null")?;

        let decoded = w
            .owner
            .decode_slatepack_message(w.mask.as_ref(), slatepack.clone(), vec![0, 1])
            .map_err(|e| format!("decode_slatepack_message: {e}"))?;
        let slate = w
            .owner
            .slate_from_slatepack_message(w.mask.as_ref(), slatepack, vec![0, 1])
            .map_err(|e| format!("slate_from_slatepack_message: {e}"))?;

        let foreign = Foreign::new(
            w.owner.wallet_inst.clone(),
            w.config_path.clone(),
            w.mask.clone(),
            None,
            false,
        );
        let slate_resp = foreign
            .receive_tx(&slate, None, None)
            .map_err(|e| format!("receive_tx: {e}"))?;

        let recipients: Vec<SlatepackAddress> = decoded.sender.into_iter().collect();
        let response = w
            .owner
            .create_slatepack_message(w.mask.as_ref(), &slate_resp, None, recipients)
            .map_err(|e| format!("create_slatepack_message: {e}"))?;
        Ok(json!({ "slatepack": response }))
    });
    match result {
        Ok(Ok(v)) => ok_json(v),
        Ok(Err(e)) => {
            set_error(e);
            fail()
        }
        Err(_) => {
            set_error("panic in grin_wallet_receive".into());
            fail()
        }
    }
}

/// Финализировать ответ получателя и отправить в сеть. 0 — ок, -1 — ошибка.
#[no_mangle]
pub extern "C" fn grin_wallet_finalize(
    handle: *mut GrinWallet,
    slatepack_response: *const c_char,
) -> i32 {
    let result = guarded(|| -> Result<(), String> {
        let w = unsafe { &mut *handle };
        let slatepack = c_str(slatepack_response).ok_or("slatepack is null")?;
        let slate = w
            .owner
            .slate_from_slatepack_message(w.mask.as_ref(), slatepack, vec![0, 1])
            .map_err(|e| format!("slate_from_slatepack_message: {e}"))?;
        let finalized = w
            .owner
            .finalize_tx(w.mask.as_ref(), &slate)
            .map_err(|e| format!("finalize_tx: {e}"))?;
        w.owner
            .post_tx(w.mask.as_ref(), &finalized, true)
            .map_err(|e| format!("post_tx: {e}"))?;
        Ok(())
    });
    match result {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            set_error(e);
            -1
        }
        Err(_) => {
            set_error("panic in grin_wallet_finalize".into());
            -1
        }
    }
}

/// Отмена неподтверждённой транзакции по slate_id (uuid-строка).
#[no_mangle]
pub extern "C" fn grin_wallet_cancel(handle: *mut GrinWallet, slate_id: *const c_char) -> i32 {
    let result = guarded(|| -> Result<(), String> {
        let w = unsafe { &mut *handle };
        let slate_id = c_str(slate_id).ok_or("slate_id is null")?;
        let uuid = uuid::Uuid::parse_str(&slate_id).map_err(|e| format!("bad uuid: {e}"))?;
        w.owner
            .cancel_tx(w.mask.as_ref(), None, Some(uuid))
            .map_err(|e| format!("cancel_tx: {e}"))?;
        Ok(())
    });
    match result {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            set_error(e);
            -1
        }
        Err(_) => {
            set_error("panic in grin_wallet_cancel".into());
            -1
        }
    }
}
