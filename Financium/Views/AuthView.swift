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

            VStack(spacing: 14) {
                appleSignInButton

                if auth.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }

                if let message = auth.errorMessage {
                    Text(verbatim: message)
                        .font(.footnote)
                        .foregroundStyle(FITheme.Palette.destructive)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// A glyph rather than the bundled icon: Financium's app icon lives only in
    /// the appiconset, which cannot be loaded as an `Image`. Swap this for an
    /// `Image("LaunchAppIcon")` once a launch imageset exists.
    private var appMark: some View {
        Image(systemName: "wallet.bifold.fill")
            .font(.system(size: 56, weight: .regular))
            .foregroundStyle(FITheme.Palette.accent)
            .frame(width: 120, height: 120)
            .background(FITheme.Palette.card, in: RoundedRectangle(cornerRadius: 27, style: .continuous))
            .shadow(color: .black.opacity(0.09), radius: 18, y: 9)
    }

    /// Custom-styled Apple button: a white capsule with the label on the left
    /// and the Apple glyph plus a chevron on the right.
    ///
    /// The real `SignInWithAppleButton` stays underneath — drawn with
    /// `.destinationOver` so it is invisible but still hit-tests — because
    /// Apple's own control is the only thing allowed to start the flow.
    private var appleSignInButton: some View {
        ZStack {
            appleButtonLabel

            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.fullName, .email]
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
                    Task { await auth.signIn(credential: credential) }

                case .failure(let error):
                    // A cancel is not an error worth showing: the user knows
                    // they backed out.
                    if (error as? ASAuthorizationError)?.code != .canceled {
                        auth.errorMessage = error.localizedDescription
                    }
                }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .whiteOutline)
            .blendMode(.destinationOver)
        }
        .frame(height: 64)
        .clipShape(Capsule(style: .continuous))
        .disabled(auth.isWorking)
        .opacity(auth.isWorking ? 0.6 : 1)
    }

    private var appleButtonLabel: some View {
        HStack(spacing: 12) {
            Text("auth.continue_with_apple")
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Image(systemName: "apple.logo")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary)

            FIChevron()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FITheme.Palette.card, in: Capsule(style: .continuous))
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
