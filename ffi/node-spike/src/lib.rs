//! Спайк встроенной ноды: минимальная библиотека, которая заставляет
//! скомпилироваться и слинковаться node-крейтам Grin под iOS.
//!
//! В приложение не входит. Цель — ответить на вопрос «собирается ли
//! full node как staticlib для iOS», до того как писать менеджер ноды.

use std::ffi::CString;
use std::os::raw::c_char;

/// Форсирует компиляцию `grin_servers`/`grin_config` (типы и конфиг ноды).
pub fn server_type_marker() -> Option<grin_servers::Server> {
    None
}

/// Проверка, что конфиг ноды парсится на этой платформе.
pub fn config_parse_marker(path: &str) -> Result<(), String> {
    grin_config::GlobalConfig::new(path)
        .map(|_| ())
        .map_err(|e| format!("config: {e}"))
}

/// C-точка входа для будущего Swift-менеджера ноды: возвращает строку,
/// которую нужно освободить через `grin_node_spike_free`.
#[no_mangle]
pub extern "C" fn grin_node_spike_self_check() -> *mut c_char {
    let ok = server_type_marker().is_none() && grin_core::global::ChainTypes::Testnet == grin_core::global::ChainTypes::Testnet;
    let text = if ok { "spike-ok".to_string() } else { "spike-fail".to_string() };
    CString::new(text).unwrap_or_default().into_raw()
}

/// Освобождение строки из `grin_node_spike_*`.
#[no_mangle]
pub unsafe extern "C" fn grin_node_spike_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}
