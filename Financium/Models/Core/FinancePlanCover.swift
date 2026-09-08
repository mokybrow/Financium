import Foundation

/// Version-one cover payload shared by local JSON and CloudKit records.
nonisolated struct FinancePlanCover: Codable, Equatable, Sendable {
    var font = "rounded"
    var emoji = ""
    var color = "blue"
    var photo: Data?
    // Optional additions keep previously saved covers decodable.
    var backgroundColor: String?
    var gradientColor: String?
    var gradientEnabled: Bool?
    /// Id of a gradient from the background catalogue. When set, and no photo is
    /// chosen, it is the cover background.
    var backgroundID: String?
    /// Per-slot type: the title and the amount are styled independently. Nil
    /// falls back to `font`, so covers saved before this stays unchanged.
    var titleFont: FontSpec?
    var amountFont: FontSpec?
    /// A photo chosen from Unsplash: rendered from `imageURL`, with the
    /// attribution Unsplash's API terms require. Cleared when the user picks
    /// their own photo or a gradient.
    var unsplash: UnsplashCredit?

    struct UnsplashCredit: Codable, Equatable, Sendable {
        var photoID = ""
        var imageURL = ""
        var thumbURL = ""
        var photographerName = ""
        var photographerURL = ""
        var photoURL = ""
    }

    /// One text slot's styling. Plain data — the SwiftUI `Font` is built in the
    /// view layer.
    struct FontSpec: Codable, Equatable, Sendable {
        var weight = "heavy"
        var design = "rounded"
        var italic = false
    }

    var resolvedTitleFont: FontSpec { titleFont ?? Self.legacyFont(font) }
    var resolvedAmountFont: FontSpec { amountFont ?? Self.legacyFont(font) }

    /// The single `font` name mapped onto the new two-axis model.
    static func legacyFont(_ id: String) -> FontSpec {
        switch id {
        case "heavy": FontSpec(weight: "black", design: "default")
        case "serif": FontSpec(weight: "bold", design: "serif")
        case "mono": FontSpec(weight: "bold", design: "mono")
        default: FontSpec(weight: "heavy", design: "rounded")
        }
    }

    static func decode(_ json: String) -> Self {
        guard let data = json.data(using: .utf8), let cover = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return cover
    }

    func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}

