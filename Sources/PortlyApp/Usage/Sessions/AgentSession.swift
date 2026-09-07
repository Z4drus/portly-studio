import SwiftUI

/// One agent session, whichever tool it belongs to: a display model rather
/// than a mirror of any one tool's file format.
struct AgentSession: Identifiable, Equatable {
    enum State: Equatable {
        case busy
        case waiting
        case idle
    }

    let id: String
    /// What to call it in the tooltip.
    let name: String
    /// The quieter second line — where it is running, or what it is doing.
    let detail: String
    let state: State
    /// Set while `waiting`: what it wants from you.
    let waitingFor: String?
    /// When it entered its current state.
    let since: Date
}

/// What the activity indicator shows: the state of every live session,
/// reduced to the one thing worth knowing at a glance.
struct ActivitySummary: Equatable {
    enum State: Equatable {
        case working
        case waiting
        case idle
    }

    let state: State
    let sessions: [AgentSession]

    /// Nil when nothing is running — the indicator disappears rather than
    /// sitting there saying nothing.
    init?(sessions: [AgentSession]) {
        guard !sessions.isEmpty else { return nil }
        self.sessions = sessions
        // Anything blocked on you outranks anything merely busy: it is the only
        // state where the notch is asking for something.
        if sessions.contains(where: { $0.state == .waiting }) {
            state = .waiting
        } else if sessions.contains(where: { $0.state == .busy }) {
            state = .working
        } else {
            state = .idle
        }
    }

    /// One short word, for the tooltip and the sidebar.
    var label: String {
        switch state {
        case .working: return "working"
        case .waiting: return "waiting"
        case .idle: return "idle"
        }
    }

    /// White for working, deliberately: the indicator sits inside a ring whose
    /// colour already means "how much of your limit is gone", and a neutral
    /// tone cannot be misread as part of that scale. Waiting gets amber
    /// because it is the one state that wants something from you.
    var color: Color {
        switch state {
        case .working: return NotchPalette.textPrimary
        case .waiting: return NotchPalette.watch
        case .idle: return NotchPalette.ringTrack
        }
    }

    var waitingSessions: [AgentSession] { sessions.filter { $0.state == .waiting } }
}
