import PhotosUI
import SwiftUI
import UIKit

/// The avatar workshop, reached from the pencil on the profile picture.
///
/// Photo, emoji, background colour, monogram style — the same set Eatometer
/// offers, laid out as one page with the colour wheel and style list one tap
/// deeper. Whatever the reader picks is written straight through
/// `ProfileStore`, which mirrors it to iCloud.
struct ProfileAppearanceEditorView: View {
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var photoItem: PhotosPickerItem?
    @State private var editorImage: UIImage?
    @State private var editorIsNew = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: FITheme.Metrics.sectionSpacing) {
                FIAvatar(
                    monogram: profile.monogram,
                    colorHex: profile.colorHex,
                    emoji: profile.emoji,
                    monogramStyle: profile.monogramStyle,
                    photo: profile.photo,
                    size: 190
                )
                .padding(.top, 12)

                FISection("profile.photo.editor") {
                    if profile.photo == nil {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            pickerRow("profile.photo.set", symbol: "photo.fill")
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            editorImage = profile.photo
                            editorIsNew = false
                        } label: {
                            pickerRow("profile.photo.set", value: "common.edit", symbol: "photo.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }

                FISection("profile.appearance.avatar") {
                    NavigationLink { AvatarBackgroundEditorView() } label: {
                        pickerRow("profile.appearance.background", value: "profile.appearance.choose")
                    }
                    .buttonStyle(.plain)

                    FIRowSeparator()

                    NavigationLink { AvatarMonogramEditorView() } label: {
                        pickerRow(
                            "profile.appearance.monogram",
                            value: "profile.appearance.choose"
                        )
                    }
                    .buttonStyle(.plain)
                }

                if profile.emoji != nil {
                    Button("profile.appearance.emoji_clear", role: .destructive) {
                        profile.setEmoji(nil)
                    }
                    .font(.footnote)
                }
            }
            .fiCardInsets()
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .fiPageBackground()
        .navigationTitle(Text("profile.title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) { dismiss() }.tint(.primary)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(role: .confirm) { dismiss() }.tint(FITheme.Palette.accent)
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    editorImage = image
                    editorIsNew = true
                }
                photoItem = nil
            }
        }
        .sheet(isPresented: Binding(get: { editorImage != nil }, set: { if !$0 { editorImage = nil } })) {
            if let editorImage {
                ProfilePhotoEditorSheet(
                    image: editorImage,
                    isNewPhoto: editorIsNew,
                    onSave: { profile.setPhoto($0) },
                    onDelete: { profile.setPhoto(nil) }
                )
            }
        }
    }

    private var emojiBinding: Binding<String> {
        Binding(
            get: { profile.emoji ?? "" },
            set: { profile.setEmoji($0) }
        )
    }

    /// "Title      Выбрать  [icon]  ›" — the row shape in the design.
    private func pickerRow(
        _ title: LocalizedStringKey,
        value: LocalizedStringKey? = nil,
        verbatimValue: String? = nil,
        symbol: String? = nil
    ) -> some View {
        FIListRow(title: Text(title)) {
            HStack(spacing: 8) {
                if let verbatimValue {
                    Text(verbatim: verbatimValue).font(.body)
                } else if let value {
                    Text(value).foregroundStyle(.secondary)
                }
                if let symbol {
                    Image(systemName: symbol)
                        .font(.body)
                        .foregroundStyle(FITheme.Palette.accent)
                }
                FIChevron()
            }
        }
    }
}

// MARK: - Background

private struct AvatarBackgroundEditorView: View {
    @EnvironmentObject private var profile: ProfileStore
    @State private var hue: CGFloat = 0
    @State private var saturation: CGFloat = 0

    var body: some View {
        VStack(spacing: 26) {
            FIAvatar(
                monogram: profile.monogram,
                colorHex: selectedHex,
                emoji: profile.emoji,
                monogramStyle: profile.monogramStyle,
                photo: nil,
                size: 150
            )
            AvatarColorWheel(hue: $hue, saturation: $saturation)
                .frame(width: 260, height: 260)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                ForEach(ProfileStore.palette, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex) ?? .gray)
                        .frame(width: 36, height: 36)
                        .overlay {
                            if hex.caseInsensitiveCompare(selectedHex) == .orderedSame {
                                Circle().stroke(.primary, lineWidth: 2).padding(-3)
                            }
                        }
                        .onTapGesture { apply(hex: hex) }
                }
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 0)
        }
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fiPageBackground()
        .navigationTitle(Text("profile.appearance.background"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { seedFromCurrent() }
        .onChange(of: hue) { _, _ in profile.colorHex = selectedHex; profile.commit() }
        .onChange(of: saturation) { _, _ in profile.colorHex = selectedHex; profile.commit() }
    }

    private var selectedHex: String {
        UIColor(hue: hue, saturation: saturation, brightness: 1, alpha: 1).financeHex
    }

    private func apply(hex: String) {
        guard let ui = UIColor(hexString: hex) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = h
        saturation = s
    }

    private func seedFromCurrent() {
        guard let ui = UIColor(hexString: profile.colorHex) else {
            hue = 0.13; saturation = 0.7; return
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = h
        saturation = s
    }
}

// MARK: - Monogram style

private struct AvatarMonogramEditorView: View {
    @EnvironmentObject private var profile: ProfileStore

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: FITheme.Metrics.sectionSpacing) {
                FIAvatar(
                    monogram: profile.monogram,
                    colorHex: profile.colorHex,
                    emoji: nil,
                    monogramStyle: profile.monogramStyle,
                    photo: nil,
                    size: 150
                )
                .padding(.top, 12)

                FICard {
                    ForEach(Array(ProfileStore.MonogramStyle.allCases.enumerated()), id: \.element.id) { index, style in
                        if index > 0 { FIRowSeparator() }
                        Button {
                            profile.monogramStyle = style
                            profile.commit()
                        } label: {
                            FIListRow(
                                title: Text(style.titleKey),
                                accessory: style == profile.monogramStyle ? .value(Text(verbatim: "✓")) : .none
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .fiCardInsets()
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .fiPageBackground()
        .navigationTitle(Text("profile.appearance.monogram"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Colour wheel

private struct AvatarColorWheel: View {
    @Binding var hue: CGFloat
    @Binding var saturation: CGFloat
    private let wheelColors: [Color] = [.red, .yellow, .green, .cyan, .blue, .purple, .red]
    private let indicatorDiameter: CGFloat = 28

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let radius = side / 2
            let angle = hue * .pi * 2
            let indicatorRadius = saturation * max(radius - indicatorDiameter / 2, 0)

            ZStack {
                Circle()
                    .fill(AngularGradient(colors: wheelColors, center: .center))
                    .overlay {
                        Circle().fill(
                            RadialGradient(
                                colors: [.white, .white.opacity(0)],
                                center: .center, startRadius: 0, endRadius: radius
                            )
                        )
                    }
                Circle()
                    .fill(Color(hue: Double(hue), saturation: Double(saturation), brightness: 1))
                    .frame(width: indicatorDiameter, height: indicatorDiameter)
                    .overlay(Circle().stroke(.white, lineWidth: 4))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .offset(x: cos(angle) * indicatorRadius, y: sin(angle) * indicatorRadius)
            }
            .frame(width: side, height: side)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { update(at: $0.location, in: proxy.size) }
            )
        }
    }

    private func update(at point: CGPoint, in size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radius = min(size.width, size.height) / 2
        saturation = min(max(hypot(dx, dy) / radius, 0), 1)
        var angle = atan2(dy, dx)
        if angle < 0 { angle += .pi * 2 }
        hue = angle / (.pi * 2)
    }
}

// MARK: - Emoji field

struct EmojiOnlyTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var fontSize: CGFloat = 34
    var isFocused: Binding<Bool> = .constant(false)

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, isFocused: isFocused) }

    func makeUIView(context: Context) -> EmojiKeyboardTextField {
        let field = EmojiKeyboardTextField()
        field.delegate = context.coordinator
        field.placeholder = placeholder
        field.text = text
        field.font = .systemFont(ofSize: fontSize)
        field.textAlignment = .center
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.returnKeyType = .done
        field.backgroundColor = .clear
        field.tintColor = .clear
        return field
    }

    func updateUIView(_ uiView: EmojiKeyboardTextField, context: Context) {
        if uiView.text != text { uiView.text = text }
        if isFocused.wrappedValue {
            guard uiView.window != nil, !uiView.isFirstResponder else { return }
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        } else if uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.resignFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String
        var isFocused: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            _text = text
            self.isFocused = isFocused
        }

        func textFieldDidBeginEditing(_ textField: UITextField) { isFocused.wrappedValue = true }
        func textFieldDidEndEditing(_ textField: UITextField) { isFocused.wrappedValue = false }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let current = textField.text ?? ""
            guard let stringRange = Range(range, in: current) else { return false }
            let updated = current.replacingCharacters(in: stringRange, with: string)
            let inserted = firstEmoji(string)
            let result = inserted.isEmpty ? firstEmoji(updated) : inserted
            text = result
            textField.text = result
            if !inserted.isEmpty {
                textField.resignFirstResponder()
                isFocused.wrappedValue = false
            }
            return false
        }

        func textFieldShouldClear(_ textField: UITextField) -> Bool {
            text = ""
            isFocused.wrappedValue = false
            return true
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            isFocused.wrappedValue = false
            return true
        }

        private func firstEmoji(_ value: String) -> String {
            for character in value where character.unicodeScalars.contains(where: {
                $0.properties.isEmojiPresentation || $0.properties.isEmoji
            }) {
                return String(character)
            }
            return ""
        }
    }
}

final class EmojiKeyboardTextField: UITextField {
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }
}

// MARK: - Colour helpers

private extension UIColor {
    convenience init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let int = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: CGFloat((int >> 16) & 0xFF) / 255,
            green: CGFloat((int >> 8) & 0xFF) / 255,
            blue: CGFloat(int & 0xFF) / 255,
            alpha: 1
        )
    }

    var financeHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#F2C14E" }
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}
