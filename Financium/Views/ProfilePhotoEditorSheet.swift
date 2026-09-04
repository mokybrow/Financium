import PhotosUI
import SwiftUI
import UIKit

/// Crop, zoom and rotate a photo before it becomes the avatar.
///
/// Ported from Eatometer's editor. The circle is the crop; everything outside
/// it is discarded. Pan and pinch position the photo inside it, the bottom bar
/// rotates in 90° steps, swaps the photo, or removes it.
struct ProfilePhotoEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let isNewPhoto: Bool
    let onSave: (UIImage) -> Void
    let onDelete: () -> Void

    @State private var image: UIImage
    @State private var replacementItem: PhotosPickerItem?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var rotationDegrees = 0
    @State private var previewSide: CGFloat = 300
    @State private var hasReplacement = false
    @GestureState private var liveScale: CGFloat = 1
    @GestureState private var liveOffset: CGSize = .zero

    init(image: UIImage, isNewPhoto: Bool, onSave: @escaping (UIImage) -> Void, onDelete: @escaping () -> Void) {
        _image = State(initialValue: image)
        self.isNewPhoto = isNewPhoto
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var displayedScale: CGFloat { min(max(scale * liveScale, 1), 5) }
    private var displayedOffset: CGSize {
        CGSize(width: offset.width + liveOffset.width, height: offset.height + liveOffset.height)
    }

    private var hasChanges: Bool {
        isNewPhoto || hasReplacement || scale != 1 || offset != .zero || rotationDegrees != 0
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                GeometryReader { proxy in
                    let side = min(proxy.size.width - 28, 380)
                    PhotoCropCanvas(
                        image: image,
                        scale: displayedScale,
                        offset: displayedOffset,
                        rotationDegrees: rotationDegrees,
                        referenceSide: side
                    )
                    .frame(width: side, height: side)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.16), lineWidth: 1))
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .onAppear { previewSide = side }
                    .onChange(of: side) { _, newSide in previewSide = newSide }
                    .simultaneousGesture(dragGesture)
                    .simultaneousGesture(magnificationGesture)
                }
                .frame(height: 400)

                Text("profile.photo.crop_hint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .fiPageBackground()
            .navigationTitle("profile.photo.editor")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: replacementItem) { _, item in replacePhoto(item) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }.tint(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm, action: save)
                        .disabled(!hasChanges)
                        .tint(FITheme.Palette.accent)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { rotate(by: -90) } label: {
                        Label("profile.photo.rotate_left", systemImage: "rotate.left").labelStyle(.iconOnly)
                    }
                    Button { rotate(by: 90) } label: {
                        Label("profile.photo.rotate_right", systemImage: "rotate.right").labelStyle(.iconOnly)
                    }
                    Spacer()
                    PhotosPicker(selection: $replacementItem, matching: .images) {
                        Label("profile.photo.replace", systemImage: "photo.on.rectangle").labelStyle(.iconOnly)
                    }
                    if !isNewPhoto {
                        Button(role: .destructive) {
                            onDelete()
                            dismiss()
                        } label: {
                            Label("profile.photo.remove", systemImage: "trash").labelStyle(.iconOnly)
                        }
                    }
                }
            }
            .toolbarBackground(.visible, for: .bottomBar)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .updating($liveOffset) { value, state, _ in state = value.translation }
            .onEnded { value in
                offset = clampedOffset(
                    CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height),
                    scale: scale
                )
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .updating($liveScale) { value, state, _ in state = value }
            .onEnded { value in
                scale = min(max(scale * value, 1), 5)
                offset = clampedOffset(offset, scale: scale)
            }
    }

    private func clampedOffset(_ candidate: CGSize, scale: CGFloat) -> CGSize {
        let imageWidth = max(image.size.width, 1)
        let imageHeight = max(image.size.height, 1)
        let aspectRatio = imageWidth / imageHeight
        var renderedWidth = aspectRatio >= 1 ? previewSide * aspectRatio : previewSide
        var renderedHeight = aspectRatio >= 1 ? previewSide : previewSide / aspectRatio

        if abs(rotationDegrees / 90).isMultiple(of: 2) == false {
            swap(&renderedWidth, &renderedHeight)
        }

        let horizontalLimit = max(0, (renderedWidth * scale - previewSide) / 2)
        let verticalLimit = max(0, (renderedHeight * scale - previewSide) / 2)
        return CGSize(
            width: min(max(candidate.width, -horizontalLimit), horizontalLimit),
            height: min(max(candidate.height, -verticalLimit), verticalLimit)
        )
    }

    private func rotate(by degrees: Int) {
        withAnimation(.snappy) {
            // Accumulate, never wrap: rotating past 270° should continue to
            // 360° and beyond, not snap back through 0.
            rotationDegrees += degrees
            offset = .zero
        }
    }

    private func replacePhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let replacement = UIImage(data: data) else { return }
            image = replacement
            hasReplacement = true
            scale = 1
            offset = .zero
            rotationDegrees = 0
        }
    }

    private func save() {
        let outputSide: CGFloat = 900
        let renderer = ImageRenderer(
            content: PhotoCropCanvas(
                image: image,
                scale: scale,
                offset: offset,
                rotationDegrees: rotationDegrees,
                referenceSide: previewSide
            )
            .frame(width: outputSide, height: outputSide)
        )
        renderer.scale = 1
        guard let rendered = renderer.uiImage else { return }
        onSave(rendered)
        dismiss()
    }
}

private struct PhotoCropCanvas: View {
    let image: UIImage
    let scale: CGFloat
    let offset: CGSize
    let rotationDegrees: Int
    let referenceSide: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let ratio = referenceSide > 0 ? side / referenceSide : 1
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .scaleEffect(scale)
                .rotationEffect(.degrees(Double(rotationDegrees)))
                .offset(x: offset.width * ratio, y: offset.height * ratio)
                .frame(width: side, height: side)
                .clipped()
        }
        .background(Color.black)
        .clipped()
    }
}
