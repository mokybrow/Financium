import SwiftUI

extension Color {
    /// `#RRGGBB` (or `RRGGBB`). Returns nil for anything else.
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let int = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: Double((int >> 16) & 0xFF) / 255,
            green: Double((int >> 8) & 0xFF) / 255,
            blue: Double(int & 0xFF) / 255
        )
    }
}

/// The person, as a photo, an emoji, or a monogram on a coloured disc.
struct FIAvatar: View {
    let monogram: String
    let colorHex: String
    var emoji: String? = nil
    var monogramStyle: ProfileStore.MonogramStyle = .classic
    let photo: UIImage?
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            } else if let emoji, !emoji.isEmpty {
                (Color(hex: colorHex) ?? FITheme.Palette.controlFill)
                    .overlay { Text(verbatim: emoji).font(.system(size: size * 0.5)) }
            } else {
                (Color(hex: colorHex) ?? FITheme.Palette.controlFill)
                    .overlay {
                        Text(verbatim: monogram)
                            .font(monogramStyle.font(size: size * 0.42))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .contentShape(Circle())
    }
}

/// The avatar button that lives in the trailing toolbar slot on the main
/// screens and opens the profile sheet. A plain SwiftUI `Button` so it picks
/// up the toolbar's own styling.
struct ProfileToolbarButton: View {
    @EnvironmentObject private var profile: ProfileStore

    var body: some View {
        Button {
            profile.isPresented = true
        } label: {
            FIAvatar(
                monogram: profile.monogram,
                colorHex: profile.colorHex,
                emoji: profile.emoji,
                monogramStyle: profile.monogramStyle,
                photo: profile.photo,
                size: 32
            )
        }
        .accessibilityLabel(Text("profile.title"))
    }
}
