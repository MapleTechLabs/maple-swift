import Foundation

/// The currently-active span.
///
/// Two mechanisms, because iOS networking spans both worlds. `@TaskLocal` is the correct
/// answer for `async`/`await` and propagates into child tasks for free. It does *not*
/// reach a `URLSession` completion handler or a delegate callback, which is where a large
/// share of real app code still lives — those run on an arbitrary queue with no task
/// context at all. So a thread-dictionary fallback carries the same value for
/// synchronous scopes.
///
/// Reads prefer the task-local. When both are set they agree, because both are written by
/// the same `withSpan`.
public enum TraceContext {
    @TaskLocal private static var taskLocalSpan: Span?

    private static let threadKey = "dev.maple.tracing.currentSpan"

    /// The span new spans should parent themselves to.
    public static var current: Span? {
        if let span = taskLocalSpan { return span }
        return Thread.current.threadDictionary[threadKey] as? Span
    }

    public static var activeTraceId: String? { current?.traceId }

    /// Run `body` with `span` active, restoring the previous span afterwards.
    public static func withSpan<T>(_ span: Span, _ body: () throws -> T) rethrows -> T {
        let previous = Thread.current.threadDictionary[threadKey]
        Thread.current.threadDictionary[threadKey] = span
        defer { Thread.current.threadDictionary[threadKey] = previous }
        return try $taskLocalSpan.withValue(span) { try body() }
    }

    /// Async variant. The thread-dictionary write is deliberately omitted: an `async`
    /// function can resume on a different thread than it suspended on, so a thread-keyed
    /// value would leak onto an unrelated thread and be missing on the one that resumed.
    /// The task-local is correct here and is inherited by child tasks.
    public static func withSpan<T>(_ span: Span, _ body: () async throws -> T) async rethrows -> T {
        try await $taskLocalSpan.withValue(span) { try await body() }
    }
}
