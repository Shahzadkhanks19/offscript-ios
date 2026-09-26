import Foundation

public enum LifecyclePolicy {
    public static func canTransition(from current: EncounterLifecycle, to next: EncounterLifecycle) -> Bool {
        if current == next { return true }
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
             (_, .recovering),
             (.recovering, .active),
             (_, .failed),
             (_, .cancelled):
            return true
        default:
            return false
        }
    }
}
