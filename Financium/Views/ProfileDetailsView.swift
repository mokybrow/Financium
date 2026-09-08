import PhotosUI
import SwiftUI

struct ProfileDetailsView: View {
    @EnvironmentObject private var profile: ProfileStore
    @State private var editing = false
    @State private var name = ""
    @State private var monogramStyle: ProfileStore.MonogramStyle = .classic
    @State private var color = Color.yellow
    @State private var originalColor = Color.yellow
    @State private var photo: UIImage?
    @State private var item: PhotosPickerItem?
    @State private var pickingPhoto = false
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var liveZoom: CGFloat = 1
    @GestureState private var liveOffset: CGSize = .zero
    @State private var side: CGFloat = 360

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GeometryReader { proxy in
                    ZStack {
                        Color.white
                        if let image = editing ? photo : profile.photo {
                            let scale = editing ? min(max(zoom * liveZoom, 1), 5) : 1
                            let factor = max(proxy.size.width / image.size.width, proxy.size.width / image.size.height) * scale
                            Image(uiImage: image).resizable()
                                .frame(width: image.size.width * factor, height: image.size.height * factor)
                                .offset(editing ? constrainedOffset(image, side: proxy.size.width, scale: scale,
                                    proposed: CGSize(width: offset.width + liveOffset.width, height: offset.height + liveOffset.height)) : .zero)
                        } else {
                            (editing ? color : Color(hex: profile.colorHex) ?? FITheme.Palette.controlFill)
                            FIMonogram(
                                text: ProfileStore.monogram(for: editing ? name : profile.name),
                                style: editing ? monogramStyle : profile.monogramStyle,
                                size: proxy.size.width
                            )
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.width)
                    .overlay {
                        if editing && photo != nil {
                            Path { path in
                                for step in 1...2 {
                                    let coordinate = proxy.size.width * CGFloat(step) / 3
                                    path.move(to: CGPoint(x: coordinate, y: 0))
                                    path.addLine(to: CGPoint(x: coordinate, y: proxy.size.width))
                                    path.move(to: CGPoint(x: 0, y: coordinate))
                                    path.addLine(to: CGPoint(x: proxy.size.width, y: coordinate))
                                }
                            }
                            .stroke(.white.opacity(0.8), lineWidth: 1)
                            .shadow(color: .black.opacity(0.4), radius: 1)
                            .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { side = $0; clampOffset() }
                    .gesture(MagnifyGesture().updating($liveZoom) { value, state, _ in if editing { state = value.magnification } }.onEnded { value in if editing { zoom = min(max(zoom * value.magnification, 1), 5); clampOffset() } })
                    .simultaneousGesture(DragGesture().updating($liveOffset) { value, state, _ in if editing { state = value.translation } }.onEnded { value in if editing { offset.width += value.translation.width; offset.height += value.translation.height; clampOffset() } })
                }.aspectRatio(1, contentMode: .fit)
                // Both the editing and the read-only controls stay mounted the
                // whole time and are only shown or hidden. Building a TextField
                // or a ColorPicker from scratch on the Edit tap is what made the
                // toolbar's Edit → checkmark morph drop frames.
                FISection("profile.name") {
                    ZStack {
                        FITextFieldRow("profile.name", text: $name)
                            .opacity(editing ? 1 : 0).allowsHitTesting(editing)
                        FIListRow(title: Text(profile.name))
                            .opacity(editing ? 0 : 1).allowsHitTesting(!editing)
                    }
                }
                FISection("profile.appearance.avatar") {
                    ZStack {
                        VStack(spacing: 0) {
                            FIMenuRow(title: Text("profile.appearance.monogram"), value: Text(monogramStyle.titleKey), icon: "textformat") {
                                Picker("profile.appearance.monogram", selection: $monogramStyle) {
                                    ForEach(ProfileStore.MonogramStyle.allCases) { style in
                                        Text(style.titleKey).tag(style)
                                    }
                                }
                            }
                            FIRowSeparator()
                            ColorPicker("profile.appearance.background", selection: $color, supportsOpacity: false).padding(16)
                        }
                        .opacity(editing ? 1 : 0).allowsHitTesting(editing)
                        VStack(spacing: 0) {
                            FIListRow("profile.appearance.monogram", icon: "textformat")
                            FIRowSeparator()
                            FIListRow("profile.appearance.background", icon: "paintpalette")
                        }
                        .opacity(editing ? 0 : 1).allowsHitTesting(!editing)
                    }
                }
                FIFootnote("home.profile.hint")
            }.fiCardInsets().padding(.vertical, 12)
        }
        .fiPageBackground()
        .navigationTitle(Text("profile.title")).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(editing)
        .toolbar {
            // One trailing slot, one stable id: the plain "Edit" text button and
            // the round prominent confirm button live in the *same* item, so
            // SwiftUI crossfades one into the other instead of removing one item
            // and inserting another.
            ToolbarItem(id: "profile.trailing", placement: .confirmationAction) {
                if editing {
                    Button(role: .confirm) {
                        save()
                        withAnimation(.snappy) { editing = false }
                    }
                    .disabled(!hasChanges)
                    .accessibilityLabel(Text("common.save"))
                } else {
                    Button("profile.edit.action") {
                        beginEditing()
                        withAnimation(.snappy) { editing = true }
                    }
                    .tint(.primary)
                }
            }
            ToolbarItem(id: "profile.cancel", placement: .cancellationAction) {
                if editing {
                    Button(role: .close) {
                        item = nil
                        withAnimation(.snappy) { editing = false }
                    }
                    .tint(.primary)
                    .accessibilityLabel(Text("common.cancel"))
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if editing {
                    Button { rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }.tint(.primary).disabled(photo == nil).accessibilityLabel(Text("profile.photo.rotate_left"))
                    Button { rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }.tint(.primary).disabled(photo == nil).accessibilityLabel(Text("profile.photo.rotate_right"))
                    Spacer()
                    Button { pickingPhoto = true } label: { Image(systemName: "photo") }.tint(.primary).accessibilityLabel(Text("profile.photo.replace"))
                    Button(role: .destructive) { photo = nil; zoom = 1; offset = .zero } label: { Image(systemName: "trash") }.tint(.primary).accessibilityLabel(Text("profile.photo.remove"))
                }
            }
        }
        .photosPicker(isPresented: $pickingPhoto, selection: $item, matching: .images)
        .task(id: item) {
            guard editing, let item, let data = try? await item.loadTransferable(type: Data.self), !Task.isCancelled, editing, let image = UIImage(data: data) else { return }
            photo = image; zoom = 1; offset = .zero
        }
    }
    private var hasChanges: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != profile.name
            || monogramStyle != profile.monogramStyle
            || !UIColor(color).isEqual(UIColor(originalColor))
            || photo !== profile.photo
            || (photo != nil && (zoom != 1 || offset != .zero))
    }

    private func constrainedOffset(_ image: UIImage, side: CGFloat, scale: CGFloat, proposed: CGSize) -> CGSize {
        let factor = max(side / image.size.width, side / image.size.height) * scale
        let maxX = max(0, (image.size.width * factor - side) / 2)
        let maxY = max(0, (image.size.height * factor - side) / 2)
        return CGSize(width: min(max(proposed.width, -maxX), maxX), height: min(max(proposed.height, -maxY), maxY))
    }

    private func clampOffset() {
        guard let photo else { offset = .zero; return }
        offset = constrainedOffset(photo, side: side, scale: zoom, proposed: offset)
    }

    private func beginEditing() {
        name = profile.name; monogramStyle = profile.monogramStyle; photo = profile.photo
        var hex = profile.colorHex; hex.removeAll { $0 == "#" }
        let value = UInt32(hex, radix: 16) ?? 0xF2C14E
        color = Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
        originalColor = color
        item = nil
        zoom = 1; offset = .zero
    }
    private func save() {
        profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.emoji = nil
        profile.monogramStyle = monogramStyle
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        profile.colorHex = String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        if let photo {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let result = UIGraphicsImageRenderer(size: CGSize(width: 720, height: 720), format: format).image { _ in
                let factor = max(720 / photo.size.width, 720 / photo.size.height) * zoom
                let width = photo.size.width * factor, height = photo.size.height * factor
                let dx = min(max(offset.width * 720 / side, -(width - 720) / 2), (width - 720) / 2)
                let dy = min(max(offset.height * 720 / side, -(height - 720) / 2), (height - 720) / 2)
                photo.draw(in: CGRect(x: (720 - width) / 2 + dx, y: (720 - height) / 2 + dy, width: width, height: height))
            }
            profile.setPhoto(result)
        } else { profile.setPhoto(nil) }
        profile.commit()
    }
    private func rotate(clockwise: Bool) {
        guard let image = photo else { return }
        let size = CGSize(width: image.size.height, height: image.size.width)
        photo = UIGraphicsImageRenderer(size: size).image { context in
            context.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            context.cgContext.rotate(by: clockwise ? .pi / 2 : -.pi / 2)
            image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width, height: image.size.height))
        }
        zoom = 1; offset = .zero
    }
}

