import Foundation
import Observation

/// Контакт адресной книги: имя и Grin-адрес (Slatepack).
struct Contact: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var address: String
}

/// Адресная книга контрагентов.
///
/// Хранится в UserDefaults: это не секрет (публичные адреса и имена),
/// зато не требует Keychain и переживает переустановку в пределах контейнера.
@Observable
final class AddressBook {
    private static let storageKey = "addressBook.contacts.v1"

    private(set) var contacts: [Contact] = []

    init() {
        load()
    }

    func add(name: String, address: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedAddress.isEmpty else { return }
        contacts.append(Contact(name: trimmedName, address: trimmedAddress))
        save()
    }

    func delete(_ contact: Contact) {
        contacts.removeAll { $0.id == contact.id }
        save()
    }

    /// Контакт по адресу (для подсказки «кому отправляем»).
    func contact(forAddress address: String) -> Contact? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return contacts.first { $0.address == trimmed }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([Contact].self, from: data) else {
            return
        }
        contacts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(contacts) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
