import AppKit
import UniformTypeIdentifiers

@MainActor
enum LibraryZIPPicker {
    static func choose(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Review"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK else {
            return nil
        }
        return panel.url
    }
}
