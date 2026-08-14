import SwiftUI

/// A deliberately ordinary screen.
///
/// The other two demo screens are PII torture tests — almost every pixel is
/// sensitive, so "everything is masked" looks correct there and tells you nothing about
/// whether a real recording is worth watching. This is what an actual app looks like:
/// mostly navigation, status and structure, with a few genuinely sensitive fields. If a
/// replay of this screen is unreadable, the masking policy is wrong.
struct OrdersScreen: View {
    @State private var search = ""
    @State private var scope = 0

    private struct Order: Identifiable {
        let id: String
        let title: String
        let status: String
        let eta: String
        let price: String
        let tint: Color
    }

    private let orders: [Order] = [
        .init(id: "1", title: "Aeron Chair — Graphite", status: "Delivered", eta: "Arrived Mar 2", price: "$1,395", tint: .indigo),
        .init(id: "2", title: "Standing Desk 60\"", status: "In transit", eta: "Arrives Mar 8", price: "$899", tint: .teal),
        .init(id: "3", title: "Monitor Arm, Dual", status: "Preparing", eta: "Ships Mar 9", price: "$249", tint: .orange),
        .init(id: "4", title: "Desk Mat — Charcoal", status: "Delivered", eta: "Arrived Feb 24", price: "$65", tint: .pink),
        .init(id: "5", title: "Cable Tray", status: "Cancelled", eta: "Refunded", price: "$40", tint: .gray),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Scope", selection: $scope) {
                        Text("All").tag(0)
                        Text("Open").tag(1)
                        Text("Past").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }

                Section("Recent orders") {
                    ForEach(orders) { order in
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(order.tint.gradient)
                                .frame(width: 48, height: 48)
                                .overlay {
                                    Image(systemName: "shippingbox.fill")
                                        .foregroundStyle(.white)
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(order.title).font(.subheadline.weight(.medium))
                                HStack(spacing: 6) {
                                    Text(order.status)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                    Text(order.eta).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(order.price).font(.subheadline.monospacedDigit())
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Payment") {
                    // The genuinely sensitive part of an otherwise mundane screen.
                    LabeledContent("Card", value: "•••• 4429")
                    LabeledContent("Billing", value: "14 Ashgrove, Wellington")
                }
            }
            .searchable(text: $search, prompt: "Search orders")
            .navigationTitle("Orders")
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 150) }
        }
    }
}
