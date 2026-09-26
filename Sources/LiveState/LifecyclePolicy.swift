import Foundation

public enum LifecyclePolicy {
    public static func canTransition(from current: EncounterLifecycle, to next: EncounterLifecycle) -> Bool {
        if current == next { return true }

        // Terminal states are immutable. A new attempt must be represented by
        // an explicit retry/branch flow rather than reviving a terminal state.
        if isTerminal(current) { return false }

        switch (current, next) {
        case (.created, .preparing),
             (.preparing, .ready),
             (.ready, .starting),
             (.starting, .active),
             (.active, .paused),
             (.paused, .active),
             (.active, .ending),
             (.ending, .processing),
             (.processing, .completed),
             (.completed, .reviewing),
             (.reviewing, .retrying),
             (.retrying, .active),
             (.recovering, .active):
            return true

        case (.preparing, .recovering),
             (.ready, .recovering),
             (.starting, .recovering),
             (.active, .recovering),
             (.paused, .recovering),
             (.ending, .recovering),
             (.processing, .recovering),
             (.reviewing, .recovering),
             (.retrying, .recovering):
            return true

        case (.preparing, .failed),
             (.ready, .failed),
             (.starting, .failed),
             (.active, .failed),
             (.paused, .failed),
             (.ending, .failed),
             (.processing, .failed),
             (.recovering, .failed),
             (.reviewing, .failed),
             (.retrying, .failed):
            return true

        case (.created, .cancelled),
             (.preparing, .cancelled),
             (.ready, .cancelled),
             (.starting, .cancelled),
             (.active, .cancelled),
             (.paused, .cancelled),
             (.ending, .cancelled),
             (.processing, .cancelled),
             (.recovering, .cancelled),
             (.completed, .cancelled),
             (.reviewing, .cancelled),
             (.retrying, .cancelled):
            return true

        default:
            return false
        }
    }

    public static func isTerminal(_ lifecycle: EncounterLifecycle) -> Bool {
        lifecycle == .failed || lifecycle == .cancelled
    }
}
