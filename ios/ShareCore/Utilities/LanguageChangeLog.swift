//
//  LanguageChangeLog.swift
//  ShareCore
//

enum LanguageChangeLog {
    static func message(
        scope: String,
        field: String,
        from: String?,
        to: String?,
        reason: String
    ) -> String {
        "languageChange scope=\(scope) field=\(field) from=\(from ?? "nil") to=\(to ?? "nil") reason=\(reason)"
    }
}
