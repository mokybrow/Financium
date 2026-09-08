import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

struct FIPlanCoverTile: View {
    let title: String
    let amount: String
    let progress: Double
    let cover: FinancePlanCover
    var size: CGFloat = 160
    var showsTitle = true
    var showsAmount = true
    var shared = false
    var cornerRadius: CGFloat = 22
    var placeholderSymbol: String? = "photo"
    var contentTopInset: CGFloat = 0
    /// The "Photo by … on Unsplash" attribution. Off for small tiles where it
    /// would just be clutter.
    var showsCredit = false
    /// The fill line and the amount / percent row.
    var showsProgress = true
    /// Detail page: the name sits at the foot of the cover, above the credit,
    /// rather than at the top.
    var titleAtBottom = false
    @State private var image: UIImage?

    private enum ImageSource: Equatable {
        case none, data(Data), remote(URL)
    }
    private var imageSource: ImageSource {
        if let data = cover.photo { return .data(data) }
        if let url = cover.unsplash.flatMap({ URL(string: $0.imageURL) }) { return .remote(url) }
        return .none
    }

    private var titleFont: Font { cover.resolvedTitleFont.font(size: size * 0.144) }
    private func amountFont(size: CGFloat) -> Font { cover.resolvedAmountFont.font(size: size) }
    private var clampedProgress: CGFloat { min(1, max(0, CGFloat(progress))) }

    private func coverImage(_ image: UIImage) -> some View {
        Image(uiImage: image).resizable().scaledToFill().frame(width: size, height: size).clipped()
    }

    /// Nothing chosen at all — no photo, no gradient, no colour.
    private var isBlank: Bool {
        imageSource == .none && cover.backgroundID == nil && (cover.backgroundColor ?? "").isEmpty
    }

    /// The cover's picture, before the colour reveal. A photo, a gradient, or a
    /// neutral surface when the cover is still blank.
    @ViewBuilder private var picture: some View {
        if let image {
            coverImage(image)
        } else if isBlank {
            Rectangle().fill(Color(uiColor: .secondarySystemGroupedBackground))
        } else {
            FIPlanCoverBackground(cover: cover)
        }
    }

    static func fill(_ id: String) -> Color {
        switch id {
        case "red": Color(red: 1, green: 0.36, blue: 0.29)
        case "pink": Color(red: 1, green: 0.55, blue: 0.68)
        case "orange": Color(red: 1, green: 0.65, blue: 0.35)
        case "mint": Color(red: 0.42, green: 0.83, blue: 0.67)
        case "purple": Color(red: 0.7, green: 0.6, blue: 0.95)
        case "yellow": Color(red: 1, green: 0.83, blue: 0.4)
        default: Color(red: 0.25, green: 0.73, blue: 1)
        }
    }

    private var lightTitle: Bool {
        if image != nil || cover.unsplash != nil { return true }
        if progress > 0.85 {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard UIColor(Self.fill(cover.color)).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
            return red * 0.2126 + green * 0.7152 + blue * 0.0722 < 0.48
        }
        return FIPlanBackgroundCatalog.isDark(cover)
    }

    private var ink: Color { lightTitle ? .white : .primary }
    private var textShadow: Color { image == nil ? .clear : .black.opacity(0.6) }

    private var titleText: some View {
        Text(title).font(titleFont).multilineTextAlignment(.leading)
            .lineLimit(2).minimumScaleFactor(0.65)
            .foregroundStyle(ink)
            .shadow(color: textShadow, radius: 3, y: 1)
    }

    /// The fill line on the card.
    private var progressBar: some View {
        let height = max(4, size * 0.028)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(lightTitle ? Color.white.opacity(0.3) : Color.black.opacity(0.12))
                Capsule().fill(FITheme.Palette.accent)
                    .frame(width: max(0, geo.size.width * clampedProgress))
            }
        }
        .frame(height: height)
        .padding(.vertical, 2)
    }

    private func creditBadge(_ credit: FinancePlanCover.UnsplashCredit) -> some View {
        HStack(spacing: 3) {
            Text("cover.credit.by")
            creditLink(credit.photographerName, credit.photographerLink)
            Text("cover.credit.on")
            creditLink("Unsplash", credit.unsplashLink)
        }
        .font(.system(size: max(9, size * 0.03)))
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.black.opacity(0.35), in: Capsule())
    }

    @ViewBuilder
    private func creditLink(_ text: String, _ url: URL?) -> some View {
        if let url { Link(text, destination: url).underline() }
        else { Text(verbatim: text) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            picture
            VStack(alignment: .leading, spacing: 4) {
                if showsTitle, !titleAtBottom { titleText }
                if shared { Image(systemName: "person.2.fill").foregroundStyle(ink).accessibilityLabel(Text("plan.shared")) }
                Spacer(minLength: 0)
                if isBlank, let placeholderSymbol {
                    Image(systemName: placeholderSymbol).font(.system(size: size * 0.2))
                        .foregroundStyle(Color.secondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                if showsProgress {
                    progressBar
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if showsAmount {
                            Text(amount).lineLimit(1).minimumScaleFactor(0.6)
                        }
                        Spacer(minLength: 0)
                        Text(verbatim: "\(Int((clampedProgress * 100).rounded()))%")
                    }
                    .font(amountFont(size: max(12, size * 0.072)))
                    .monospacedDigit()
                    .foregroundStyle(ink)
                    .shadow(color: textShadow, radius: 3, y: 1)
                }
                if showsTitle, titleAtBottom {
                    titleText.padding(.bottom, showsCredit && cover.unsplash != nil ? size * 0.055 : 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(max(12, size * 0.06))
            .padding(.top, min(size, max(0, contentTopInset)))

            if showsCredit, let credit = cover.unsplash {
                creditBadge(credit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: titleAtBottom ? .bottomLeading : .bottomTrailing)
                    .padding(max(8, size * 0.03))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: imageSource) {
            switch imageSource {
            case .none:
                image = nil
            case .data(let data):
                let decoded = await Task.detached { UIImage(data: data) }.value
                guard !Task.isCancelled else { return }
                image = decoded
            case .remote(let url):
                let loaded = await UnsplashService.image(at: url)
                guard !Task.isCancelled else { return }
                image = loaded
            }
        }
    }
}

/// Draft-only editor. Cancel never changes the parent editor or stored record.
struct FinancePlanCoverEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: FinancePlanCover
    let title: String
    let amount: String
    let onSave: (FinancePlanCover) -> Void
    @State private var photoItem: PhotosPickerItem?
    @State private var loading = false
    @State private var imageError = false
    @State private var showCatalog = false
    @State private var showFontEditor = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        FIPlanCoverTile(title: title, amount: amount, progress: 0.5, cover: draft, size: 200, showsCredit: true)
                        Spacer()
                    }.listRowBackground(Color.clear)
                } footer: { Text("cover.preview.hint") }
                Section("cover.appearance") {
                    Button { showCatalog = true } label: {
                        HStack(spacing: 12) {
                            UnsplashMark().foregroundStyle(Color(.label)).frame(width: 20, height: 20)
                            Text("cover.backgrounds")
                            Spacer()
                            RoundedRectangle(cornerRadius: 6)
                                .fill(FIPlanBackgroundCatalog.item(draft.backgroundID).gradient)
                                .frame(width: 34, height: 22)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.1)))
                        }
                    }.tint(.primary)
                    Button { showFontEditor = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "textformat").frame(width: 18)
                            Text("cover.font")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }.tint(.primary)
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("cover.photo", systemImage: "photo")
                    }
                    if draft.photo != nil {
                        Button("cover.photo.remove", role: .destructive) { draft.photo = nil; photoItem = nil }
                    }
                    if loading { ProgressView() }
                }
            }
            .navigationTitle(Text("cover.title"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showCatalog) { FIPlanBackgroundPicker(cover: $draft) }
            .sheet(isPresented: $showFontEditor) {
                FIPlanFontEditor(draft: draft, title: title, amount: amount) { draft = $0 }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { onSave(draft); dismiss() }.disabled(loading)
                }
            }
            .alert("cover.photo.error", isPresented: $imageError) { Button("common.close", role: .cancel) {} }
            .task(id: photoItem) {
                guard let photoItem else { loading = false; return }
                loading = true
                defer { if self.photoItem == photoItem { loading = false } }
                do {
                    guard let data = try await photoItem.loadTransferable(type: Data.self) else { throw CoverImageFailure.invalid }
                    let compressed = await Task.detached { Self.thumbnail(data) }.value
                    guard !Task.isCancelled else { return }
                    guard let compressed else { throw CoverImageFailure.invalid }
                    draft.photo = compressed
                    draft.emoji = ""
                    draft.unsplash = nil
                } catch {
                    if !Task.isCancelled { imageError = true }
                }
            }
        }
    }

    private enum CoverImageFailure: Error { case invalid }

    // Bound payload size before putting an image into the synced cover JSON.
    nonisolated fileprivate static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 400
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 150_000 else { return nil }
        return output as Data
    }
}

/// Inline draft controls used by both plan creation sheets.
struct FIPlanCoverComposer: View {
    @Binding var cover: FinancePlanCover
    let title: String
    let amount: String
    @Binding var loading: Bool
    @State private var photoItem: PhotosPickerItem?
    @State private var imageError = false
    @State private var showCatalog = false
    @State private var showFontEditor = false

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { proxy in
                FIPlanCoverTile(title: title, amount: amount, progress: 0.5,
                                cover: cover, size: proxy.size.width, cornerRadius: 12, showsCredit: true)
            }.aspectRatio(1, contentMode: .fit)
            ViewThatFits(in: .horizontal) {
                HStack {
                    catalogButton
                    Spacer(minLength: 12)
                    toolGroup
                }
                VStack(alignment: .leading, spacing: 10) {
                    catalogButton
                    toolGroup
                }
            }
            if loading { ProgressView() }
            Text("cover.preview.hint").font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showCatalog) { FIPlanBackgroundPicker(cover: $cover) }
        .sheet(isPresented: $showFontEditor) {
            FIPlanFontEditor(draft: cover, title: title, amount: amount) { cover = $0 }
        }
        .alert("cover.photo.error", isPresented: $imageError) { Button("common.close", role: .cancel) {} }
        .task(id: photoItem) {
            guard let photoItem else { loading = false; return }
            loading = true
            defer { if self.photoItem == photoItem { loading = false } }
            do {
                guard let data = try await photoItem.loadTransferable(type: Data.self) else { imageError = true; return }
                let photo = await Task.detached { FinancePlanCoverEditor.thumbnail(data) }.value
                guard !Task.isCancelled else { return }
                guard let photo else { imageError = true; return }
                cover.photo = photo
                cover.emoji = ""
                cover.unsplash = nil
            } catch {
                if !Task.isCancelled { imageError = true }
            }
        }
    }

    /// Left: the background catalogue (Unsplash-style).
    private var catalogButton: some View {
        Button { showCatalog = true } label: {
            UnsplashMark().foregroundStyle(Color(.label))
                .frame(width: 26, height: 26).frame(width: 48, height: 48)
        }
        .padding(4).buttonStyle(.plain)
        .glassEffect(.regular, in: Capsule())
        .accessibilityLabel(Text("cover.backgrounds"))
    }

    /// Right: font editor and photo, grouped.
    private var toolGroup: some View {
        HStack(spacing: 0) {
            Button { showFontEditor = true } label: {
                Image(systemName: "textformat").frame(width: 44, height: 44)
            }.accessibilityLabel(Text("cover.font"))
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "photo").frame(width: 44, height: 44)
            }.accessibilityLabel(Text("cover.photo"))
            if cover.photo != nil {
                Button { photoItem = nil; cover.photo = nil } label: {
                    Image(systemName: "trash").frame(width: 44, height: 44)
                }.accessibilityLabel(Text("cover.photo.remove"))
            }
        }
        .padding(4).buttonStyle(.plain).tint(.primary)
        .glassEffect(.regular, in: Capsule())
    }
}

/// The Unsplash wordmark glyph, traced from the brand SVG (24×24 viewBox).
struct UnsplashMark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let ox = rect.midX - 12 * s, oy = rect.midY - 12 * s
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        var path = Path()
        path.addRect(CGRect(x: ox + 9 * s, y: oy + 4.5 * s, width: 6 * s, height: 4 * s))
        path.move(to: p(4, 10.5))
        path.addLine(to: p(9, 10.5)); path.addLine(to: p(9, 14.5))
        path.addLine(to: p(15, 14.5)); path.addLine(to: p(15, 10.5))
        path.addLine(to: p(20, 10.5)); path.addLine(to: p(20, 19.5))
        path.addLine(to: p(4, 19.5)); path.closeSubpath()
        return path
    }
}

/// A catalogue of ready-made gradient backgrounds. Stands in until the Unsplash
/// API key is wired up; the picker UI is already the shape a photo search wants.
enum FIPlanBackgroundCatalog {
    struct Item: Identifiable, Hashable {
        let id: String
        let stops: [String]
        var gradient: LinearGradient {
            LinearGradient(colors: stops.map { Color(hex: $0) ?? .gray },
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    static let items: [Item] = [
        Item(id: "sunset", stops: ["FF5C4A", "FF8CAD"]),
        Item(id: "peach", stops: ["FFA659", "FFD466"]),
        Item(id: "lagoon", stops: ["40BAFF", "6BD4AB"]),
        Item(id: "grape", stops: ["B399F2", "6E5BD6"]),
        Item(id: "forest", stops: ["2E7D5B", "6BD4AB"]),
        Item(id: "berry", stops: ["FF5C4A", "8E2DE2"]),
        Item(id: "sky", stops: ["5AC8FA", "007AFF"]),
        Item(id: "rose", stops: ["FF8CAD", "FF5C7C"]),
        Item(id: "gold", stops: ["FFD466", "FF9F45"]),
        Item(id: "ocean", stops: ["1FA2FF", "12D8FA", "A6FFCB"]),
        Item(id: "dusk", stops: ["355C7D", "6C5B7B", "C06C84"]),
        Item(id: "aurora", stops: ["43C6AC", "191654"]),
        Item(id: "ember", stops: ["F83600", "FE8C00"]),
        Item(id: "iris", stops: ["A18CD1", "FBC2EB"]),
        Item(id: "graphite", stops: ["3A3A3C", "1C1C1E"]),
        Item(id: "paper", stops: ["F5F7FA", "E4E7EB"]),
    ]

    static func item(_ id: String?) -> Item {
        items.first { $0.id == id } ?? items[0]
    }

    static var randomID: String { items.randomElement()?.id ?? items[0].id }

    /// Whether a cover's resolved background is dark enough for white text.
    static func isDark(_ cover: FinancePlanCover) -> Bool {
        if cover.unsplash != nil { return true }
        let hex: String
        if let id = cover.backgroundID {
            hex = item(id).stops.first ?? "FFFFFF"
        } else if let legacy = cover.backgroundColor {
            hex = legacy
        } else {
            hex = items[0].stops.first ?? "FFFFFF"
        }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(Color(hex: hex) ?? .white).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        return red * 0.2126 + green * 0.7152 + blue * 0.0722 < 0.5
    }
}

extension FinancePlanCover {
    /// A fresh cover for a new plan — a random gradient so the sheet is never
    /// blank.
    static func newPlan() -> Self {
        var cover = Self()
        cover.backgroundID = FIPlanBackgroundCatalog.randomID
        return cover
    }
}

extension FinancePlanCover.FontSpec {
    var swiftWeight: Font.Weight {
        switch weight {
        case "light": .light
        case "regular": .regular
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        case "black": .black
        default: .heavy
        }
    }
    var swiftDesign: Font.Design {
        switch design {
        case "serif": .serif
        case "mono": .monospaced
        case "default": .default
        default: .rounded
        }
    }
    func font(size: CGFloat) -> Font {
        let base = Font.system(size: size, weight: swiftWeight, design: swiftDesign)
        return italic ? base.italic() : base
    }
}

/// Native sheet Unsplash browser: a search field, a row of category chips, and
/// an edge-to-edge two-column grid. The ready-made gradients sit under the first
/// chip. Follows the system theme like any other sheet.
///
/// Picking a photo clears any chosen gradient or personal photo, records the
/// attribution, and pings Unsplash's download endpoint as their terms require.
struct FIPlanBackgroundPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var cover: FinancePlanCover

    @State private var query = ""
    @State private var tab = 0            // 0 = gradients, else UnsplashService.categories[tab - 1]
    @State private var photos: [UnsplashPhoto] = []
    @State private var phase: Phase = .loading
    private enum Phase: Equatable { case loading, loaded, failed }

    private let grid = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    private var chips: [(id: Int, key: String)] {
        [(0, "cover.backgrounds.gradients")] +
        UnsplashService.categories.enumerated().map { ($0.offset + 1, $0.element.key) }
    }
    private var showingGradients: Bool { tab == 0 && query.isEmpty }
    private var activeTerm: String {
        if !query.isEmpty { return query }
        guard tab > 0 else { return "" }
        return UnsplashService.categories[tab - 1].term ?? ""
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text(verbatim: "Unsplash"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }.tint(.primary)
                    }
                }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: Text("cover.unsplash.search"))
                .safeAreaInset(edge: .top, spacing: 0) { chipRow }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task(id: activeTerm) { await load() }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.id) { chip in
                    let selected = query.isEmpty && tab == chip.id
                    Button {
                        query = ""
                        tab = chip.id
                    } label: {
                        Text(LocalizedStringKey(chip.key))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(selected ? Color.accentColor : Color.secondary)
                    .background(selected ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            if showingGradients {
                LazyVGrid(columns: grid, spacing: 2) {
                    ForEach(FIPlanBackgroundCatalog.items) { item in
                        Button {
                            cover.backgroundID = item.id
                            cover.photo = nil
                            cover.unsplash = nil
                            dismiss()
                        } label: {
                            item.gradient
                                .frame(height: 150)
                                .overlay {
                                    if cover.photo == nil, cover.unsplash == nil, cover.backgroundID == item.id {
                                        Image(systemName: "checkmark.circle.fill").font(.title3)
                                            .foregroundStyle(.white).shadow(radius: 3)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                switch phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                case .failed:
                    ContentUnavailableView("cover.unsplash.failed", systemImage: "wifi.slash")
                        .padding(.top, 40)
                case .loaded:
                    LazyVGrid(columns: grid, spacing: 2) {
                        ForEach(photos) { photo in photoCell(photo) }
                    }
                }
            }
        }
    }

    private func photoCell(_ photo: UnsplashPhoto) -> some View {
        Button {
            cover.unsplash = .init(photo)
            cover.photo = nil
            cover.backgroundID = nil
            UnsplashService.trackUsage(photo)
            dismiss()
        } label: {
            (Color(hex: photo.accentHex ?? "") ?? Color(.tertiarySystemFill))
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .overlay {
                    AsyncImage(url: photo.thumbURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ProgressView()
                    }
                }
                .clipped()
                .contentShape(Rectangle())
                .overlay(alignment: .bottomLeading) {
                    // Attribution required wherever an Unsplash photo is shown.
                    Text(photo.photographerName)
                        .font(.caption2).foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                        )
                }
                .overlay(alignment: .topTrailing) {
                    if cover.unsplash?.photoID == photo.id {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white).shadow(radius: 2).padding(6)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        guard !showingGradients else { return }
        // Debounce: .task(id:) cancels the in-flight call on the next keystroke.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        phase = photos.isEmpty ? .loading : phase
        do {
            let result = try await UnsplashService.search(activeTerm)
            guard !Task.isCancelled else { return }
            photos = result
            phase = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            if photos.isEmpty { phase = .failed }
        }
    }
}

/// A small sheet for the two independent text slots on a cover.
struct FIPlanFontEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: FinancePlanCover
    let title: String
    let amount: String
    let onSave: (FinancePlanCover) -> Void

    private let weights = ["light", "regular", "medium", "semibold", "bold", "heavy", "black"]
    private let designs = ["default", "rounded", "serif", "mono"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        FIPlanCoverTile(title: title, amount: amount, progress: 0.5, cover: draft, size: 170)
                        Spacer()
                    }.listRowBackground(Color.clear)
                }
                Section("cover.font.section.title") {
                    slotRows(Binding(get: { draft.resolvedTitleFont }, set: { draft.titleFont = $0 }))
                }
                Section("cover.font.section.amount") {
                    slotRows(Binding(get: { draft.resolvedAmountFont }, set: { draft.amountFont = $0 }))
                }
            }
            .navigationTitle(Text("cover.font"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { onSave(draft); dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func slotRows(_ spec: Binding<FinancePlanCover.FontSpec>) -> some View {
        Picker("cover.font.weight", selection: spec.weight) {
            ForEach(weights, id: \.self) { Text(LocalizedStringKey("cover.weight." + $0)).tag($0) }
        }
        Picker("cover.font.style", selection: spec.design) {
            ForEach(designs, id: \.self) { Text(LocalizedStringKey("cover.design." + $0)).tag($0) }
        }
        Toggle("cover.font.italic", isOn: spec.italic)
    }
}

private struct FIPlanCoverBackground: View {
    let cover: FinancePlanCover

    var body: some View {
        if let id = cover.backgroundID {
            FIPlanBackgroundCatalog.item(id).gradient
        } else if let hex = cover.backgroundColor, let color = Color(hex: hex) {
            // A cover saved before the catalogue: keep its solid/gradient look.
            if cover.gradientEnabled == true {
                LinearGradient(colors: [color, color.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                color
            }
        } else {
            FIPlanBackgroundCatalog.item(nil).gradient
        }
    }
}
