import Foundation
import ShareCore
import SwiftUI
import Testing

#if os(macOS)
    import AppKit
#endif

struct ModelTagTests {
    private let payload = ##"""
    {"id":"gemini-3.8-flash","displayName":"Gemini 3.8 Flash","isDefault":false,"isPremium":true,
    "tags":["Latest - Sep 2","Recommended"],
    "tagStyles":{"Recommended":{"textColor":"#166534","backgroundColor":"#DCFCE7"}}}
    """##

    @Test func decodesStylesAndPreservesTagOrder() throws {
        let model = try JSONDecoder().decode(ModelConfig.self, from: Data(payload.utf8))
        #expect(model.tags == ["Latest - Sep 2", "Recommended"])
        #expect(model.tagStyles["Recommended"]?.textColor == "#166534")
        #expect(model.tagStyles["Recommended"]?.backgroundColor == "#DCFCE7")
        let restored = try JSONDecoder().decode(ModelConfig.self, from: JSONEncoder().encode(model))
        #expect(restored == model)
    }

    @Test func legacyDecoderIgnoresStyles() throws {
        struct LegacyModel: Decodable {
            let id: String
            let displayName: String
            let isDefault: Bool
            let isPremium: Bool
            let tags: [String]
        }
        let old = try JSONDecoder().decode(LegacyModel.self, from: Data(payload.utf8))
        #expect(old.tags == ["Latest - Sep 2", "Recommended"])
    }

    @Test func missingOrMalformedStylesDoNotBreakDecoding() throws {
        for extra in [
            "",
            #", "tagStyles":null"#,
            #", "tagStyles":[]"#,
            #", "tagStyles":{"Recommended":{"textColor":123}}"#,
        ] {
            let json = #"{"id":"test","displayName":"Test","isDefault":false,"isPremium":false,"tags":["Recommended"]"# + extra +
                "}"
            let model = try JSONDecoder().decode(ModelConfig.self, from: Data(json.utf8))
            #expect(model.tagStyles.isEmpty)
            #expect(model.tags == ["Recommended"])
        }
    }

    #if os(macOS)
        @Test @MainActor func rendersNarrowTags() throws {
            let model = ModelConfig(
                id: "test", displayName: "Gemini 3.8 Flash", isPremium: true,
                tags: [
                    "Latest - Sep 2",
                    "Recommended",
                    "Experimental",
                    "Unstable",
                    "A much longer tag that wraps within the available width",
                ],
                tagStyles: [
                    "Recommended": ModelTagStyle(textColor: "#166534", backgroundColor: "#DCFCE7"),
                    "Experimental": ModelTagStyle(textColor: "#92400E", backgroundColor: "#FEF3C7"),
                    "Unstable": ModelTagStyle(textColor: "#991B1B", backgroundColor: "#FEE2E2"),
                ]
            )
            for scheme in [ColorScheme.light, .dark] {
                let view = SelectableModelRow(model: model, isSelected: true) {}
                    .frame(width: 280)
                    .padding(.vertical, 12)
                    .background(scheme == .dark ? Color.black : Color.white)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                #expect(image.width == 560)
                #expect(image.height > 140)
                let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("model-tags-\(scheme).png")
                try data.write(to: url)
                print("Model tag snapshot: \(url.path)")
            }
        }
    #endif
}
