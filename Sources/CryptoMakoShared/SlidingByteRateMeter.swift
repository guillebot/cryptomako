import Foundation

/// Sliding-window upload rate from cumulative completed bytes.
///
/// Samples `(time, cumulativeBytes)` and reports `Δbytes / Δt` over roughly
/// `windowSeconds` of wall clock. Completion bursts (many parallel puts finishing
/// in one UI flush) cannot invent multi-Gbps readings because the denominator is
/// the window span, not the inter-completion gap.
///
/// Cap changes must **not** reset this meter: zeroing cumulative bytes while
/// in-flight puts still complete dumps a large `Δbytes` into a short elapsed and
/// was the 2.6 Gbps bug after removing a Sync Mbps limit mid-run. The window
/// adapts to a new regime within about one `windowSeconds`.
public struct SlidingByteRateMeter: Equatable, Sendable {
    public var windowSeconds: TimeInterval
    public var minElapsed: TimeInterval
    /// Absurdity guard only (bytes/s). Product paths are far below this;
    /// documents belt-and-suspenders against a regressing short window.
    public var maxBytesPerSecond: Double?
    public var minSampleGap: TimeInterval

    private struct Sample: Equatable, Sendable {
        var at: Date
        var bytes: Int64
    }

    private var samples: [Sample] = []

    /// 10 Gbit/s in cleartext bytes/s — not a product cap; rejects numerical nonsense.
    public static let absurdityClampBytesPerSecond: Double = 1_250_000_000

    public init(
        windowSeconds: TimeInterval = 8,
        minElapsed: TimeInterval = 1.0,
        maxBytesPerSecond: Double? = SlidingByteRateMeter.absurdityClampBytesPerSecond,
        minSampleGap: TimeInterval = 0.25
    ) {
        self.windowSeconds = windowSeconds
        self.minElapsed = minElapsed
        self.maxBytesPerSecond = maxBytesPerSecond
        self.minSampleGap = minSampleGap
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    public var hasSamples: Bool { !samples.isEmpty }

    /// Observe cumulative completed bytes at `now`. Returns bytes/s when the
    /// sample span is at least `minElapsed`, else `nil` (caller keeps last rate).
    @discardableResult
    public mutating func observe(cumulativeBytes: Int64, at now: Date = Date()) -> Double? {
        let bytes = max(Int64(0), cumulativeBytes)
        if let last = samples.last, now.timeIntervalSince(last.at) < minSampleGap {
            // Same bucket: fold bytes in without collapsing the bucket's start time.
            samples[samples.count - 1].bytes = max(last.bytes, bytes)
        } else {
            samples.append(Sample(at: now, bytes: bytes))
        }

        // Keep one sample at or before the cutoff so Δt stays ≈ windowSeconds
        // instead of collapsing to the gap between the two newest points.
        let cutoff = now.addingTimeInterval(-windowSeconds)
        while samples.count > 1, samples[1].at <= cutoff {
            samples.removeFirst()
        }

        guard let oldest = samples.first, let newest = samples.last else { return nil }
        let elapsed = newest.at.timeIntervalSince(oldest.at)
        guard elapsed >= minElapsed, elapsed.isFinite else { return nil }
        let delta = max(Int64(0), newest.bytes - oldest.bytes)
        var rate = Double(delta) / elapsed
        if let cap = maxBytesPerSecond {
            rate = min(rate, cap)
        }
        return rate
    }
}
