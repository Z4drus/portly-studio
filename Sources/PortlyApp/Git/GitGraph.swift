import Foundation

/// Lays recent commits out in lanes, the way Git graph tools draw history:
/// each commit sits in one lane, a line runs from it down to its parents,
/// branches that fork take a lane of their own and give it back when they
/// merge. Pure arithmetic over the commit list, so it can be checked.
enum GitGraph {
    /// One commit's place in the drawing.
    struct Row: Hashable {
        var commit: GitCommit
        /// The lane the commit's dot sits in.
        var lane: Int
        /// Colour index of that lane.
        var color: Int
        /// Lines from this row down to the next one: where each lane goes.
        var edges: [Edge]
        /// Lanes that run straight through this row without touching the
        /// commit: drawn behind the dot.
        var passingLanes: [Int]
    }

    struct Edge: Hashable {
        var fromLane: Int
        var toLane: Int
        var color: Int
    }

    struct Layout: Hashable {
        var rows: [Row]
        /// How many lanes the widest row needs.
        var laneCount: Int
    }

    /// `commits` must be in display order (newest first, parents after
    /// children as `git log --date-order` prints them).
    static func layout(_ commits: [GitCommit]) -> Layout {
        // Each lane expects a commit hash: the parent the line is heading for.
        var lanes: [String?] = []
        var laneColors: [Int] = []
        var nextColor = 0
        var rows: [Row] = []
        var widest = 0

        func allocateLane(expecting hash: String) -> Int {
            if let free = lanes.firstIndex(where: { $0 == nil }) {
                lanes[free] = hash
                laneColors[free] = nextColor
                nextColor += 1
                return free
            }
            lanes.append(hash)
            laneColors.append(nextColor)
            nextColor += 1
            return lanes.count - 1
        }

        for (index, commit) in commits.enumerated() {
            // The commit lands in the first lane waiting for it, else a new one.
            let lane: Int
            if let expected = lanes.firstIndex(where: { $0 == commit.hash }) {
                lane = expected
            } else {
                lane = allocateLane(expecting: commit.hash)
            }
            let color = laneColors[lane]
            // Every other lane waiting for this same commit converges here.
            for other in lanes.indices where other != lane && lanes[other] == commit.hash {
                lanes[other] = nil
            }
            let passing = lanes.indices.filter { $0 != lane && lanes[$0] != nil }

            // The first parent continues in this lane; the others fork out,
            // unless a lane is already heading for them.
            var edges: [Edge] = []
            // A passing lane that turns out to be heading for our first
            // parent bends into this lane instead of running on.
            var redirected: [Int: Int] = [:]
            if let first = commit.parents.first {
                if let existing = lanes.firstIndex(where: { $0 == first }) {
                    if existing < lane {
                        // Already awaited further left: this line bends into it.
                        lanes[lane] = nil
                        edges.append(Edge(fromLane: lane, toLane: existing, color: color))
                    } else {
                        // Pull the parent into this lane, the leftmost of the
                        // two, so the trunk never jumps sideways at a base.
                        lanes[existing] = nil
                        lanes[lane] = first
                        redirected[existing] = lane
                        edges.append(Edge(fromLane: lane, toLane: lane, color: color))
                    }
                } else {
                    lanes[lane] = first
                    edges.append(Edge(fromLane: lane, toLane: lane, color: color))
                }
                for parent in commit.parents.dropFirst() {
                    if let existing = lanes.firstIndex(where: { $0 == parent }) {
                        edges.append(Edge(fromLane: lane, toLane: existing, color: laneColors[existing]))
                    } else {
                        let fresh = allocateLane(expecting: parent)
                        edges.append(Edge(fromLane: lane, toLane: fresh, color: laneColors[fresh]))
                    }
                }
            } else {
                lanes[lane] = nil
            }
            for other in passing {
                edges.append(Edge(fromLane: other, toLane: redirected[other] ?? other, color: laneColors[other]))
            }

            // Lanes heading for the next commit bend into its lane, so the
            // edges of this row point where the dot will actually be.
            if index + 1 < commits.count {
                let next = commits[index + 1]
                let target = lanes.firstIndex(where: { $0 == next.hash })
                    ?? lanes.firstIndex(where: { $0 == nil })
                    ?? lanes.count
                for edgeIndex in edges.indices where lanes.indices.contains(edges[edgeIndex].toLane)
                    && lanes[edges[edgeIndex].toLane] == next.hash {
                    edges[edgeIndex].toLane = target
                }
            }

            widest = max(widest, lane + 1, (edges.map { max($0.fromLane, $0.toLane) + 1 }.max() ?? 0))
            rows.append(Row(commit: commit, lane: lane, color: color, edges: edges, passingLanes: passing))
        }

        return Layout(rows: rows, laneCount: widest)
    }
}
