import SwiftUI

/// The colour a ring or bar takes at a given level of use.
///
/// The thresholds come from the Codenotch design frame, which shows 21% green,
/// 52% yellow and 73% orange.
enum UsageBand: Equatable {
    case ample       // under half
    case watch       // getting close
    case critical    // nearly out
    case exhausted   // limit hit, waiting for the reset

    static func band(for usedFraction: Double) -> UsageBand {
        switch usedFraction {
        case ..<0.50: return .ample
        case ..<0.70: return .watch
        case ..<1.00: return .critical
        default:      return .exhausted
        }
    }

    /// The notch's colours: neon on pure black, sampled from the design frame.
    var color: Color {
        switch self {
        case .ample:                return NotchPalette.ample
        case .watch:                return NotchPalette.watch
        case .critical, .exhausted: return NotchPalette.critical
        }
    }

    /// The same meaning on Portly's own light or dark surfaces, where the
    /// notch's neon would glare: the system colours the rest of the app uses.
    var tint: Color {
        switch self {
        case .ample:     return .green
        case .watch:     return .yellow
        case .critical:  return .orange
        case .exhausted: return .red
        }
    }
}
