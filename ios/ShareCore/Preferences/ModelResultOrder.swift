import Foundation

public enum ModelResultOrder: String, CaseIterable, Sendable {
    case firstCompletedFirst
    case modelList

    public var title: String {
        switch self {
        case .firstCompletedFirst:
            String(localized: "First Completed First")
        case .modelList:
            String(localized: "Model List Order")
        }
    }
}
