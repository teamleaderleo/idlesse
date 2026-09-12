import Foundation

struct CoverageRestPolicy: Equatable {
    let restThreshold: Double
    let resumeThreshold: Double
    let stableSamples: Int

    init(restThreshold: Double = 0.95, resumeThreshold: Double = 0.85, stableSamples: Int = 2) {
        precondition((0...1).contains(resumeThreshold))
        precondition((0...1).contains(restThreshold))
        precondition(resumeThreshold < restThreshold)
        precondition(stableSamples > 0)
        self.restThreshold = restThreshold
        self.resumeThreshold = resumeThreshold
        self.stableSamples = stableSamples
    }

    static func shouldRestSharedPlayback(globalPause: Bool, displayResting: [Bool]) -> Bool {
        globalPause || (!displayResting.isEmpty && displayResting.allSatisfy { $0 })
    }

    struct Decision: Equatable {
        let isResting: Bool
        let changed: Bool
        let candidate: Bool?
        let consecutiveSamples: Int
    }

    struct Tracker: Equatable {
        private(set) var isResting: Bool
        private var candidate: Bool?
        private var consecutiveSamples = 0

        init(isResting: Bool = false) {
            self.isResting = isResting
        }

        mutating func synchronize(isResting: Bool) {
            guard self.isResting != isResting else { return }
            self.isResting = isResting
            candidate = nil
            consecutiveSamples = 0
        }

        mutating func sample(_ fraction: Double, policy: CoverageRestPolicy) -> Decision {
            let fraction = min(1, max(0, fraction))
            let desired: Bool?
            if isResting {
                desired = fraction <= policy.resumeThreshold ? false : nil
            } else {
                desired = fraction >= policy.restThreshold ? true : nil
            }
            guard let desired else {
                candidate = nil
                consecutiveSamples = 0
                return Decision(isResting: isResting, changed: false,
                                candidate: nil, consecutiveSamples: 0)
            }
            if candidate == desired {
                consecutiveSamples += 1
            } else {
                candidate = desired
                consecutiveSamples = 1
            }
            guard consecutiveSamples >= policy.stableSamples else {
                return Decision(isResting: isResting, changed: false,
                                candidate: candidate, consecutiveSamples: consecutiveSamples)
            }
            let changed = isResting != desired
            isResting = desired
            candidate = nil
            consecutiveSamples = 0
            return Decision(isResting: isResting, changed: changed,
                            candidate: nil, consecutiveSamples: 0)
        }
    }
}
