import Foundation

struct ImportedResultFont: Identifiable, Equatable {
    let postScriptName: String
    let displayName: String
    let fileURL: URL

    var id: String {
        postScriptName
    }
}
