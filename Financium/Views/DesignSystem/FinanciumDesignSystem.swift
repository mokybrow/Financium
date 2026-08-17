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

/// Row with a filled bar under it — a goal or a budget.
///
/// The bar is the point of the row: "38 000 ₽ left" is a number the reader has
/// to hold against the target to mean anything, while a bar answers "how far
/// along am I" before the text is read at all. It stays visible past 100% so an
/// exceeded goal reads as full rather than as an empty bar that wrapped around.
struct FIProgressRow: View {
    let title: Text
    var subtitle: Text?
    var trailing: Text?
    var trailingColor: Color = .secondary
    /// Unclamped: values above 1 are expected and the bar handles them.
    let progress: Double
    var tint: Color = FITheme.Palette.accent

    /// Title above, bar in the middle, figures below.
    ///
    /// The title and the status used to share one line, and neither fitted: a
    /// budget called "Мобильный интернет" shrank until it was unreadable so
    /// that "превышен на 500 ₽" could sit beside it, and the status was
    /// truncated anyway. They are two different things — what this is, and how
    /// it is going — and each now has the width of the row to say it in. The
    /// title may run to two lines rather than shrink, because a name is read,
    /// not measured.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            title
                .font(FITheme.Typography.rowTitle)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(FITheme.Palette.controlFill)

                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * min(max(progress, 0), 1))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)

            if subtitle != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if let subtitle {
                        subtitle
                            .font(FITheme.Typography.rowSubtitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }

                    Spacer(minLength: 0)

                    if let trailing {
                        trailing
                            .font(FITheme.Typography.rowSubtitle)
                            .foregroundStyle(trailingColor)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, FITheme.Metrics.cardInset)
        .padding(.vertical, FITheme.Metrics.rowVerticalPadding)
        .frame(minHeight: FITheme.Metrics.rowMinHeight)
        .contentShape(Rectangle())
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

/// Row whose trailing side is a date chip — the `Payment Day  [June 2024]`
/// pattern.
///
/// A compact `DatePicker` rather than a hand-drawn chip: it already renders as
/// the grey capsule in the mock-up, and tapping it opens the real system
/// calendar with all its keyboard, locale and accessibility behaviour.
struct FIDateRow: View {
    private let title: Text
    @Binding private var date: Date

    init(_ titleKey: LocalizedStringKey, date: Binding<Date>) {
        self.title = Text(titleKey)
        self._date = date
    }

    var body: some View {
        FIListRow(title: title) {
            DatePicker("", selection: $date, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(FITheme.Palette.accent)
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
    private let centred: Bool
    private let action: () -> Void

    init(
        _ titleKey: LocalizedStringKey,
        tint: Color = FITheme.Palette.accent,
        symbol: String? = nil,
        centred: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = Text(titleKey)
        self.tint = tint
        self.symbol = symbol
        self.centred = centred
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                title
                    .font(FITheme.Typography.rowTitle)
                    .foregroundStyle(symbol == nil ? tint : .primary)
                    .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)

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
                        .tint(.primary)
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
                // The same size as every other row's text. It used to be
                // `.title3`, so "Opening balance" sat visibly larger than
                // "Name" one row above it in the same card.
                .font(FITheme.Typography.rowTitle)
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
                        .font(.system(size: 17))
                        .foregroundStyle(Color.secondary.opacity(0.55))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("common.clear"))
            }
        }
        // Matched to FITextFieldRow so an amount row and a text row are the
        // same height in the same card.
        .padding(.horizontal, FITheme.Metrics.cardInset)
        .padding(.vertical, FITheme.Metrics.rowVerticalPadding)
        .frame(minHeight: FITheme.Metrics.rowMinHeight)
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
/// A plain toolbar icon button.
///
/// Toolbar glyphs are black, not blue. Blue is reserved for the one button that
/// commits something — the confirm button on a sheet — so that colour keeps
/// meaning "this is the action" instead of "this is tappable". `.tint` has to be
/// set as well as `foregroundStyle`: a menu inherits the ambient tint for its
/// own rows, and without it they come out looking disabled.
struct FIToolbarButton: View {
    let systemImage: String
    let accessibilityLabel: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .tint(.primary)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

/// The same glyph treatment, for a toolbar button that opens a menu.
struct FIToolbarMenu<Content: View>: View {
    let systemImage: String
    let accessibilityLabel: LocalizedStringKey
    @ViewBuilder let menuContent: () -> Content

    var body: some View {
        Menu {
            menuContent()
        } label: {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .tint(.primary)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

struct FIToolbarAddButton<Content: View>: View {
    @ViewBuilder let menuContent: () -> Content

    var body: some View {
        FIToolbarMenu(systemImage: "plus", accessibilityLabel: "common.add", menuContent: menuContent)
    }
}

extension View {
    /// Surfaces whatever the store last failed at.
    ///
    /// Only Money used to carry this, so a rejected save on Budget or Goals
    /// left the sheet sitting there with no explanation — the write had failed
    /// and the app said nothing.
    func fiErrorAlert(_ message: Binding<String?>) -> some View {
        alert(Text("common.error"), isPresented: Binding(
            get: { message.wrappedValue != nil },
            // Cleared on the next turn of the run loop, not inside the setter.
            //
            // SwiftUI calls this while it is deciding what the alert should be,
            // which is part of the view update — and the value being written is
            // `@Published` on the store, so writing it there is a change
            // published from within an update. That is what the warning said,
            // and it is undefined rather than merely untidy: the update is
            // reading the same object it is being asked to change.
            set: { presented in
                guard !presented else { return }
                Task { @MainActor in message.wrappedValue = nil }
            }
        )) {
            Button("common.ok", role: .cancel) {
                // The button's action runs after the update, so this one is
                // free to write straight away — and it is what normally clears
                // the message; the setter above is the path taken when the
                // alert is dismissed some other way.
                message.wrappedValue = nil
            }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

/// Empty-state placeholder, matching the tone of the rest of the app.
/// Shown in place of a screen's content when there is nothing to list.
///
/// No card behind it: a white rectangle containing only the words "no accounts
/// yet" is a container drawn around an absence. Without one the text sits on
/// the page and centres in the space the list would have filled, which is where
/// the eye goes when a screen is empty.
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, FITheme.Metrics.cardInset)
        // Laid over a scroll view, so it must not swallow taps meant for the
        // month chip underneath it.
        .allowsHitTesting(false)
        // Sized by whatever it is laid over rather than by a container-relative
        // height: as a sibling inside the scroll view's stack it measured a
        // whole viewport *plus* the rows above it, so the screen scrolled and
        // the text sat below the fold instead of in the middle of it. Call
        // sites put this in an `.overlay` on the scroll view, which is exactly
        // the box it should centre in.
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

    /// Long-press menu on a row inside a card. The opaque background is what
    /// keeps the lifted preview from showing the page through it.
    ///
    /// The menu's tint is reset to `.primary` and then to `.red` for
    /// destructive items: rows sit inside buttons that carry the accent tint,
    /// and a menu inherits the ambient tint — which was repainting the delete
    /// item's trash glyph blue, so the one item that should look dangerous
    /// looked like every other one.
    func fiRowContextMenu<MenuItems: View>(@ViewBuilder menuItems: () -> MenuItems) -> some View {
        background(FITheme.Palette.card)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: FITheme.Metrics.cardRadius, style: .continuous))
            .contextMenu { menuItems().tint(.primary) }
    }
}

/// A menu item that deletes something.
///
/// `Button(role: .destructive)` alone leaves the icon on the ambient tint
/// inside a tinted container, so the label went red while the trash stayed
/// blue. Tinting the item destructive makes both agree.
struct FIDestructiveMenuButton: View {
    let titleKey: LocalizedStringKey
    var systemImage: String = "trash"
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label(titleKey, systemImage: systemImage)
        }
        .tint(FITheme.Palette.destructive)
    }
}

/// A destructive action that asks first.
///
/// Deleting an account, a budget or a transaction is one tap in a context menu
/// — a menu that opens on a long press, which is easy to trigger by accident
/// while scrolling — and none of it can be undone. The alert is the only thing
/// standing between a slipped thumb and somebody's records.
///
/// A modifier rather than four alerts written four times: the wording, the
/// role and the cancel button are the same everywhere, and the only thing that
/// differs is what gets deleted.
struct FIDeleteConfirmation<Item: Identifiable>: ViewModifier {
    @Binding var item: Item?
    let title: LocalizedStringKey
    let perform: (Item) -> Void

    func body(content: Content) -> some View {
        content.alert(
            Text(title),
            isPresented: Binding(
                get: { item != nil },
                // Cleared on the next turn of the run loop: SwiftUI calls this
                // while deciding what the alert should be, and writing state
                // from inside a view update is undefined.
                set: { presented in
                    guard !presented else { return }
                    Task { @MainActor in item = nil }
                }
            ),
            presenting: item
        ) { target in
            Button("common.delete", role: .destructive) {
                perform(target)
                item = nil
            }
            Button("common.cancel", role: .cancel) { item = nil }
        } message: { _ in
            Text("common.delete.message")
        }
    }
}

extension View {
    /// Asks before deleting `item`, then hands it to `perform`.
    func fiConfirmDelete<Item: Identifiable>(
        _ item: Binding<Item?>,
        title: LocalizedStringKey = "common.delete.confirm",
        perform: @escaping (Item) -> Void
    ) -> some View {
        modifier(FIDeleteConfirmation(item: item, title: title, perform: perform))
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
