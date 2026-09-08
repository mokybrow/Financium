import AuthenticationServices
import SwiftUI

/// The first screen: the app mark, a greeting, and Sign in with Apple.
///
/// There is no backend behind it — the button reads the name and email Apple
/// hands back and keeps them on the device.
struct AuthView: View {
    @EnvironmentObject private var auth: AppleAuth
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 18) {
                Image("AppIconPreview")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
                    .shadow(color: .black.opacity(0.09), radius: 18, y: 9)

                Text("auth.greeting")
                    .font(FITheme.Typography.screenTitle)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    switch result {
                    case .success(let authorization):
                        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                            auth.errorMessage = NSLocalizedString(
                                "auth.apple.invalid_response", comment: "Apple ID response could not be read"
                            )
                            return
                        }
                        auth.signIn(credential: credential)
                    case .failure(let error):
                        if (error as? ASAuthorizationError)?.code != .canceled {
                            auth.errorMessage = error.localizedDescription
                        }
                    }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .clipShape(Capsule(style: .continuous))

                if let message = auth.errorMessage {
                    Text(verbatim: message)
                        .font(.footnote)
                        .foregroundStyle(FITheme.Palette.destructive)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, FITheme.Metrics.cardInset)
                }
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
}
