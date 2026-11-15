import UIKit

/// SwiftUI buttons the accessibility tree can't name. SwiftUI draws no view per control and builds
/// its accessibility tree only while the system's accessibility is on (VoiceOver, an automation
/// client), so for most users a tap on a SwiftUI control finds no element. UIKit still holds the
/// gesture SwiftUI attached: once a finger is down on a button (a NavigationLink is one too), one
/// of the touch's gesture recognizers is named after its type
/// (`Button<ResolvedButtonStyleBody<…>>`), and on some releases the touch's description names its
/// `_ButtonGesture`. Neither is API: a release that renames them loses the name, never the tap.
enum SwiftUIGestures {
    /// `target`, named as a SwiftUI button when nothing else named it: SwiftUI's type as the
    /// component and the role, with no label, as the browser reports an element that has no
    /// accessible name. The recognizers and the description are read only for such a target, and
    /// the recognizers' names, which SwiftUI builds on every read, only until one names a button.
    static func named<Names: Sequence>(
        _ target: InteractionTarget, recognizerNames: @autoclosure () -> Names,
        description: () -> String
    ) -> InteractionTarget where Names.Element == String? {
        guard target.label.isEmpty, target.role.isEmpty,
            isButton(recognizerNames: recognizerNames(), description: description)
        else { return target }
        var named = target
        named.component = "Button"
        named.role = "button"
        return named
    }

    /// Read while the finger is down: by the time it lifts, UIKit has let go of the recognizers.
    static func isButton<Names: Sequence>(recognizerNames: Names, description: () -> String) -> Bool
    where Names.Element == String? {
        if recognizerNames.contains(where: { $0?.hasPrefix("Button<") == true }) { return true }
        return description().contains("ButtonGesture")
    }
}
