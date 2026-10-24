import SwiftUI

extension View {
    // Tests locate the real rendered bounds, then send mouse events through
    // AppKit hit testing. Release builds keep only normal accessibility IDs.
    func interactionTarget(_ id: String) -> some View {
        #if NOSY_UI_TEST
        self.accessibilityIdentifier(id).background(InteractionTarget(id: id).allowsHitTesting(false))
        #else
        self.accessibilityIdentifier(id)
        #endif
    }
}

#if NOSY_UI_TEST
import AppKit

struct InteractionTarget: NSViewRepresentable {
    let id: String
    final class Anchor: NSView {
        var id = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.id = id
        return view
    }
    func updateNSView(_ view: Anchor, context: Context) { view.id = id }
}
#endif
