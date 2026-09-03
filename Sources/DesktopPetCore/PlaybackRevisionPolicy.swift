import Foundation

/// Accepts work only from the playback/timer generation that scheduled it.
public enum PlaybackRevisionPolicy {
    public static func shouldAccept(expected: UInt, current: UInt) -> Bool {
        expected == current
    }
}
