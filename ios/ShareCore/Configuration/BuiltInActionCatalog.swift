//
//  BuiltInActionCatalog.swift
//  ShareCore
//
//  Created by Codex on 2026/05/31.
//

import Foundation

enum BuiltInActionCatalog {
    private static let sentenceAnalysisPrompt = [
        "You are an expert linguist and language tutor. Analyze the text below and produce a study-oriented breakdown.",
        "",
        "Text:",
        "{{text}}",
        "",
        "Output language: {{appLanguage}}",
        "",
        "Rules:",
        "- Write ALL explanations, definitions, labels, and commentary in {{appLanguage}}.",
        "- Keep the original words, phrases, and example sentences in their source language. " +
            "Do NOT translate the source text itself or the example sentences' source-language part.",
        "- Be precise and pedagogical, not verbose.",
        "- Do not add any preface, summary, or closing remarks outside the two sections.",
        "- Do not invent content not grounded in the input.",
        "",
        "Output format:",
        "Use compact Markdown that renders well in a chat/result cell.",
        "- Use only headings, bullet lists, block quotes, bold labels, and inline code.",
        "- Do NOT use code fences, HTML, tables, images, or remote media.",
        "- Wrap source-language words, phrases, and expressions in inline code.",
        "- Translate section heading text and labels into {{appLanguage}}.",
        "",
        "## <Grammar Analysis — translated to {{appLanguage}}>",
        "",
        "For EACH sentence in the input, on its own block:",
        "1. First line: a block quote containing the original sentence, verbatim.",
        "2. Then, one bullet per meaningful chunk (word, phrase, or clause) in the order it appears, formatted as:",
        "   - `<chunk>`: <its grammatical role and function, explained in {{appLanguage}}>",
        "   - Cover subjects, verbs/tenses, objects, complements, modifiers, conjunctions, fillers, clauses " +
            "(and their type), ellipsis, and any noteworthy structure.",
        "   - If something is omitted or implied, reconstruct the full form in parentheses and explain it.",
        "3. Separate sentence blocks with one blank line.",
        "",
        "## <Collocations & Useful Expressions — translated to {{appLanguage}}>",
        "",
        "Pick 2–4 high-value collocations, phrasal verbs, or idiomatic expressions actually used in the input. " +
            "For each, output this Markdown block (labels translated to {{appLanguage}}, source-language content kept " +
            "in its original language and wrapped in inline code):",
        "",
        "### `<expression>`",
        #"- **<meaning label>:** <concise definition in {{appLanguage}}>"#,
        #"- **<example label>:** <natural source-language example using the expression>"#,
        #"- **<example note label>:** <explanation in {{appLanguage}}>"#,
        #"- **<synonyms label>:** <synonym> (<gloss>); <synonym> (<gloss>)"#,
        #"- **<antonyms label>:** <antonym> (<gloss>); <antonym> (<gloss>)"#,
        "",
        "Separate expression blocks with one blank line.",
    ].joined(separator: "\n")

    static let translateActionID = UUID(uuidString: "A17A0000-0000-4000-8000-000000000001")!
    static let sentenceTranslateActionID = UUID(uuidString: "A17A0000-0000-4000-8000-000000000002")!

    static let wordLookupPrompt = [
        "Look up the {{sourceLanguage}} word or phrase below like a bilingual dictionary for a {{targetLanguage}} reader.",
        "",
        "Text:",
        "{{text}}",
        "",
        "Rules:",
        "- Write all explanations in {{targetLanguage}}; keep the headword and example sentences in the source language.",
        "- Use compact Markdown: headings, bullet lists, bold labels, and inline code only. No code fences, HTML, or tables.",
        "- Do not add any preface or closing remarks.",
        "",
        "Output format:",
        "**<headword>** <pronunciation (IPA, pinyin, or kana) when applicable>",
        "- One bullet per part of speech: *<part of speech>* <concise {{targetLanguage}} meanings>",
        "- 2–3 natural example sentences, each followed by its {{targetLanguage}} translation",
        "- Common collocations or related forms, only if useful",
    ].joined(separator: "\n")

    static let actions: [ActionConfig] = [
        ActionConfig(
            id: translateActionID,
            name: "Translate",
            prompt: [
                "Translate the text below from {{sourceLanguage}} to {{targetLanguage}}.",
                "",
                "Text:",
                "{{text}}",
                "",
                "Rules:",
                "- Preserve the original meaning, tone, and formatting.",
                "- If the input contains Markdown structure, preserve headings, lists, block quotes, links, and inline code; " +
                    "translate only the human-readable text.",
                "- Do NOT add Markdown structure that was not present in the input.",
                "- Use natural, fluent {{targetLanguage}}.",
                "- Do NOT add explanations or alternatives.",
                "- Return only the translated text.",
            ].joined(separator: "\n"),
            outputType: .translate,
            category: .translation
        ),
        ActionConfig(
            id: sentenceTranslateActionID,
            name: "Sentence Translate",
            prompt: [
                "Translate the text below sentence by sentence from {{sourceLanguage}} to {{targetLanguage}}.",
                "",
                "Text:",
                "{{text}}",
                "",
                "Rules:",
                "- Split the input into sentences while keeping punctuation with each sentence.",
                "- Preserve the original meaning, tone, and style.",
                "- Use natural, fluent {{targetLanguage}} for each translation.",
                "- Return original-translation pairs only.",
            ].joined(separator: "\n"),
            outputType: .sentencePairs,
            category: .translation
        ),
        ActionConfig(
            id: UUID(uuidString: "A17A0000-0000-4000-8000-000000000005")!,
            name: "Simplify",
            prompt: [
                "Rewrite the text below to be simpler and more concise.",
                "",
                "Text:",
                "{{text}}",
                "",
                "Rules:",
                "- Preserve the input language exactly.",
                "- Do NOT translate the text into another language.",
                "- Preserve the original meaning.",
                "- If the input contains Markdown structure, preserve headings, lists, block quotes, links, and inline code; " +
                    "rewrite only the human-readable text.",
                "- Do NOT add Markdown structure that was not present in the input.",
                "- Make the rewritten text natural, coherent, and grammatically correct.",
                "- Do NOT add new information.",
                "- Return only the rewritten text.",
            ].joined(separator: "\n")
        ),
        ActionConfig(
            id: UUID(uuidString: "A17A0000-0000-4000-8000-000000000003")!,
            name: "Grammar Check",
            prompt: [
                "Check the grammar of the text below.",
                "",
                "Text:",
                "{{text}}",
                "",
                "Rules:",
                "- Put the corrected version in revised_text.",
                "- Preserve the input language in revised_text.",
                "- Format additional_text as compact Markdown in {appLanguage}.",
                "- In additional_text, use '## Issues' and '## Meaning' headings translated into {appLanguage}.",
                "- Under Issues, use bullets. Prefix severe issues with ❌ and minor issues with ⚠️.",
                "- Wrap source and corrected fragments in inline code.",
                "- Under Meaning, translate the corrected text into {appLanguage} and include that translation as a block quote.",
                "- Do NOT use code fences, HTML, tables, images, or remote media in additional_text.",
                "- Do NOT add unrelated commentary.",
            ].joined(separator: "\n"),
            outputType: .grammarCheck
        ),
        ActionConfig(
            id: UUID(uuidString: "A17A0000-0000-4000-8000-000000000004")!,
            name: "Polish",
            prompt: [
                "Polish the text below to sound natural and fluent.",
                "",
                "Text:",
                "{{text}}",
                "",
                "Rules:",
                "- Preserve the input language exactly.",
                "- Preserve the original meaning, tone, and formatting.",
                "- If the input contains Markdown structure, preserve headings, lists, block quotes, links, and inline code; " +
                    "polish only the human-readable text.",
                "- Do NOT add Markdown structure that was not present in the input.",
                "- Do NOT add new information.",
                "- Return only the polished text.",
            ].joined(separator: "\n"),
            outputType: .diff
        ),
        ActionConfig(
            id: UUID(uuidString: "A17A0000-0000-4000-8000-000000000006")!,
            name: "Sentence Analysis",
            prompt: sentenceAnalysisPrompt
        ),
    ]

    private static let actionNames = Set(actions.map(\.name))
    private static let actionIDs = Set(actions.map(\.id))

    static func isBuiltInActionName(_ name: String) -> Bool {
        actionNames.contains(name)
    }

    static func prompt(named name: String) -> String? {
        actions.first { $0.name == name }?.prompt
    }

    static func isBuiltInAction(_ action: ActionConfig) -> Bool {
        actionIDs.contains(action.id)
    }

    static func displayName(for action: ActionConfig) -> String {
        guard isBuiltInAction(action) else { return action.name }
        return displayName(forActionName: action.name)
    }

    static func displayName(forActionName name: String) -> String {
        guard isBuiltInActionName(name) else { return name }
        return NSLocalizedString(name, comment: "Built-in action name")
    }

    static func customActions(from actions: [ActionConfig]) -> [ActionConfig] {
        actions.filter { !isBuiltInAction($0) }
    }

    static func customConfiguration(from config: AppConfiguration) -> (config: AppConfiguration, removedBuiltInActions: Bool) {
        let customEntries = config.actions.filter { !isPersistedBuiltInAction($0) }
        var filtered = config
        filtered.actions = customEntries
        return (filtered, customEntries.count != config.actions.count)
    }

    private static func isPersistedBuiltInAction(_ entry: AppConfiguration.ActionEntry) -> Bool {
        if let id = entry.id {
            return actionIDs.contains(id)
        }

        let candidate = entry.toActionConfig()
        return actions.contains { builtIn in
            candidate.name == builtIn.name &&
                candidate.prompt == builtIn.prompt &&
                candidate.outputType == builtIn.outputType &&
                candidate.category == builtIn.category
        }
    }
}
