import Foundation

public enum ModelResultOrder: String, CaseIterable, Sendable {
    case firstCompletedFirst
    case lastCompletedFirst
    case modelList

    public var title: String {
        switch self {
        case .firstCompletedFirst:
            String(localized: "First Completed First")
        case .lastCompletedFirst:
            String(localized: "Last Completed First")
        case .modelList:
            String(localized: "Model List Order")
        }
    }
}
