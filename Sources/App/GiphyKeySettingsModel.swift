import Combine
import Foundation

enum GiphyKeyStatus: Equatable {
    case missing
    case stored
    case failed(String)
}

@MainActor
final class GiphyKeySettingsModel: ObservableObject {
    @Published var draftKey = ""
    @Published private(set) var status: GiphyKeyStatus = .missing

    private let store: any GiphyAPIKeyStoring

    init(
        store: any GiphyAPIKeyStoring = KeychainGiphyAPIKeyStore()
    ) {
        self.store = store
    }

    var hasStoredKey: Bool {
        status == .stored
    }

    var statusTitle: String {
        switch status {
        case .missing:
            "No Keychain key stored"
        case .stored:
            "Stored in Keychain"
        case .failed:
            "Keychain unavailable"
        }
    }

    var statusSymbolName: String {
        switch status {
        case .missing:
            "key.slash"
        case .stored:
            "checkmark.shield"
        case .failed:
            "exclamationmark.triangle"
        }
    }

    func refresh() {
        do {
            _ = try store.apiKey()
            status = .stored
        } catch RemoteMediaError.missingAPIKey {
            status = .missing
        } catch {
            status = .failed(Self.safeErrorDescription(error))
        }
    }

    func save() {
        let value = draftKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty else {
            status = .failed("Enter a GIPHY API key before saving.")
            return
        }
        do {
            try store.save(value)
            draftKey = ""
            status = .stored
        } catch {
            status = .failed(Self.safeErrorDescription(error))
        }
    }

    func remove() {
        do {
            try store.delete()
            draftKey = ""
            status = .missing
        } catch {
            status = .failed(Self.safeErrorDescription(error))
        }
    }

    private static func safeErrorDescription(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "The GIPHY key could not be changed."
    }
}
