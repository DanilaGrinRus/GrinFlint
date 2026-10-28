import Foundation

/// Незавершённый перевод: переживает перезапуск приложения, чтобы Slatepack
/// не терялся после обновления истории (в истории он не хранится).
enum PendingOperationKind: String, Codable {
    /// Исходящий: создан запрос, ждём ответный Slatepack получателя.
    case send
    /// Входящий: получен запрос, готов ответ для отправителя.
    case receive
}

enum PendingOperationStage: String, Codable {
    /// send: запрос создан, ответ ещё не получен.
    case awaitingResponse
    /// receive: ответный Slatepack готов, его нужно передать отправителю.
    case responseReady

    var title: String {
        switch self {
        case .awaitingResponse:
            return "Ждём ответ получателя"
        case .responseReady:
            return "Ответ готов — передайте отправителю"
        }
    }
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
    var txID: String?
    var createdAt: Date
    var lastError: String?

    var amountDecimal: Decimal? {
        amount.flatMap { Decimal(string: $0) }
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

    /// Самая свежая незавершённая операция.
    var latest: PendingOperation? {
        operations.sorted { $0.createdAt > $1.createdAt }.first
    }

    /// Исходящая операция, ожидающая ответа (одна за раз — предотвращает
    /// повторную подпись и дублирование переводов).
    var awaitingSend: PendingOperation? {
        operations
            .filter { $0.kind == .send && $0.stage == .awaitingResponse }
            .sorted { $0.createdAt > $1.createdAt }
            .first
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
            try data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            // Журнал — вспомогательный: операция всё равно в памяти.
        }
    }
}
