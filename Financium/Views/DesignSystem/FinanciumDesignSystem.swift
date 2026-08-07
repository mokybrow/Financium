import SwiftUI
import UIKit

// MARK: - Design tokens

/// Central design tokens taken from the Financium mock-ups. Everything visual —
/// radii, insets, palette, typography — lives here so the app can be re-skinned
/// from one place.
enum FITheme {

    // MARK: Metrics

    enum Metrics {
        /// Screen edge to card edge.
        static let screenInset: CGFloat = 20
        /// Text that sits *outside* a card — section headers, footnotes — is
        /// already inside a stack carrying `screenInset`, so it only needs the
        /// card's own inner padding to line up with the text inside one.
        /// Adding a full 36 on top of the stack pushed it out to 56.
        static let textInset: CGFloat = cardInset
        /// Inner padding of a card.
        static let cardInset: CGFloat = 16
        static let cardRadius: CGFloat = 22
        /// Small pills: the month chip, the payment-day chip.
        static let pillRadius: CGFloat = 16
        static let rowVerticalPadding: CGFloat = 13
        static let rowMinHeight: CGFloat = 44
        /// Between stacked cards and sections.
        static let sectionSpacing: CGFloat = 20
        /// Between a section header and its card.
        static let headerSpacing: CGFloat = 8
        /// Diameter of the round sheet-header buttons.
        static let sheetButtonSize: CGFloat = 36
    }

    // MARK: Palette

    enum Palette {
        static var pageBackground: Color {
            Color(UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor.systemBackground
                    : UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1) // #F2F2F7
            })
        }

        static var card: Color {
            Color(UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor.secondarySystemBackground
                    : UIColor.white
            })
        }

        /// Hairline between rows inside a card.
        static var rowSeparator: Color {
            Color(UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor.separator.withAlphaComponent(0.55)
                    : UIColor(white: 0.88, alpha: 1)
            })
        }

        /// Neutral fill: the month chip, the close button, number-pad tray.
        static var controlFill: Color {
            Color(UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor.tertiarySystemFill
                    : UIColor(red: 0.898, green: 0.898, blue: 0.918, alpha: 1) // #E5E5EA
            })
        }

        /// Interactive blue — currency selector, confirm button, symbols.
        static let accent = Color(red: 0.0, green: 0.478, blue: 1.0) // #007AFF
        static let positive = Color(red: 0.204, green: 0.780, blue: 0.349) // #34C759
        static let destructive = Color(red: 1.0, green: 0.231, blue: 0.188) // #FF3B30
    }

    // MARK: Typography

    enum Typography {
        /// Screen title: "Money", "Budget", "Goals", "Profile".
        static let screenTitle = Font.largeTitle.bold()
        /// Header standing alone on the page: "Accounts", "Accounts Activity".
        static let sectionHeader = Font.system(.title3, design: .default).weight(.bold)
        /// Header above a settings card: "General", "Security".
        static let groupHeader = Font.headline.weight(.bold)
        static let rowTitle = Font.body
        /// Grey line under a row title: a balance, "3 600,00 left".
        static let rowSubtitle = Font.subheadline
        /// Trailing value of a row: "Edit", "RUB", an amount.
        static let rowValue = Font.body
        static let footnote = Font.subheadline
        static let sheetTitle = Font.headline.weight(.semibold)
    }
}

// MARK: - Card container

/// White rounded container that groups rows.
struct FICard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FITheme.Palette.card)
        // Clipping rather than a rounded background keeps rows that paint their
        // own background — context-menu rows — inside the rounded corners.
        .clipShape(RoundedRectangle(cornerRadius: FITheme.Metrics.cardRadius, style: .continuous))
    }
}

/// Hairline divider between rows inside `FICard`. Inset to the text, not to the
/// card edge, which is what the mock-ups show.
struct FIRowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(FITheme.Palette.rowSeparator)
            .frame(height: 0.5)
            .padding(.horizontal, FITheme.Metrics.cardInset)
    }
}

// MARK: - Headers and footnotes

struct FISectionHeader: View {
    private let title: Text

    init(_ key: LocalizedStringKey) { self.title = Text(key) }
    init(verbatim value: String) { self.title = Text(verbatim: value) }

    var body: some View {
        title
            .font(FITheme.Typography.sectionHeader)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FITheme.Metrics.textInset)
    }
}

/// Grey explanatory text under a card.
struct FIFootnote: View {
    private let text: Text

    init(_ key: LocalizedStringKey) { self.text = Text(key) }
    init(verbatim value: String) { self.text = Text(verbatim: value) }

    var body: some View {
        text
            .font(FITheme.Typography.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FITheme.Metrics.textInset)
    }
}

// MARK: - Rows

/// What sits at the trailing edge of a row.
enum FIRowAccessory {
    case none
    /// Plain grey text: a balance, a currency code.
    case value(Text)
    case chevron
    /// Grey text plus a chevron — the "Edit ›" pattern.
    case valueChevron(Text)
    /// Value plus the up/down chevrons that mean "this opens a menu".
    case menu(Text)
    case symbol(name: String, color: Color)
    case checkmark
}

struct FIRowAccessoryView: View {
    let accessory: FIRowAccessory

    var body: some View {
        switch accessory {
        case .none:
            EmptyView()

        case .value(let text):
            text
                .font(FITheme.Typography.rowValue)
                .foregroundStyle(.secondary)
                .lineLimit(1)

        case .chevron:
            FIChevron()

        case .valueChevron(let text):
            HStack(spacing: 6) {
                text
                    .font(FITheme.Typography.rowValue)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                FIChevron()
            }

        case .menu(let text):
            HStack(spacing: 6) {
                text
                    .font(FITheme.Typography.rowValue)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

        case .symbol(let name, let color):
            Image(systemName: name)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)

        case .checkmark:
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(FITheme.Palette.accent)
        }
    }
}

struct FIChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}

/// Standard row: title, optional grey subtitle under it, trailing accessory.
struct FIListRow<Trailing: View>: View {
    private let title: Text
    private let subtitle: Text?
    private let titleColor: Color
    private let trailing: Trailing

    init(
        title: Text,
        subtitle: Text? = nil,
        titleColor: Color = .primary,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.titleColor = titleColor
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(FITheme.Typography.rowTitle)
                    .foregroundStyle(titleColor)

                if let subtitle {
                    subtitle
                        .font(FITheme.Typography.rowSubtitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.horizontal, FITheme.Metrics.cardInset)
        .padding(.vertical, FITheme.Metrics.rowVerticalPadding)
        .frame(minHeight: FITheme.Metrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

extension FIListRow where Trailing == FIRowAccessoryView {
    init(
        title: Text,
        subtitle: Text? = nil,
        titleColor: Color = .primary,
        accessory: FIRowAccessory = .none
    ) {
        self.init(title: title, subtitle: subtitle, titleColor: titleColor) {
            FIRowAccessoryView(accessory: accessory)
        }
    }

    init(
        _ titleKey: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        titleColor: Color = .primary,
        accessory: FIRowAccessory = .none
    ) {
        self.init(
            title: Text(titleKey),
            subtitle: subtitle.map { Text($0) },
            titleColor: titleColor,
            accessory: accessory
        )
    }
}

/// Row whose trailing side is a switch.
struct FIToggleRow: View {
    private let title: Text
    private let subtitle: Text?
    @Binding private var isOn: Bool

    init(_ titleKey: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, isOn: Binding<Bool>) {
        self.title = Text(titleKey)
        self.subtitle = subtitle.map { Text($0) }
        self._isOn = isOn
    }

    var body: some View {
        FIListRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(FITheme.Palette.positive)
        }
    }
}

/// Row whose trailing side opens an inline menu — the `Category ⌃⌄` pattern.
struct FIMenuRow<Content: View>: View {
    private let title: Text
    private let value: Text
    private let menuContent: Content

    init(_ titleKey: LocalizedStringKey, value: String, @ViewBuilder menuContent: () -> Content) {
        self.title = Text(titleKey)
        self.value = Text(verbatim: value)
        self.menuContent = menuContent()
    }

    init(title: Text, value: Text, @ViewBuilder menuContent: () -> Content) {
        self.title = title
        self.value = value
        self.menuContent = menuContent()
    }

    var body: some View {
        Menu {
            menuContent
        } label: {
            FIListRow(title: title, accessory: .menu(value))
        }
        // The menu inherits the ambient tint otherwise, and its rows come out
        // looking disabled.
        .tint(.primary)
    }
}

/// A row that is entirely a text field, with the placeholder standing in for the
/// label.
///
/// A name has no short value to show on the right, so splitting the row into
/// "Name" plus a cramped trailing field wastes the width and gives the caret a
/// few characters to live in. The placeholder already says what the field is.
struct FITextFieldRow: View {
    private let placeholder: LocalizedStringKey
    @Binding private var text: String
    private let axis: Axis
    private let showsClearButton: Bool

    init(
        _ placeholder: LocalizedStringKey,
        text: Binding<String>,
        axis: Axis = .horizontal,
        showsClearButton: Bool = true
    ) {
        self.placeholder = placeholder
        self._text = text
        self.axis = axis
        self.showsClearButton = showsClearButton
    }

    var body: some View {
        HStack(spacing: 12) {
            TextField(placeholder, text: $text, axis: axis)
                .font(FITheme.Typography.rowTitle)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showsClearButton, !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.secondary.opacity(0.55))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("common.clear"))
            }
        }
        .padding(.horizontal, FITheme.Metrics.cardInset)
        .padding(.vertical, FITheme.Metrics.rowVerticalPadding)
        .frame(minHeight: FITheme.Metrics.rowMinHeight)
    }
}

/// Row that is a single action: "Add Category  +", or a destructive "Delete".
struct FIInlineActionRow: View {
    private let title: Text
    private let tint: Color
    private let symbol: String?
    private let action: () -> Void

    init(_ titleKey: LocalizedStringKey, tint: Color = FITheme.Palette.accent, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = Text(titleKey)
        self.tint = tint
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                title
                    .font(FITheme.Typography.rowTitle)
                    .foregroundStyle(symbol == nil ? tint : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let symbol {
                    Image(systemName: symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(tint)
                }
            }
            .padding(.horizontal, FITheme.Metrics.cardInset)
            .padding(.vertical, FITheme.Metrics.rowVerticalPadding)
            .frame(minHeight: FITheme.Metrics.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Full-width centred action row — the "Log out" button.
///
/// Centred rather than leading-aligned because it is the only thing in its card
/// and reads as a button, not as a setting with a value.
struct FIDestructiveRow: View {
    private let title: Text
    private let action: () -> Void

    init(_ titleKey: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = Text(titleKey)
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            title
                .font(FITheme.Typography.rowTitle)
                .foregroundStyle(FITheme.Palette.destructive)
                .frame(maxWidth: .infinity)
                .padding(.vertical, FITheme.Metrics.rowVerticalPadding)
                .frame(minHeight: FITheme.Metrics.rowMinHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chips

/// The grey month chip under the screen title.
struct FIMonthChip: View {
    let title: String
    var action: (() -> Void)? = nil

    var body: some View {
        let label = Text(verbatim: title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(FITheme.Palette.controlFill, in: Capsule())

        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
        } else {
            label
        }
    }
}

/// The blue currency selector at the trailing edge of the month row.
struct FICurrencyMenu<Content: View>: View {
    let code: String
    @ViewBuilder let menuContent: () -> Content

    var body: some View {
        Menu {
            menuContent()
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: code)
                    .font(.headline.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(FITheme.Palette.accent)
        }
    }
}

// MARK: - Sheet chrome

/// Native sheet chrome: an inline title with a system close button on the left
/// and a confirm button on the right.
///
/// The mock-ups draw those as a grey circle and a filled blue circle, which is
/// exactly what iOS 26's `ButtonRole.close` and `.confirm` render — so this uses
/// the real toolbar instead of a hand-built header. That also means the title
/// truncates, the buttons get their standard hit areas and VoiceOver labels, and
/// the glass background behaves like it does everywhere else.
enum FISheetConfirm {
    /// No trailing button.
    case none
    /// Checkmark confirm button, disabled until the form is valid.
    case confirm(isEnabled: Bool, action: () -> Void)
}

extension View {
    func fiSheetChrome(
        title: Text,
        confirm: FISheetConfirm = .none,
        onClose: @escaping () -> Void
    ) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close, action: onClose)
                }

                ToolbarItem(placement: .confirmationAction) {
                    switch confirm {
                    case .none:
                        EmptyView()
                    case .confirm(let isEnabled, let action):
                        Button(role: .confirm, action: action)
                            .disabled(!isEnabled)
                            .tint(FITheme.Palette.accent)
                    }
                }
            }
            // Toolbar glyphs otherwise inherit the accent and come out blue.
            .tint(.primary)
    }

    func fiSheetChrome(
        _ titleKey: LocalizedStringKey,
        confirm: FISheetConfirm = .none,
        onClose: @escaping () -> Void
    ) -> some View {
        fiSheetChrome(title: Text(titleKey), confirm: confirm, onClose: onClose)
    }
}

// MARK: - Amount entry

/// The amount line of an editor sheet.
///
/// A plain `TextField` on the decimal pad: the mock-up's number pad *is* the
/// system decimal pad, so there is nothing to hand-build. Using the real field
/// means focus, the caret, selection, dictation, paste and Dynamic Type all
/// behave the way they do everywhere else in iOS.
struct FIAmountRow: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey = "common.amount"

    var body: some View {
        HStack(spacing: 12) {
            TextField(placeholder, text: $text)
                .font(.title3)
                .monospacedDigit()
                .keyboardType(.decimalPad)
                .onChange(of: text) { _, newValue in
                    text = Self.sanitize(newValue)
                }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("common.clear"))
            }
        }
        .padding(.horizontal, FITheme.Metrics.cardInset)
        .padding(.vertical, 14)
        .frame(minHeight: 52)
    }

    /// Keeps the field to a well-formed amount as it is typed.
    ///
    /// The decimal pad still lets a user paste letters or a second separator,
    /// and the field must never show a number different from the one that will
    /// be saved.
    static func sanitize(_ raw: String, fractionDigits: Int = 2) -> String {
        let separator = Locale.current.decimalSeparator ?? "."
        // Accept either separator on input — a paste or a hardware keyboard can
        // produce the other one — and normalise to the locale's.
        var value = raw.replacingOccurrences(of: separator == "." ? "," : ".", with: separator)
        value = value.filter { $0.isNumber || String($0) == separator }

        let parts = value.components(separatedBy: separator)
        guard parts.count > 1 else { return value }

        let whole = parts[0]
        let fraction = String(parts.dropFirst().joined().prefix(fractionDigits))
        return whole + separator + fraction
    }
}

// MARK: - Buttons

/// The round white "+" in the top-right corner of every list screen.
struct FIToolbarAddButton<Content: View>: View {
    @ViewBuilder let menuContent: () -> Content

    var body: some View {
        Menu {
            menuContent()
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .tint(.primary)
    }
}

/// Empty-state placeholder, matching the tone of the rest of the app.
struct FIEmptyState: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(.title3, design: .default).weight(.bold))
                .foregroundStyle(.secondary)

            if let subtitle {
                Text(subtitle)
                    .font(FITheme.Typography.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, FITheme.Metrics.cardInset)
    }
}

// MARK: - Layout helpers

extension View {
    /// Paints the page background behind a screen.
    func fiPageBackground() -> some View {
        background(FITheme.Palette.pageBackground.ignoresSafeArea())
    }

    /// Standard horizontal inset for a stack of cards.
    func fiCardInsets() -> some View {
        padding(.horizontal, FITheme.Metrics.screenInset)
    }

    /// Long-press menu on a card, with the preview clipped to the card's own
    /// shape so the highlight does not overhang its corners.
    func fiCardContextMenu<MenuItems: View>(
        cornerRadius: CGFloat = FITheme.Metrics.cardRadius,
        @ViewBuilder menuItems: () -> MenuItems
    ) -> some View {
        contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contextMenu(menuItems: menuItems)
    }

    /// Long-press menu on a row inside a card. The opaque background is what
    /// keeps the lifted preview from showing the page through it.
    func fiRowContextMenu<MenuItems: View>(@ViewBuilder menuItems: () -> MenuItems) -> some View {
        background(FITheme.Palette.card)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: FITheme.Metrics.cardRadius, style: .continuous))
            .contextMenu(menuItems: menuItems)
    }
}

/// Section = header + card + optional footnote, the shape most screens repeat.
struct FISection<Content: View>: View {
    private let header: Text?
    private let footnote: Text?
    private let content: Content

    init(header: Text? = nil, footnote: Text? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footnote = footnote
        self.content = content()
    }

    init(_ headerKey: LocalizedStringKey, footnote: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.init(header: Text(headerKey), footnote: footnote.map { Text($0) }, content: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FITheme.Metrics.headerSpacing) {
            if let header {
                header
                    .font(FITheme.Typography.groupHeader)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, FITheme.Metrics.cardInset)
            }

            FICard {
                content
            }

            if let footnote {
                footnote
                    .font(FITheme.Typography.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, FITheme.Metrics.cardInset)
                    .padding(.top, 2)
            }
        }
    }
}
