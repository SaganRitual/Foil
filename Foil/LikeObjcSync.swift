import Foundation

class LikeObjcSync {
    public class func synced(_ lock: Any, closure: () -> ()) {
        objc_sync_enter(lock)
        defer { objc_sync_exit(lock) }
        closure()
    }

    public class func syncedReturn(_ lock: Any, closure: () -> (Any?)) -> Any? {
        objc_sync_enter(lock)
        defer { objc_sync_exit(lock) }
        return closure()
    }
}
