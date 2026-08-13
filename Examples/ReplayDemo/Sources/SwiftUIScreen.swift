import SwiftUI

/// Deliberately full of the things that must never survive into a recording.
///
/// Every one of these is rendered by SwiftUI through private UIKit classes we refuse to
/// enumerate — so this screen is the real test of the unknown-leaf rule.
struct SwiftUIScreen: View {
    @State private var email = "ada.lovelace@example.com"
    @State private var password = "hunter2"
    @State private var note = ""

    private let transactions = [
        ("Acme Payroll", "+ $4,280.00", "Mar 1"),
        ("Blue Bottle Coffee", "− $6.75", "Mar 2"),
        ("Rent — 14 Ashgrove", "− $2,150.00", "Mar 3"),
        ("Refund · Order #88213", "+ $42.10", "Mar 4"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    LabeledContent("Name", value: "Ada Lovelace")
                    LabeledContent("Member since", value: "2019")
                    HStack {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .frame(width: 44, height: 44)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text("Ada Lovelace").font(.headline)
                            Text("Premium plan").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Credentials") {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                    TextField("Notes", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Transactions") {
                    ForEach(transactions, id: \.0) { name, amount, date in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(name)
                                Text(date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(amount).monospacedDigit()
                        }
                    }
                }
            }
            .navigationTitle("SwiftUI")
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 96) }
        }
    }
}
