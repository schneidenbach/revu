import Foundation

/// Debounce + single-flight for automatic refreshes. Pure (times are passed in) so it can be tested
/// without sleeping: a refresh fires `delay` after the last relevant event, never while one is running,
/// and events that arrive during a refresh collapse into exactly one follow-up.
public struct RefreshCoalescer: Sendable {
    public let delay: TimeInterval
    private var lastEvent: TimeInterval?
    private var running = false

    public init(delay: TimeInterval = 0.4) { self.delay = delay }

    public mutating func noteEvent(at now: TimeInterval) { lastEvent = now }

    /// When the next refresh may start, or nil if nothing is pending.
    public var nextDeadline: TimeInterval? { lastEvent.map { $0 + delay } }

    /// Returns true (and marks a refresh as running) if one should start now.
    public mutating func poll(at now: TimeInterval) -> Bool {
        guard !running, let lastEvent, now >= lastEvent + delay else { return false }
        self.lastEvent = nil
        running = true
        return true
    }

    public mutating func finish() { running = false }
}

/// Retry schedule for automatic refreshes that fail (e.g. while the agent is mid-rebase): one retry
/// after `delay`, no tight loops, and give up after `maxConsecutiveFailures` failures in a row.
public struct RefreshRetryPolicy: Sendable {
    public let delay: TimeInterval
    public let maxConsecutiveFailures: Int
    public private(set) var failures = 0

    public init(delay: TimeInterval = 1.5, maxConsecutiveFailures: Int = 3) {
        self.delay = delay
        self.maxConsecutiveFailures = maxConsecutiveFailures
    }

    public mutating func recordSuccess() { failures = 0 }

    /// A new request (file event or ⌘R) starts a fresh series.
    public mutating func reset() { failures = 0 }

    /// Seconds to wait before retrying, or nil once the limit is reached.
    public mutating func recordFailure() -> TimeInterval? {
        failures += 1
        return failures < maxConsecutiveFailures ? delay : nil
    }
}
