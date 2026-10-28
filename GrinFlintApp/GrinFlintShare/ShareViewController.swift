import UIKit
import UniformTypeIdentifiers

/// Share Extension: принимает из системного «Поделиться» текст или ссылку
/// (например, Slatepack из мессенджера) и открывает приложение по
/// `grinslate://receive?text=<url-encoded>`.
///
/// App Group не нужен: данные передаются через URL, приложение само
/// разбирает ссылку и открывает лист приёма.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        loadSharedItem()
    }

    private func loadSharedItem() {
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem])?
            .compactMap { $0.attachments }
            .flatMap { $0 } ?? []
        guard !attachments.isEmpty else {
            finish(cancelled: true)
            return
        }

        let textType = UTType.plainText.identifier
        let urlType = UTType.url.identifier

        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(textType) }) {
            provider.loadItem(forTypeIdentifier: textType, options: nil) { [weak self] item, _ in
                let text = (item as? String)
                    ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                self?.open(text: text)
            }
        } else if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(urlType) }) {
            provider.loadItem(forTypeIdentifier: urlType, options: nil) { [weak self] item, _ in
                let text = (item as? URL)?.absoluteString ?? (item as? String)
                self?.open(text: text)
            }
        } else {
            finish(cancelled: true)
        }
    }

    /// Процентное кодирование с запасом: всё, кроме неразрешённых символов,
    /// чтобы `+`, `=` и `/` из Slatepack не потерялись в query.
    private func percentEncoded(_ text: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    private func open(text: String?) {
        guard let text, !text.isEmpty, let encoded = percentEncoded(text),
              let url = URL(string: "grinslate://receive?text=\(encoded)") else {
            finish(cancelled: true)
            return
        }
        extensionContext?.open(url) { [weak self] succeeded in
            self?.finish(cancelled: !succeeded)
        }
    }

    private func finish(cancelled: Bool) {
        guard let context = extensionContext else { return }
        if cancelled {
            let error = NSError(
                domain: "com.dan.grinflint.share",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось передать текст в GrinFlint"]
            )
            context.cancelRequest(withError: error)
        } else {
            context.completeRequest(returningItems: nil)
        }
    }
}
