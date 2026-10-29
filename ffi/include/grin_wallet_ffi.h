#ifndef GRIN_WALLET_FFI_H
#define GRIN_WALLET_FFI_H

/* C API кошелька Grin (обёртка над grin-wallet 5.5.x).
 * Все возвращаемые строки — JSON; освобождать через grin_string_free().
 * При ошибке возвращается NULL (или -1), текст — через grin_last_error().
 */

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

typedef struct GrinWallet GrinWallet;

/* Последняя ошибка текущего потока (не освобождать). */
const char *grin_last_error(void);

/* Освобождение строк, возвращённых API. */
void grin_string_free(char *s);

/* Создать контекст кошелька. chain: "mainnet" | "floonet".
 * api_secret: NULL/пусто или пароль Basic Auth ноды (grinnode.live). */
GrinWallet *grin_wallet_create(const char *data_dir,
                               const char *node_url,
                               const char *chain,
                               const char *api_secret);

/* Закрыть и освободить контекст. */
void grin_wallet_destroy(GrinWallet *handle);

/* Открыть кошелек паролем. Возвращает {"address": "grin1..."}. */
char *grin_wallet_open(GrinWallet *handle, const char *password);

/* Создать кошелек (mnemonic=NULL — новый seed) или восстановить.
 * Возвращает {"mnemonic": "24 слова..."}. */
char *grin_wallet_create_seed(GrinWallet *handle,
                              const char *password,
                              uint32_t mnemonic_length,
                              const char *mnemonic);

/* Баланс {"spendable","awaiting","locked","total"} в наногринах.
 * refresh=1 — сначала опросить ноду. */
char *grin_wallet_balance(GrinWallet *handle, int32_t refresh);

/* История транзакций: {"txs": [...]}. */
char *grin_wallet_txs(GrinWallet *handle);

/* Создать исходящую транзакцию. amount в наногринах, dest — grin1...
 * Возвращает {"slatepack","slate_id","fee"}.
 * Текста сообщения нет: slatepack grin-wallet 5.5.1 его не переносит. */
char *grin_wallet_send(GrinWallet *handle,
                       uint64_t amount_nanogrin,
                       const char *dest);

/* Принять slatepack отправителя. Возвращает {"slatepack": <ответ>}. */
char *grin_wallet_receive(GrinWallet *handle, const char *slatepack);

/* Финализировать ответ получателя и отправить в сеть. 0 — ок, -1 — ошибка. */
int32_t grin_wallet_finalize(GrinWallet *handle, const char *slatepack_response);

/* Отменить неподтверждённую транзакцию по slate_id (uuid). */
int32_t grin_wallet_cancel(GrinWallet *handle, const char *slate_id);

/* Genesis-хеш сети кошелька для проверки совместимости ноды.
 * Возвращает {"chain":"mainnet|testnet","hash":<hex>}; NULL — ошибка. */
char *grin_wallet_chain_genesis(const char *chain);

/* Оценка комиссии до подписания (estimate_only, без блокировки средств).
 * Возвращает {"fee":<u64>,"total":<u64>}; NULL — ошибка. */
char *grin_wallet_estimate_fee(GrinWallet *handle, uint64_t amount_nanogrin, const char *dest);

/* Повторная публикация уже подписанной tx по slate_id (без подписи).
 * 0 — отправлено, -1 — ошибка (grin_last_error). */
int32_t grin_wallet_repost(GrinWallet *handle, const char *slate_id);

/* Точный разбор суммы по общему контракту (до 9 знаков, без переполнения).
 * Возвращает {"nano":<u64>,"display":"..."}; NULL — ошибка. */
char *grin_wallet_parse_amount(const char *text);

/* Состояние перевода по общему контракту (schema 1):
 * {"schema":1,"stage":...,"next_action":...,"can_*":...}.
 * NULL — ошибка (текст в grin_last_error). */
char *grin_wallet_transfer_state(const char *direction,
                                 const char *wallet_state,
                                 uint64_t amount_nano,
                                 uint64_t fee_nano,
                                 const char *peer,
                                 const char *slate_id,
                                 const char *last_error);

#ifdef __cplusplus
}
#endif

#endif /* GRIN_WALLET_FFI_H */
