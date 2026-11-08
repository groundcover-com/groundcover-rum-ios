import ObjectiveC
import SwiftUI
import UIKit

extension UIView {
    /// Masks the label and hint of every tap on this view or inside it as `***`, whatever the
    /// privacy level. The counterpart of React Native's `dataPrivate`. The view itself, and what
    /// VoiceOver reads, are untouched.
    @objc public var groundcoverPrivate: Bool {
        get { (objc_getAssociatedObject(self, &privateKey) as? NSNumber)?.boolValue ?? false }
        set {
            objc_setAssociatedObject(
                self, &privateKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

private var privateKey: UInt8 = 0

extension View {
    /// Names the screen this view is, for a SwiftUI screen that no view controller of its own
    /// presents: it is stamped on the events under it from when it appears. `key` tells two live
    /// copies of one screen apart.
    public func groundcoverScreen(_ name: String, key: String? = nil) -> some View {
        modifier(ScreenModifier(name: name, key: key))
    }

    /// Masks the label and hint of every tap inside this view as `***`, whatever the privacy
    /// level. The SwiftUI counterpart of ``UIKit/UIView/groundcoverPrivate``.
    public func groundcoverPrivate(_ isPrivate: Bool = true) -> some View {
        background(PrivateMarker(isPrivate: isPrivate).accessibilityHidden(true))
    }
}
