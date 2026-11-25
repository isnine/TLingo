#if os(iOS)
    import ShareCore
    import SwiftUI
    import TipKit

    /// Suggests the on-device English model when realtime captions English with another model.
    struct ParakeetUnifiedTip: Tip {
        @Parameter static var isEligible: Bool = false

        static let chooseModelActionID = "chooseModel"

        var title: Text {
            Text("Try \(RecognitionModelDescriptor.parakeetUnified.title)")
        }

        var message: Text? {
            Text("More accurate English captions with punctuation, recognized on this device.")
        }

        var image: Image? {
            Image(systemName: "waveform")
        }

        var rules: [Rule] {
            #Rule(Self.$isEligible) { $0 == true }
        }

        var actions: [Action] {
            Action(id: Self.chooseModelActionID, title: String(localized: "Choose Model"))
        }

        static func updateEligibility(source: SourceLanguageOption, modelID: String) {
            let model = RecognitionModelDescriptor.parakeetUnified
            isEligible = source != .auto
                && model.supports(sourceLanguage: source)
                && modelID != model.id
                && RecognitionModelStore.isSelectable(model)
        }
    }
#endif
