import SwiftUI

/// The app's icon on the page background, and nothing else.
///
/// Stands in for the several small spinners that used to mark the same wait —
/// one under the account list, one under the sign-in button. A wheel in the
/// middle of a half-drawn screen says the app is stuck; a screen that is only
/// the mark says it is starting, which is what is actually happening.
///
/// Still, deliberately. It is on for well under a second, and an entrance
/// animation would be competing with the app arriving behind it.
struct LaunchScreen: View {
    private let icon = AppIconOption.current

    var body: some View {
        ZStack {
            FITheme.Palette.pageBackground
                .ignoresSafeArea()

            Image(icon.previewImageName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 112, height: 112)
                // The radius iOS itself uses, so the mark matches the icon the
                // reader tapped rather than approximating it.
                .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                .shadow(color: .black.opacity(0.10), radius: 22, y: 12)
        }
        // Swallows taps: whatever is underneath is mid-load and not ready to be
        // touched.
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityHidden(true)
    }
}

#Preview {
    LaunchScreen()
}
