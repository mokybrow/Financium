// Combine is imported explicitly: @Published's enclosing-instance subscript
// lives there, and SwiftUI does not re-export it under explicit modules.
import Combine
import SwiftUI
import UIKit

/// Selectable app icons.
///
/// Financium ships only its primary icon so far. The picker exists now so the
/// settings screen is complete and so adding an icon later is a matter of one
/// case here plus a preview imageset — not a new screen.
///
/// To add one:
///   1. Drop `<Name>.icon` (Icon Composer) into the app target.
///   2. Add its name to `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`.
///   3. Add an `AppIconPreview<Name>` imageset with a 1024×1024 render.
///   4. Add a case below.
enum AppIconOption: String, CaseIterable, Identifiable {
    /// `nil` alternate name means the primary icon.
    case `default`

    var id: String { rawValue }

    /// Alternate icon name as declared in the asset catalog build settings.
    var alternateName: String? {
        switch self {
        case .default: return nil
        }
    }

    /// Preview thumbnail imageset bundled for the picker.
    var previewImageName: String {
        switch self {
        case .default: return "AppIconPreviewDefault"
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .default: return "app_icon.default"
        }
    }

    static var current: AppIconOption {
        let name = UIApplication.shared.alternateIconName
        return AppIconOption.allCases.first { $0.alternateName == name } ?? .default
    }

    /// True while the app has nothing to choose between. The picker shows an
    /// empty state rather than a list of one.
    static var hasAlternates: Bool {
        allCases.contains { $0.alternateName != nil }
    }
}

@MainActor
final class AppIconManager: ObservableObject {
    static let shared = AppIconManager()

    @Published private(set) var selected: AppIconOption

    private init() {
        selected = AppIconOption.current
    }

    var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    func setIcon(_ option: AppIconOption) {
        guard supportsAlternateIcons else { return }
        guard option.alternateName != UIApplication.shared.alternateIconName else {
            selected = option
            return
        }

        UIApplication.shared.setAlternateIconName(option.alternateName) { error in
            let succeeded = error == nil
            Task { @MainActor [weak self] in
                // On failure fall back to what the system actually has, so the
                // checkmark never claims an icon that was not applied.
                self?.selected = succeeded ? option : AppIconOption.current
            }
        }
    }
}

struct AppIconPickerView: View {
    @StateObject private var manager = AppIconManager.shared

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
                if AppIconOption.hasAlternates {
                    FICard {
                        ForEach(Array(AppIconOption.allCases.enumerated()), id: \.element.id) { index, option in
                            if index > 0 {
                                FIRowSeparator()
                            }

                            Button {
                                manager.setIcon(option)
                            } label: {
                                iconRow(option)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !manager.supportsAlternateIcons {
                        FIFootnote("app_icon.unsupported")
                    }
                } else {
                    FICard {
                        FIEmptyState(
                            title: "app_icon.empty",
                            subtitle: "app_icon.empty.subtitle"
                        )
                    }
                }
            }
            .fiCardInsets()
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .fiPageBackground()
        .navigationTitle(Text("app_icon.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Standard row with a small icon preview on the left.
    private func iconRow(_ option: AppIconOption) -> some View {
        let isSelected = manager.selected == option

        return HStack(spacing: 14) {
            Image(option.previewImageName)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text(option.titleKey)
                .font(FITheme.Typography.rowTitle)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FITheme.Palette.accent)
            }
        }
        .padding(.horizontal, FITheme.Metrics.cardInset)
        .padding(.vertical, 10)
        .frame(minHeight: FITheme.Metrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}
