import SwiftUI

enum PondDesign {
    static let cornerRadius: CGFloat = 12
    static let compactCornerRadius: CGFloat = 9
    static let contentPadding: CGFloat = 20
    static let pond = Color(red: 0.18, green: 0.45, blue: 0.55)
    static let lily = Color(red: 0.34, green: 0.58, blue: 0.38)
}

struct PondCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: PondDesign.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: PondDesign.cornerRadius)
                    .stroke(.separator.opacity(0.55))
            }
    }
}

struct PondMark: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            Circle()
                .fill(PondDesign.pond.gradient)
            Image(systemName: "water.waves")
                .font(.system(size: size * 0.43, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: PondDesign.pond.opacity(0.22), radius: 16, y: 8)
        .accessibilityHidden(true)
    }
}

