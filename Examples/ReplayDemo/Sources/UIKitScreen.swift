import SwiftUI
import UIKit

/// The UIKit half of the demo. Same sensitive content as the SwiftUI screen, built from
/// classes the scanner recognises by name — so a diff between the two recordings shows
/// what the unknown-leaf rule is actually doing.
struct UIKitScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: UIKitProfileController())
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

final class UIKitProfileController: UIViewController, UITableViewDataSource {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    private let rows: [(String, String)] = [
        ("Card ending", "•••• 4429"),
        ("Billing address", "14 Ashgrove, Wellington"),
        ("Phone", "+64 21 555 0134"),
        ("Support PIN", "884213"),
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "UIKit"
        view.backgroundColor = .systemGroupedBackground

        let header = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 220))

        let avatar = UIImageView(frame: CGRect(x: 16, y: 16, width: 72, height: 72))
        avatar.image = Self.solidImage(size: CGSize(width: 72, height: 72), color: .systemIndigo)
        avatar.layer.cornerRadius = 36
        avatar.clipsToBounds = true

        let name = UILabel(frame: CGRect(x: 100, y: 24, width: 240, height: 24))
        name.text = "Ada Lovelace"
        name.font = .preferredFont(forTextStyle: .headline)

        let email = UILabel(frame: CGRect(x: 100, y: 52, width: 240, height: 20))
        email.text = "ada.lovelace@example.com"
        email.font = .preferredFont(forTextStyle: .subheadline)
        email.textColor = .secondaryLabel

        let field = UITextField(frame: CGRect(x: 16, y: 108, width: 320, height: 40))
        field.borderStyle = .roundedRect
        field.placeholder = "Search transactions"
        field.text = "rent"

        let secure = UITextField(frame: CGRect(x: 16, y: 156, width: 320, height: 40))
        secure.borderStyle = .roundedRect
        secure.isSecureTextEntry = true
        secure.text = "hunter2"

        [avatar, name, email, field, secure].forEach(header.addSubview)

        tableView.dataSource = self
        tableView.tableHeaderView = header
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.contentInset.bottom = 96
        view.addSubview(tableView)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: "cell")
        cell.textLabel?.text = rows[indexPath.row].0
        cell.detailTextLabel?.text = rows[indexPath.row].1
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private static func solidImage(size: CGSize, color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
