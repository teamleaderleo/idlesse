import Foundation

package enum IdlesseScalingMode: String, CaseIterable, Codable {
    case fit
    case fill
    case actual

    package var title: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .actual: return "Actual Size"
        }
    }
}
