import AuthenticationServices
import SwiftUI

/// Sign-in, laid out like Eatometer's: the app mark and a greeting centred in
/// the upper half, the Apple button and the legal line pinned to the bottom.
///
/// Apple ID is the only way in, so there is no form — which is why the screen
/// can afford to be mostly space.
struct AuthView: View {
    @EnvironmentObject private var auth: AuthSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var appleNonce = ""

    /// Called when the reader chooses to keep their money on the device.
    var onContinueLocally: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 18) {
                appMark

                Text("auth.greeting")
                    .font(FITheme.Typography.screenTitle)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                // Apple's own button, drawn by Apple. It was previously a
                // custom row with the real control hidden underneath on
                // `.destinationOver` — which reads as one list with the option
                // below it, but is exactly what Apple's guidelines forbid and
                // what review rejects. The button has to look like the button.
                appleSignInButton

                // The secondary way in, as a secondary control: same width, less
                // weight. A system button style rather than a hand-drawn row, so
                // it inherits the platform's shape, tint and pressed state.
                Button(action: onContinueLocally) {
                    Text("auth.continue_locally")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(height: 50)
                .disabled(auth.isWorking)

                if let message = auth.errorMessage {
                    Text(verbatim: message)
                        .font(.footnote)
                        .foregroundStyle(FITheme.Palette.destructive)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Same inset as the legal line below, so the two blocks
                        // of prose share one left edge instead of starting a
                        // card inset apart.
                        .padding(.horizontal, FITheme.Metrics.cardInset)
                }

                legalText
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, FITheme.Metrics.screenInset)
        .padding(.vertical, 24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .fiPageBackground()
        .tint(FITheme.Palette.accent)
    }

    /// The app's own icon.
    ///
    /// Drawn from the preview imageset the icon picker already ships, not from
    /// the `.icon` bundle — an app icon cannot be loaded as an `Image` at
    /// runtime, so the render has to be in the asset catalog either way.
    ///
    /// Whichever icon the reader currently has on their home screen, so the
    /// mark on this screen and the thing they tapped to get here are the same
    /// picture.
    private var appMark: some View {
        Image(AppIconOption.current.previewImageName)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 120, height: 120)
            // 22.37% of the side is the corner radius iOS itself uses, so the
            // mark matches the icon rather than approximating it.
            .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
            .shadow(color: .black.opacity(0.09), radius: 18, y: 9)
    }

    /// Apple's button, unmodified.
    ///
    /// No custom label over it and no blend-mode trick: the control's
    /// appearance is Apple's to define, and an app that redraws it is one that
    /// gets rejected. Style and corner radius are the only knobs offered, and
    /// both are used here.
    private var appleSignInButton: some View {
        SignInWithAppleButton(.continue) { request in
            request.requestedScopes = [.fullName, .email]
            guard let nonce = AuthSession.makeAppleNonce() else {
                auth.errorMessage = NSLocalizedString("auth.apple.nonce_error", comment: "Could not create Apple nonce")
                return
            }
            appleNonce = nonce
            request.nonce = AuthSession.appleNonceHash(nonce)
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                    auth.errorMessage = NSLocalizedString(
                        "auth.apple.invalid_response",
                        comment: "Apple ID response could not be read"
                    )
                    return
                }
                Task { await auth.signIn(credential: credential, nonce: appleNonce) }

            case .failure(let error):
                // A cancel is not an error worth showing: the user knows they
                // backed out.
                if (error as? ASAuthorizationError)?.code != .canceled {
                    auth.errorMessage = error.localizedDescription
                }
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 50)
        .clipShape(Capsule(style: .continuous))
        .disabled(auth.isWorking)
    }

    private var legalText: some View {
        let markdown = FinanciumLegal.authMarkdown
        let attributed = (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)

        return Text(attributed)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FITheme.Metrics.cardInset)
    }
}

/// The consent line under the sign-in button.
///
/// Built as markdown rather than as a localized string with a link, because the
/// link text has to be part of the sentence and decline with it.
enum FinanciumLegal {
    static let publicURL = URL(string: "https://gofinancium.com/legal")!

    static var authMarkdown: String {
        let title = NSLocalizedString("legal.link", comment: "Legal information, inline")
        let link = "[\(title)](\(publicURL.absoluteString))"
        return String(
            format: NSLocalizedString("legal.auth_consent", comment: "Consent line on the sign-in screen"),
            link
        )
    }
}
