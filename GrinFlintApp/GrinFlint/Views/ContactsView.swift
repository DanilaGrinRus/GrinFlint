import SwiftUI

/// Адресная книга: список контактов, добавление и удаление.
struct ContactsView: View {
    @Environment(AddressBook.self) private var addressBook

    @State private var isAdding = false
    @State private var newName = ""
    @State private var newAddress = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if addressBook.contacts.isEmpty {
                    ContentUnavailableView(
                        "Нет контактов",
                        systemImage: "person.crop.circle.badge.plus",
                        description: Text("Добавьте Grin-адрес, чтобы не вставлять его каждый раз")
                    )
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 40)
                } else {
                    GrinCard {
                        VStack(spacing: 6) {
                            ForEach(addressBook.contacts) { contact in
                                contactRow(contact)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Адресная книга")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isAdding = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Theme.accent)
                }
                .accessibilityIdentifier("contacts.add")
            }
        }
        .sheet(isPresented: $isAdding) {
            addSheet
        }
    }

    private func contactRow(_ contact: Contact) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(contact.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(shortAddress(contact.address))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(role: .destructive) {
                addressBook.delete(contact)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Theme.negative)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("contact.delete")
        }
        .padding(.vertical, 8)
    }

    private var addSheet: some View {
        NavigationStack {
            Form {
                TextField("Имя", text: $newName)
                    .accessibilityIdentifier("contact.name")
                TextField("Grin-адрес", text: $newAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("contact.address")
            }
            .navigationTitle("Новый контакт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        reset()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        addressBook.add(name: newName, address: newAddress)
                        reset()
                    }
                    .disabled(
                        newName.trimmingCharacters(in: .whitespaces).isEmpty ||
                        newAddress.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func reset() {
        isAdding = false
        newName = ""
        newAddress = ""
    }

    private func shortAddress(_ address: String) -> String {
        guard address.count > 24 else { return address }
        return "\(address.prefix(12))…\(address.suffix(8))"
    }
}
