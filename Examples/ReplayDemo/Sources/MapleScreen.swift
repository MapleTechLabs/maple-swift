import Maple
import SwiftUI

/// Screen tracking for SwiftUI.
///
/// The SDK swizzles `UIViewController.viewDidAppear`, which is the right hook for a UIKit
/// app — but a SwiftUI app has exactly one `UIHostingController` for the whole thing, so
/// the swizzle would report one screen forever. Views announce themselves instead.
///
/// Applied at the tab site rather than inside each screen so the screens stay ordinary
/// SwiftUI with no SDK imports — which is also the honest demonstration of how little a
/// host app has to change.
struct MapleScreen: ViewModifier {
    let name: String
    @State private var span: Span?

    func body(content: Content) -> some View {
        content
            .onAppear { span = Maple.trackScreen(name) }
            .onDisappear {
                // Ending on disappear makes the span's duration the time the screen was
                // actually on screen, which is the only reading of it worth having.
                span?.end()
                span = nil
            }
    }
}

extension View {
    func mapleScreen(_ name: String) -> some View {
        modifier(MapleScreen(name: name))
    }
}
