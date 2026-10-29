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
    InitTxArgs, InitTxSendArgs, Slate, SlateState, SlatepackAddress, WalletInst,
};
use grin_core::core::hash::Hashed;
use grin_core::genesis;
use grin_core::global::{self, ChainTypes};

/// Общий контракт переводов (тот же исходник, что у desktop, schema 1).
pub use flint_transfer_contract;
use flint_transfer_contract::{Direction, NanoGrin, Network, Stage, TransferState};
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
    /// Сеть этого кошелька. grin_core хранит chain type в thread-local +
    /// глобально; FFI зовут с разных потоков (Swift actor), поэтому перед
    /// каждым вызовом выставляем thread-local заново.
    chain_type: ChainTypes,
}

// ---------- ошибки ----------

/// Проверка указателя на контекст: NULL — ошибка, а не разыменование.
fn wallet_mut<'a>(handle: *mut GrinWallet) -> Result<&'a mut GrinWallet, String> {
    // SAFETY: NULL отсекается до разыменования; ссылка живёт только на время
    // вызова FFI-функции.
    unsafe { handle.as_mut() }.ok_or_else(|| "handle is null".into())
}

/// Каталог сохранённых подписанных транзакций для повторной публикации.
fn repost_dir(w: &GrinWallet) -> std::path::PathBuf {
    w.config_path
        .parent()
        .unwrap_or_else(|| std::path::Path::new("."))
        .join("repost")
}

/// Сохраняет уже подписанную транзакцию ДО публикации: при сбое сети её
/// можно опубликовать повторно без повторной подписи.
fn store_repost_slate(w: &GrinWallet, slate: &Slate) -> Result<(), String> {
    let dir = repost_dir(w);
    std::fs::create_dir_all(&dir).map_err(|e| format!("каталог {}: {e}", dir.display()))?;
    let path = dir.join(format!("{}.json", slate.id));
    let json = serde_json::to_string(slate).map_err(|e| format!("сериализация tx: {e}"))?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json).map_err(|e| format!("запись {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("переименование {}: {e}", path.display()))?;
    Ok(())
}

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::new("").unwrap());
    static PANIC_MSG: RefCell<String> = RefCell::new(String::new());
}

fn set_error(msg: String) {
    LAST_ERROR.with(|e| {
        *e.borrow_mut() = CString::new(msg).unwrap_or_else(|_| CString::new("unknown error").unwrap());
    });
}

/// Один раз ставим hook, который запоминает текст паники в thread-local:
/// без него в Swift приходит только «panic in grin_wallet_x».
fn install_panic_hook() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let text = if let Some(s) = info.payload().downcast_ref::<&str>() {
                (*s).to_string()
            } else if let Some(s) = info.payload().downcast_ref::<String>() {
                s.clone()
            } else {
                "panic без текста".to_string()
            };
            let location = info
                .location()
                .map(|l| format!(" ({}:{})", l.file(), l.line()))
                .unwrap_or_default();
            PANIC_MSG.with(|m| *m.borrow_mut() = format!("{text}{location}"));
            previous(info);
        }));
    });
}

fn panic_message() -> String {
    PANIC_MSG.with(|m| m.borrow().clone())
}

fn panic_error(context: &str) -> String {
    let detail = panic_message();
    if detail.is_empty() {
        format!("panic in {context}")
    } else {
        format!("panic in {context}: {detail}")
    }
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
    install_panic_hook();
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
        // Сеть задаётся явно: отсутствующая или неизвестная строка — ошибка,
        // а не молчаливый mainnet (для кошелька это разные деньги).
        let chain = c_str(chain).ok_or_else(|| {
            "сеть не задана: ожидается \"mainnet\", \"testnet\" или \"floonet\"".to_string()
        })?;
        let api_secret = c_str(api_secret).filter(|s| !s.is_empty());

        // Сеть разбирает общий контракт: неизвестная строка — ошибка,
        // mainnet не выбирается молча.
        let network = Network::parse(&chain).map_err(|_| {
            format!("неизвестная сеть «{chain}»: ожидается \"mainnet\", \"testnet\" или \"floonet\"")
        })?;
        let chain_type = match network {
            Network::Testnet => ChainTypes::Testnet,
            Network::Mainnet => ChainTypes::Mainnet,
        };
        // thread-local — для текущего потока, глобальный — чтобы не паниковать
        // при вызове с другого потока (см. GrinWallet::chain_type).
        global::set_local_chain_type(chain_type);
        let _ = global::init_global_chain_type(chain_type);

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
        Ok(GrinWallet { owner, mask: None, config_path, chain_type })
    });
    match result {
        Ok(Ok(w)) => Box::into_raw(Box::new(w)),
        Ok(Err(e)) => {
            set_error(e);
            fail()
        }
        Err(_) => {
            set_error(panic_error("grin_wallet_create"));
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
        let w = wallet_mut(handle)?;
        global::set_local_chain_type(w.chain_type);
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
            set_error(panic_error("grin_wallet_open"));
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
        let w = wallet_mut(handle)?;
        global::set_local_chain_type(w.chain_type);
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
            set_error(panic_error("grin_wallet_create_seed"));
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
        let w = wallet_mut(handle)?;
        global::set_local_chain_type(w.chain_type);
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
            set_error(panic_error("grin_wallet_balance"));
            fail()
        }
    }
}

/// История транзакций: [{"id","type","status","amount","fee","message","creation_ts"}].
#[no_mangle]
pub extern "C" fn grin_wallet_txs(handle: *mut GrinWallet) -> *mut c_char {
    let result = guarded(|| -> Result<serde_json::Value, String> {
        let w = wallet_mut(handle)?;
        global::set_local_chain_type(w.chain_type);
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
            set_error(panic_error("grin_wallet_txs"));
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
        let w = wallet_mut(handle)?;
        global::set_local_chain_type(w.chain_type);
        let dest = c_str(dest).ok_or("dest is null")?;
        SlatepackAddress::try_from(dest.as_str()).map_err(|e| format!("bad dest: {e}"))?;

        if amount_nanogrin == 0 {
            return Err("сумма должна быть больше нуля".into());
        }
        // Предварительная проверка списываемого баланса: без неё
        // init_send_tx при сумме >= spendable паникует внутри выбора входов,
        // и наружу уходило «panic in …» вместо понятной причины.
        let (_updated, info) = w
            .owner
            .retrieve_summary_info(w.mask.as_ref(), false, 2)
            .map_err(|e| format!("баланс: {e}"))?;
        let spendable = info.amount_currently_spendable;
        if amount_nanogrin >= spendable {
            return Err(format!(
                "недостаточно средств: сумма {amount_nanogrin} наногрин + комиссия, доступно {spendable}"
            ));
        }

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
            set_error(panic_error("grin_wallet_send"));
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
        let w = wallet_mut(handle)?;
        global::set_local_chain_type(w.chain_type);
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
            set_error(panic_error("grin_wallet_receive"));
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
        let w = wallet_mut(handle)?;
        global::set_local_chain_type(w.chain_type);
        let slatepack = c_str(slatepack_response).ok_or("slatepack is null")?;
        let slate = w
            .owner
            .slate_from_slatepack_message(w.mask.as_ref(), slatepack, vec![0, 1])
            .map_err(|e| format!("slate_from_slatepack_message: {e}"))?;
        let finalized = w
            .owner
            .finalize_tx(w.mask.as_ref(), &slate)
            .map_err(|e| format!("finalize_tx: {e}"))?;
        // Сначала фиксируем подписанную tx на диске: если post_tx упадёт,
        // её можно опубликовать снова без повторной подписи.
        store_repost_slate(w, &finalized)?;
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
            set_error(panic_error("grin_wallet_finalize"));
            -1
        }
    }
}

/// Повторная публикация уже подписанной транзакции по slate_id.
/// Ничего не подписывает: читает сохранённый Slate и отправляет его в ноду.
#[no_mangle]
pub extern "C" fn grin_wallet_repost(handle: *mut GrinWallet, slate_id: *const c_char) -> i32 {
    let result = guarded(|| -> Result<(), String> {
        let w = wallet_mut(handle)?;
        global::set_local_chain_type(w.chain_type);
        let slate_id = c_str(slate_id).ok_or("slate_id is null")?;
        let uuid = uuid::Uuid::parse_str(&slate_id).map_err(|e| format!("bad uuid: {e}"))?;
        let path = repost_dir(w).join(format!("{uuid}.json"));
        let json = std::fs::read_to_string(&path)
            .map_err(|e| format!("нет сохранённой tx {}: {e}", path.display()))?;
        let slate = Slate::deserialize_upgrade(&json)
            .map_err(|e| format!("сохранённая tx повреждена: {e}"))?;
        w.owner
            .post_tx(w.mask.as_ref(), &slate, true)
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
            set_error(panic_error("grin_wallet_repost"));
            -1
        }
    }
}

/// Отмена неподтверждённой транзакции по slate_id (uuid-строка).
#[no_mangle]
pub extern "C" fn grin_wallet_cancel(handle: *mut GrinWallet, slate_id: *const c_char) -> i32 {
    let result = guarded(|| -> Result<(), String> {
        let w = wallet_mut(handle)?;
        global::set_local_chain_type(w.chain_type);
        let slate_id = c_str(slate_id).ok_or("slate_id is null")?;
        let uuid = uuid::Uuid::parse_str(&slate_id).map_err(|e| format!("bad uuid: {e}"))?;

        // Отмена допустима только в безопасном состоянии: до финализации.
        let (_, txs) = w
            .owner
            .retrieve_txs(w.mask.as_ref(), true, None, Some(uuid), None)
            .map_err(|e| format!("retrieve_txs: {e}"))?;
        let entry = txs
            .first()
            .ok_or_else(|| "транзакция не найдена".to_string())?;
        if entry.confirmed {
            return Err("отмена запрещена: транзакция уже подтверждена".into());
        }
        if matches!(entry.tx_slate_state, Some(SlateState::Standard3) | Some(SlateState::Invoice3))
        {
            return Err(
                "отмена запрещена: транзакция финализирована и опубликована; \
                 повторная публикация — repost, отмена — только до финализации"
                    .into(),
            );
        }

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
            set_error(panic_error("grin_wallet_cancel"));
            -1
        }
    }
}

/// Genesis-хеш сети: по нему проверяется, что нода работает в той же цепи,
/// что и кошелёк. chain: "mainnet" | "testnet" | "floonet" — строго.
#[no_mangle]
pub extern "C" fn grin_wallet_chain_genesis(chain: *const c_char) -> *mut c_char {
    let result = guarded(|| -> Result<serde_json::Value, String> {
        let chain = c_str(chain).ok_or_else(|| {
            "сеть не задана: ожидается \"mainnet\", \"testnet\" или \"floonet\"".to_string()
        })?;
        // genesis_* сверяются с thread-local типом цепи — выставляем его явно.
        let (block, name) = match chain.as_str() {
            "testnet" | "floonet" => {
                global::set_local_chain_type(ChainTypes::Testnet);
                (genesis::genesis_test(), "testnet")
            }
            "mainnet" => {
                global::set_local_chain_type(ChainTypes::Mainnet);
                (genesis::genesis_main(), "mainnet")
            }
            other => return Err(format!(
                "неизвестная сеть «{other}»: ожидается \"mainnet\", \"testnet\" или \"floonet\""
            )),
        };
        Ok(json!({
            "chain": name,
            "hash": block.header.hash().to_string(),
        }))
    });
    match result {
        Ok(Ok(v)) => ok_json(v),
        Ok(Err(e)) => {
            set_error(e);
            fail()
        }
        Err(_) => {
            set_error(panic_error("grin_wallet_chain_genesis"));
            fail()
        }
    }
}
// ---------- общий контракт переводов (flint-transfer-contract) ----------

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Точный разбор суммы по общим правилам контракта: до 9 знаков после точки,
/// без переполнения и без молчаливого усечения.
/// Возвращает {"nano": <u64>, "display": "1.000000001"}.
#[no_mangle]
pub extern "C" fn grin_wallet_parse_amount(text: *const c_char) -> *mut c_char {
    let result = guarded(|| -> Result<serde_json::Value, String> {
        let text = c_str(text).ok_or("amount is null")?;
        let nano = NanoGrin::parse(&text).map_err(|e| format!("сумма: {e}"))?;
        Ok(json!({ "nano": nano.0, "display": nano.display() }))
    });
    match result {
        Ok(Ok(v)) => ok_json(v),
        Ok(Err(e)) => {
            set_error(e);
            fail()
        }
        Err(_) => {
            set_error(panic_error("grin_wallet_parse_amount"));
            fail()
        }
    }
}

/// Оценка комиссии до подписания: сумма + реальная комиссия от backend.
/// Ничего не блокирует и не создаёт транзакцию (`estimate_only`).
#[no_mangle]
pub extern "C" fn grin_wallet_estimate_fee(
    handle: *mut GrinWallet,
    amount_nanogrin: u64,
    dest: *const c_char,
) -> *mut c_char {
    let result = guarded(|| -> Result<serde_json::Value, String> {
        let w = wallet_mut(handle)?;
        global::set_local_chain_type(w.chain_type);
        let dest = c_str(dest).ok_or("dest is null")?;
        SlatepackAddress::try_from(dest.as_str()).map_err(|e| format!("bad dest: {e}"))?;

        if amount_nanogrin == 0 {
            return Err("сумма должна быть больше нуля".into());
        }
        // Предварительная проверка списываемого баланса: без неё
        // init_send_tx при сумме >= spendable паникует внутри выбора входов,
        // и наружу уходило «panic in …» вместо понятной причины.
        let (_updated, info) = w
            .owner
            .retrieve_summary_info(w.mask.as_ref(), false, 2)
            .map_err(|e| format!("баланс: {e}"))?;
        let spendable = info.amount_currently_spendable;
        if amount_nanogrin >= spendable {
            return Err(format!(
                "недостаточно средств: сумма {amount_nanogrin} наногрин + комиссия, доступно {spendable}"
            ));
        }

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
            estimate_only: Some(true),
            late_lock: Some(false),
            send_args: Some(InitTxSendArgs {
                dest,
                post_tx: false,
                fluff: false,
                skip_tor: Some(true),
            }),
        };
        let slate = w
            .owner
            .init_send_tx(w.mask.as_ref(), args)
            .map_err(|e| format!("init_send_tx(estimate): {e}"))?;
        let fee = slate.fee_fields.fee();
        // slate.amount при use_all — сумма выбранных входов; итоговое списание
        // для пользователя = сумма перевода + комиссия.
        let total = amount_nanogrin
            .checked_add(fee)
            .ok_or_else(|| "сумма + комиссия переполняют u64".to_string())?;
        Ok(json!({ "fee": fee, "total": total }))
    });
    match result {
        Ok(Ok(v)) => ok_json(v),
        Ok(Err(e)) => {
            set_error(e);
            fail()
        }
        Err(_) => {
            set_error(panic_error("grin_wallet_estimate_fee"));
            fail()
        }
    }
}

/// Состояние перевода по общим правилам: этап, next_action и допустимые
/// действия. `wallet_state` — состояние журнала (prepared, response_received,
/// posted, confirmed, …); неизвестное состояние считается recoverable.
#[no_mangle]
pub extern "C" fn grin_wallet_transfer_state(
    direction: *const c_char,
    wallet_state: *const c_char,
    amount_nano: u64,
    fee_nano: u64,
    peer: *const c_char,
    slate_id: *const c_char,
    last_error: *const c_char,
) -> *mut c_char {
    let result = guarded(|| -> Result<serde_json::Value, String> {
        let direction = c_str(direction).ok_or("direction is null")?;
        let wallet_state = c_str(wallet_state).ok_or("wallet_state is null")?;
        let slate_id = c_str(slate_id).ok_or("slate_id is null")?;
        let peer = c_str(peer).unwrap_or_default();
        let direction = match direction.as_str() {
            "send" => Direction::Send,
            "receive" => Direction::Receive,
            other => return Err(format!("неизвестное направление «{other}»")),
        };
        let stage = Stage::from_wallet_state(direction.as_str(), &wallet_state);
        let state = TransferState::new(
            slate_id,
            direction,
            stage,
            NanoGrin(amount_nano),
            NanoGrin(fee_nano),
            peer,
            c_str(last_error),
            now_unix(),
        );
        state.validate().map_err(|e| format!("состояние: {e}"))?;
        serde_json::to_value(&state).map_err(|e| format!("json: {e}"))
    });
    match result {
        Ok(Ok(v)) => ok_json(v),
        Ok(Err(e)) => {
            set_error(e);
            fail()
        }
        Err(_) => {
            set_error(panic_error("grin_wallet_transfer_state"));
            fail()
        }
    }
}