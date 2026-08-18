import Maple
import SwiftUI

/// Where propagation is actually observable.
///
/// Redaction can be checked by looking at an MP4, but "the backend span is a child of the
/// phone's span" cannot be seen anywhere on the device — it is a property of what arrives
/// at the warehouse. So this screen fires real requests at a real Maple-instrumented
/// backend and prints the trace id it used, which is the handle for going and looking.
struct NetworkScreen: View {
    @StateObject private var model = NetworkModel()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.target.absoluteString)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Target")
                } footer: {
                    Text("Override with MAPLE_TRACE_TARGET.")
                }

                Section("Requests") {
                    Button("GET — expect 2xx/401") { model.run(.ok) }
                    Button("GET missing path — expect 404") { model.run(.notFound) }
                    Button("Unreachable host — transport failure") { model.run(.unreachable) }
                    Button("Checkout flow — one trace, three spans") { model.runCheckout() }
                }

                Section("Result") {
                    if model.log.isEmpty {
                        Text("No requests yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.log) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.summary).font(.subheadline)
                                Text(entry.traceId)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Network")
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 150) }
        }
        .mapleScreen("Network")
    }
}

@MainActor
final class NetworkModel: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let summary: String
        let traceId: String
    }

    enum Request { case ok, notFound, unreachable }

    @Published private(set) var log: [Entry] = []

    /// Defaults to the API sibling of whatever ingest host is configured, so pointing the
    /// demo at a local stack moves both ends at once.
    ///
    /// Deliberately not `/health`: the API disables its tracer for that route, so a
    /// request there proves nothing about propagation. An unauthenticated `/v2/…` call
    /// answers 401 and *is* traced — and a 401 is a good demonstration in its own right,
    /// since the SDK records it as `Ok` rather than flooding an error dashboard.
    var target: URL {
        if let override = ProcessInfo.processInfo.environment["MAPLE_TRACE_TARGET"],
           let url = URL(string: override) {
            return url
        }
        let endpoint = ProcessInfo.processInfo.environment["MAPLE_ENDPOINT"] ?? "https://ingest.maple.dev"
        let api = endpoint.replacingOccurrences(of: "://ingest.", with: "://api.")
        return URL(string: api + "/v2/services") ?? URL(string: "https://api.maple.dev/v2/services")!
    }

    func run(_ kind: Request) {
        let url: URL
        switch kind {
        case .ok: url = target
        case .notFound: url = target.appendingPathComponent("definitely-not-a-route")
        case .unreachable: url = URL(string: "https://offline.invalid/orders")!
        }
        Task { await perform(url, label: url.lastPathComponent) }
    }

    /// A manual parent span with two requests inside it. Both children inherit the trace,
    /// and the `traceparent` each sends carries its own span id — so the backend hangs its
    /// server spans under the right one and the waterfall nests three levels deep.
    func runCheckout() {
        Task {
            await Maple.span("checkout") { span in
                Maple.track("checkout_started", properties: ["source": "demo"])
                await perform(target, label: "cart")
                await perform(target.appendingPathComponent("orders"), label: "submit")
                _ = span
            }
        }
    }

    /// The `URLSession` call itself is deliberately plain — the instrumentation picks it
    /// up and injects `traceparent` with no code here. The enclosing span exists only so
    /// the demo can *print* the trace id; a real app would not need it.
    private func perform(_ url: URL, label: String) async {
        await Maple.span("demo.request", attributes: ["demo.label": .string(label)]) { span in
            let started = Date()
            var summary: String
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                summary = "\(label) → \(status) in \(Int(Date().timeIntervalSince(started) * 1000))ms"
            } catch {
                summary = "\(label) → failed: \(error.localizedDescription)"
            }
            let traceId = span?.traceId ?? "(tracing off)"
            log.insert(Entry(summary: summary, traceId: traceId), at: 0)
            print("[ReplayDemo] \(summary) trace=\(traceId)")
        }
    }
}
