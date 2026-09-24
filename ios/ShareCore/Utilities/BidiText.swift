//
//  BidiText.swift
//  ShareCore
//
//  Utilities for right-to-left (RTL) text handling. Translation results
//  must be rendered according to the *content* language, not the host UI
//  language — otherwise Arabic/Hebrew/Persian/Urdu output mis-aligns,
//  punctuation flips, and embedded LTR runs (numbers, code, URLs) jitter.
//

import Foundation
import SwiftUI

public enum BidiText {
    /// BCP-47 / ISO-639 codes whose primary script is right-to-left.
    /// Kept as a static set so detection is O(1) and free of `Locale`
    /// allocation on the hot path (streamed token rendering).
    private static let rtlLanguageCodes: Set<String> = [
        "ar", // Arabic
        "he", // Hebrew
        "iw", // Hebrew (legacy)
        "fa", // Persian / Farsi
        "ur", // Urdu
        "ps", // Pashto
        "ckb", // Central Kurdish (Sorani)
        "ku", // Kurdish (treat as RTL — Sorani dominant in app contexts)
        "sd", // Sindhi
        "ug", // Uyghur
        "yi", // Yiddish
        "dv", // Divehi / Maldivian
    ]

    // Unicode bidi isolate controls — wrap mixed-direction segments so
    // numbers / Latin tokens embedded in RTL text don't reorder neighbours.
    public static let firstStrongIsolate: Character = "\u{2068}" // FSI
    public static let popDirectionalIsolate: Character = "\u{2069}" // PDI
    public static let leftToRightIsolate: Character = "\u{2066}" // LRI
    public static let rightToLeftIsolate: Character = "\u{2067}" // RLI

    /// Returns `true` when the given language code denotes an RTL script.
    /// Accepts full BCP-47 tags (`ar-EG`, `fa_IR`); only the primary
    /// subtag is consulted.
    public static func isRTLLanguage(_ code: String?) -> Bool {
        guard let code, !code.isEmpty else { return false }
        let primary = code
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map { String($0).lowercased() } ?? ""
        return rtlLanguageCodes.contains(primary)
    }

    /// SwiftUI layout direction matching the content language.
    public static func layoutDirection(forLanguageCode code: String?) -> LayoutDirection {
        isRTLLanguage(code) ? .rightToLeft : .leftToRight
    }

    /// SwiftUI text alignment matching the content language.
    public static func textAlignment(forLanguageCode code: String?) -> TextAlignment {
        isRTLLanguage(code) ? .trailing : .leading
    }

    /// Heuristically decides whether a piece of text should render RTL by
    /// scanning Unicode scalars for the first *strong* directional character.
    /// Matches the Unicode Bidi Algorithm's "first-strong" rule (UAX #9 P2/P3),
    /// which is what `Text` would do anyway — we use it to drive container
    /// alignment so multi-line wrapping anchors to the correct edge.
    ///
    /// `scanLimit` bounds the scan for streaming hot paths.
    public static func isRTLText(_ text: String, scanLimit: Int = 256) -> Bool {
        var scanned = 0
        for scalar in text.unicodeScalars {
            scanned += 1
            if scanned > scanLimit { break }
            switch Int(scalar.value) {
            // Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic
            case 0x0590 ... 0x05FF,
                 0x0600 ... 0x06FF,
                 0x0700 ... 0x074F,
                 0x0750 ... 0x077F,
                 0x0780 ... 0x07BF,
                 0x07C0 ... 0x07FF,
                 0x0800 ... 0x083F,
                 0x0840 ... 0x085F,
                 0x08A0 ... 0x08FF,
                 // Arabic Presentation Forms-A / -B
                 0xFB1D ... 0xFDFF,
                 0xFE70 ... 0xFEFF:
                return true
            // Latin / Greek / Cyrillic / Armenian / Coptic — strong LTR.
            // Per UAX #9 P2 "first-strong", an LTR strong character before
            // any RTL scalar means the paragraph direction is LTR.
            case 0x0041 ... 0x005A, // A–Z
                 0x0061 ... 0x007A, // a–z
                 0x00C0 ... 0x00FF, // Latin-1 Supplement letters (À–ÿ)
                 0x0100 ... 0x024F, // Latin Extended-A / -B
                 0x0370 ... 0x03FF, // Greek
                 0x0400 ... 0x04FF, // Cyrillic
                 0x0500 ... 0x052F, // Cyrillic Supplement
                 0x0530 ... 0x058F, // Armenian
                 0x2C80 ... 0x2CFF, // Coptic
                 0x1E00 ... 0x1EFF: // Latin Extended Additional
                return false
            default:
                continue
            }
        }
        return false
    }

    /// Wraps a string in a First-Strong Isolate / PDI pair so it renders
    /// as a single bidirectional unit. Safe to call on already-wrapped or
    /// empty strings — returns the input unchanged in those cases.
    public static func wrapBidiIsolated(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        if text.first == firstStrongIsolate
            || text.first == leftToRightIsolate
            || text.first == rightToLeftIsolate
        {
            return text
        }
        return "\(firstStrongIsolate)\(text)\(popDirectionalIsolate)"
    }
}

extension View {
    /// Aligns a text node to the *content* language direction instead of the host
    /// UI direction. Without this, Arabic / Hebrew / Persian / Urdu translation
    /// output rendered inside an English UI hangs off the left edge and flips
    /// punctuation. Applied at the leaf so the surrounding layout (which
    /// intentionally tracks the UI language) is unaffected.
    @ViewBuilder
    func contentDirectionAware(_ text: String) -> some View {
        let isRTL = BidiText.isRTLText(text)
        environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
            .multilineTextAlignment(isRTL ? .trailing : .leading)
    }
}
