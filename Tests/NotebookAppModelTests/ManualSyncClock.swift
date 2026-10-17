@testable import NotebookAppModel
import TestSupport

extension NotebookSyncClock {
    static func manual(_ clock: ManualClock) -> NotebookSyncClock {
        NotebookSyncClock(
            now: clock.now, uptime: clock.uptime,
            elapsed: clock.elapsed, sleepUntil: clock.sleep(until:)
        )
    }
}
