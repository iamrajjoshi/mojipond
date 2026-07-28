import AppKit
import SwiftUI

@main
struct IntegrationFixtureApp: App {
    var body: some Scene {
        WindowGroup("MojiPond Integration Fixture") {
            FixtureContentView()
                .frame(minWidth: 620, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}

private struct FixtureContentView: View {
    @State private var singleLine = ""
    @State private var password = ""
    @State private var multiLine = ""

    var body: some View {
        Form {
            Section {
                TextField("Try :wave: here", text: $singleLine)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("fixture.plainTextField")
            } header: {
                Label("Plain text field", systemImage: "text.cursor")
            }

            Section {
                TextEditor(text: $multiLine)
                    .font(.body)
                    .frame(minHeight: 110)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.separator)
                    }
                    .accessibilityIdentifier("fixture.multiLineTextView")
            } header: {
                Label("Multiline text", systemImage: "text.alignleft")
            }

            Section {
                RichTextFixture()
                    .frame(minHeight: 120)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.separator)
                    }
                    .accessibilityIdentifier("fixture.richTextView")
            } header: {
                Label("Rich text and attachments", systemImage: "photo.on.rectangle")
            }

            Section {
                SecureField("MojiPond must stay inactive", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("fixture.secureTextField")
            } header: {
                Label("Secure field", systemImage: "lock")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .navigationTitle("Integration Targets")
    }
}

private struct RichTextFixture: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.string = "Try a custom image or animated GIF here."
        textView.setAccessibilityIdentifier("fixture.richTextView.native")

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

