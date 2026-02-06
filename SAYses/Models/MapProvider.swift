import Foundation

enum MapProvider: String, CaseIterable {
    case appleMaps
    case openStreetMap

    var displayName: String {
        switch self {
        case .appleMaps: return "Apple Maps"
        case .openStreetMap: return "OpenStreetMap"
        }
    }
}
