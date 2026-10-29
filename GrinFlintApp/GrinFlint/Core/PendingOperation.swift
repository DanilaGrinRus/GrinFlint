import Foundation

/// Незавершённый перевод: переживает перезапуск приложения, чтобы Slatepack
/// не терялся после обновления истории (в истории он не хранится).
enum PendingOperationKind: String, Codable {
    /// Исходящий: создан запрос, ждём ответный Slatepack получателя.
    case send
    /// Входящий: получен запрос, готов ответ для отправителя.
    case receive
}

/// Стадии операции. Исходящая проходит:
/// prepared → requestSent → finalized → posted → confirmed;
/// отмена возможна только до финализации (cancelled — терминальное состояние).
enum PendingOperationStage: String, Codable, CaseIterable {
    /// Запрос создан, средства заблокированы; получателю ещё не передан.
    case prepared
    /// Запрос передан получателю, ждём ответный Slatepack.
    case requestSent
    /// Ответ получен, транзакция подписана; публикация могла не пройти.
    /// В этом состоянии доступен повтор публикации (repost) без новой подписи.
    case finalized
    /// Подписанная транзакция опубликована в ноду.
    case posted
    /// Транзакция подтверждена в блоке.
    case confirmed
    /// Отменена до финализации, заблокированные средства освобождены.
    case cancelled

    /// Записи прежних сборок: send ждал ответа, receive готовил ответ.
    /// Обе соответствуют `prepared` — повторной подписи не происходит.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "awaitingResponse", "responseReady":
            self = .prepared
        default:
            guard let stage = PendingOperationStage(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "неизвестная стадия операции: \(raw)"
                )
            }
            self = stage
        }
    }

    var title: String {
        switch self {
        case .prepared: return "Запрос создан"
        case .requestSent: return "Запрос передан получателю"
        case .finalized: return "Транзакция подписана"
        case .posted: return "Опубликована в сети"
        case .confirmed: return "Подтверждена"
        case .cancelled: return "Отменена"
        }
    }

    /// Пояснение этапа и доступных действий (без технического жаргона).
    var detail: String {
        switch self {
        case .prepared:
            return "Передайте Slatepack получателю. Отмена возможна до финализации."
        case .requestSent:
            return "Ждём ответный Slatepack. Отмена возможна до финализации."
        case .finalized:
            return "Подпись готова. Если публикация не прошла, повторите её — новая подпись не потребуется."
        case .posted:
            return "Транзакция отправлена в сеть, ждём подтверждения в блоке."
        case .confirmed:
            return "Транзакция подтверждена в блоке."
        case .cancelled:
            return "Перевод отменён, заблокированные средства освобождены."
        }
    }

    /// Терминальные стадии не показываются как незавершённая операция.
    var isTerminal: Bool { self == .confirmed || self == .cancelled }

    /// Исходящий перевод, для которого ещё нужна подпись или публикация:
    /// второй такой запрос не создаём, чтобы не задвоить операцию.
    var blocksNewSend: Bool {
        self == .prepared || self == .requestSent || self == .finalized
    }

    /// Ответный Slatepack принимается, пока перевод не подписан.
    var acceptsResponse: Bool { self == .prepared || self == .requestSent }
}

struct PendingOperation: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: PendingOperationKind
    var stage: PendingOperationStage
    /// send — запрос для получателя; receive — ответ для отправителя.
    var slatepack: String
    var destination: String?
    var amount: String?
    var fee: String?
    /// Для send — slate_id транзакции (uuid строка из grin-wallet).
    var txID: String?
    var createdAt: Date
    var lastError: String?

    var amountDecimal: Decimal? {
        amount.flatMap { Decimal(string: $0) }
    }

    var feeDecimal: Decimal? {
        fee.flatMap { Decimal(string: $0) }
    }
}

/// Журнал незавершённых переводов в каталоге данных кошелька.
///
/// Здесь нет seed/ключей: только Slatepack и параметры операции. Файл
/// защищён как обычные Documents (`CompleteUntilFirstUserAuthentication`),
/// запись атомарная. Если запись не удалась, операция остаётся в памяти —
/// кошелёк из-за журнала не падает.
final class PendingOperationsStore {
    private let fileURL: URL
    private(set) var operations: [PendingOperation] = []

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("pending-operations.json")
        load()
    }

    /// Самая свежая операция (включая терминальные — для журнала/диагностики).
    var latest: PendingOperation? {
        operations.sorted { $0.createdAt > $1.createdAt }.first
    }

    /// Самая свежая незавершённая операция (карточка на портфеле).
    var active: PendingOperation? {
        operations
            .filter { !$0.stage.isTerminal }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    /// Исходящая операция, для которой ещё нужна подпись/публикация
    /// (одна за раз — предотвращает повторную подпись и дублирование).
    var unfinishedSend: PendingOperation? {
        operations
            .filter { $0.kind == .send && $0.stage.blocksNewSend }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    func operation(id: UUID) -> PendingOperation? {
        operations.first { $0.id == id }
    }

    func operation(txID: String) -> PendingOperation? {
        operations.first { $0.txID == txID }
    }

    func upsert(_ operation: PendingOperation) {
        if let index = operations.firstIndex(where: { $0.id == operation.id }) {
            operations[index] = operation
        } else {
            operations.append(operation)
        }
        save()
    }

    func remove(id: UUID) {
        operations.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PendingOperation].self, from: data) else {
            return
        }
        operations = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(operations)
            // Защита файла до первого входа — только Darwin; на Linux/Windows
            // (тесты чистой логики) остаётся атомарная запись.
            #if canImport(Darwin)
            let options: Data.WritingOptions = [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
            #else
            let options: Data.WritingOptions = [.atomic]
            #endif
            try data.write(to: fileURL, options: options)
        } catch {
            // Журнал — вспомогательный: операция всё равно в памяти.
        }
    }
}
