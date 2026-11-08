import UIKit

/// Names what a touch landed on the way VoiceOver would: the accessibility element under the
/// finger, its label (UIKit derives a button's from its title, SwiftUI an element's from its text),
/// role, hint, state and value. SwiftUI draws no view per control, so its elements come from the
/// hosting view's accessibility tree, which SwiftUI builds only while the system's accessibility is
/// on; without it a SwiftUI control is named by its gesture, if at all (``SwiftUIGestures``), and
/// never by the UIKit text inside SwiftUI's views, which is other controls'. UIKit's views are read
/// from their own properties too, wherever accessibility has nothing to say. Runs on the main thread
/// as a finger lands, right after UIKit delivers the touch, so every walk is bounded and the search
/// looks only inside views the touch is in.
enum TargetResolver {
    /// Elements visited per resolution, at most.
    static let nodeBudget = 500

    /// Superviews climbed from the touched view, at most.
    static let maxClimb = 32

    /// Views visited under an element for its text, or for a private view, at most.
    static let textBudget = 50

    static let maxPathSegments = 10
    static let maxPathLength = 200
    static let maxLabelLength = 200

    /// The target at `point` (in `window`'s coordinates), found from `touchedView`, the view UIKit
    /// delivered the touch to.
    static func resolve(touchedView: UIView?, window: UIWindow, point: CGPoint)
        -> InteractionTarget
    {
        let start = touchedView ?? window
        if let element = findElement(from: start, at: point, in: window) {
            return describe(element, from: start, window: window, point: point)
        }
        // With accessibility off, a SwiftUI control has no element, and the touch lands on one of
        // SwiftUI's own views: left unnamed, for its gesture to name it.
        let view = nearestControl(from: start)
        let namedByText = view !== start || !isSwiftUIs(start)
        return describe(view, from: start, window: window, point: point, namedByText: namedByText)
    }

    /// A text field or text view, by its own accessibility: where an edit happened.
    static func describe(field: UIView) -> InteractionTarget {
        guard let window = field.window else {
            let label = label(of: field, window: nil)
            return InteractionTarget(
                component: className(of: field), label: label.text, role: role(of: field),
                componentPath: componentPath(of: field), masked: label.masked || isPrivate(field))
        }
        let centre = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: window)
        return describe(field, from: field, window: window, point: centre)
    }

    private static func describe(
        _ element: NSObject, from start: UIView, window: UIWindow, point: CGPoint,
        namedByText: Bool = true
    ) -> InteractionTarget {
        let elementView = element as? UIView
        // A SwiftUI element is private when a private view overlaps it; a view (with accessibility
        // off, SwiftUI's hosting view itself), when the touch is inside one; either, when a label
        // its name was read from is.
        let region =
            elementView == nil
            ? frame(of: element, in: window) : CGRect(origin: point, size: .zero)
        let label = label(of: element, byText: namedByText, window: window)
        var target = InteractionTarget(
            componentPath: componentPath(of: elementView ?? start),
            masked: label.masked || isPrivate(start) || isPrivate(elementView)
                || holdsPrivate(elementView) || PrivateRegions.overlap(region, in: window))
        if let elementView { target.component = className(of: elementView) }
        target.label = label.text
        target.role = role(of: element)
        target.hint = clean(element.accessibilityHint)
        target.state = state(of: element)
        if !isTextEntry(element), let value = element.accessibilityValue, !value.isEmpty {
            target.valueText = String(value.prefix(maxLabelLength))
        }
        return target
    }

    // MARK: - Finding the element

    /// The smallest accessibility element containing `point`, searched from `view` and then from
    /// each superview in turn, so the touched control wins over a larger one around it. As UIKit's
    /// hit test does, the search never looks inside a view the touch is outside of: nothing there
    /// could have taken the touch, and on a dense screen it would be most of the search.
    static func findElement(from view: UIView, at point: CGPoint, in window: UIWindow) -> NSObject?
    {
        var budget = nodeBudget
        var current: UIView? = view
        var searched: UIView?
        var climbed = 0
        while let candidate = current, climbed <= maxClimb, budget > 0 {
            if let found = smallestElement(
                in: candidate, at: point, window: window, budget: &budget, skipping: searched)
            {
                return found.element
            }
            searched = candidate
            current = candidate.superview
            climbed += 1
        }
        return nil
    }

    /// `skipping` is a child already searched, one level down.
    private static func smallestElement(
        in node: NSObject, at point: CGPoint, window: UIWindow, budget: inout Int,
        skipping: NSObject? = nil
    ) -> (element: NSObject, area: CGFloat)? {
        guard budget > 0 else { return nil }
        budget -= 1
        // A view's own geometry first: accessibility's properties cost far more, most of all while
        // the system's accessibility is on.
        var viewFrame: CGRect?
        if let view = node as? UIView {
            if view.isHidden || view.alpha < 0.01 { return nil }
            let frame = view.convert(view.bounds, to: window)
            guard frame.contains(point) else { return nil }
            viewFrame = frame
        }
        if node.accessibilityElementsHidden { return nil }
        if node.isAccessibilityElement {
            let frame = viewFrame ?? frame(of: node, in: window)
            return frame.contains(point) ? (node, frame.width * frame.height) : nil
        }
        var best: (element: NSObject, area: CGFloat)?
        for child in accessibilityChildren(of: node) where child !== skipping {
            guard
                let found = smallestElement(in: child, at: point, window: window, budget: &budget)
            else { continue }
            if found.area < best?.area ?? .infinity { best = found }
        }
        return best
    }

    /// Where `node` is in `window`: a view's own geometry, else its accessibility frame.
    private static func frame(of node: NSObject, in window: UIWindow) -> CGRect {
        if let view = node as? UIView { return view.convert(view.bounds, to: window) }
        return window.convert(node.accessibilityFrame, from: window.screen.coordinateSpace)
    }

    /// What VoiceOver walks under `node`: its accessibility elements when it declares them, else a
    /// view's subviews.
    private static func accessibilityChildren(of node: NSObject) -> [NSObject] {
        if let elements = node.accessibilityElements, !elements.isEmpty {
            return elements.compactMap { $0 as? NSObject }
        }
        let count = node.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            return (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
        }
        return (node as? UIView)?.subviews ?? []
    }

    /// With no accessibility element under the finger, the control or cell around the touched view,
    /// else the touched view itself.
    private static func nearestControl(from view: UIView) -> UIView {
        var current: UIView? = view
        var climbed = 0
        while let candidate = current, climbed <= maxClimb {
            if candidate is UIControl || candidate is UITableViewCell
                || candidate is UICollectionViewCell
            {
                return candidate
            }
            current = candidate.superview
            climbed += 1
        }
        return view
    }

    // MARK: - Describing it

    /// The accessible name: the label, else the visible text: a button's title, or, `byText`, the
    /// labels inside a view. `masked` when one of those labels is private, inside a private view,
    /// or under a private SwiftUI view in `window`.
    private static func label(of element: NSObject, byText: Bool = true, window: UIWindow?)
        -> (text: String, masked: Bool)
    {
        let label = clean(element.accessibilityLabel)
        if !label.isEmpty { return (label, false) }
        if let button = element as? UIButton {
            let title = clean(button.currentTitle ?? button.titleLabel?.text)
            if !title.isEmpty { return (title, false) }
        }
        if byText, let view = element as? UIView { return visibleText(in: view, window: window) }
        return ("", false)
    }

    private static func visibleText(in view: UIView, window: UIWindow?) -> (
        text: String, masked: Bool
    ) {
        var texts: [String] = []
        var masked = false
        var budget = textBudget
        collectText(view, window: window, into: &texts, masked: &masked, budget: &budget)
        return (String(texts.joined(separator: " ").prefix(maxLabelLength)), masked)
    }

    private static func collectText(
        _ view: UIView, window: UIWindow?, into texts: inout [String], masked: inout Bool,
        budget: inout Int
    ) {
        guard budget > 0, texts.count < 5, !view.isHidden else { return }
        budget -= 1
        if facts(of: view).isTextInput { return }
        if let label = view as? UILabel {
            let text = clean(label.text)
            if !text.isEmpty {
                texts.append(text)
                masked = masked || isPrivate(label) || isUnderPrivateSwiftUI(label, in: window)
            }
            return
        }
        for subview in view.subviews {
            collectText(subview, window: window, into: &texts, masked: &masked, budget: &budget)
        }
    }

    /// Whether a private SwiftUI view's marker in `window` overlaps `view`.
    private static func isUnderPrivateSwiftUI(_ view: UIView, in window: UIWindow?) -> Bool {
        guard let window else { return false }
        return PrivateRegions.overlap(view.convert(view.bounds, to: window), in: window)
    }

    /// Whether `view` is one of SwiftUI's own (its hosting view, a scroll view or a container it
    /// draws into), by its type's module.
    private static func isSwiftUIs(_ view: UIView) -> Bool {
        facts(of: view).isSwiftUIs
    }

    /// The RN role for the element's traits, else for its class.
    static func role(of element: NSObject) -> String {
        if element is UISwitch { return "switch" }
        if isTextEntry(element) { return "textfield" }
        let traits = element.accessibilityTraits
        if #available(iOS 17.0, *), traits.contains(.toggleButton) { return "switch" }
        if traits.contains(.searchField) { return "search" }
        if traits.contains(.button) { return "button" }
        if traits.contains(.link) { return "link" }
        if traits.contains(.image) { return "image" }
        if traits.contains(.header) { return "header" }
        if traits.contains(.adjustable) { return "adjustable" }
        if traits.contains(.tabBar) { return "tabbar" }
        if traits.contains(.keyboardKey) { return "keyboardkey" }
        if traits.contains(.staticText) { return "text" }
        switch element {
        case is UIButton: return "button"
        case is UISlider, is UIStepper: return "adjustable"
        case is UIImageView: return "image"
        case is UILabel: return "text"
        default: return ""
        }
    }

    private static func state(of element: NSObject) -> [String: Any]? {
        let traits = element.accessibilityTraits
        let control = element as? UIControl
        var state: [String: Any] = [:]
        if traits.contains(.selected) || control?.isSelected == true { state["selected"] = true }
        if traits.contains(.notEnabled) || control?.isEnabled == false { state["disabled"] = true }
        return state.isEmpty ? nil : state
    }

    /// A field whose accessibility value is what the user typed, and is never sent.
    private static func isTextEntry(_ element: NSObject) -> Bool {
        facts(of: element).isTextInput || element.accessibilityTraits.contains(.searchField)
    }

    /// Whether `view` or an ancestor is private.
    private static func isPrivate(_ view: UIView?) -> Bool {
        var current: UIView? = view
        var climbed = 0
        while let candidate = current, climbed <= maxClimb {
            if candidate.groundcoverPrivate { return true }
            current = candidate.superview
            climbed += 1
        }
        return false
    }

    /// Whether a view inside `view` is private: the label of an element with none of its own is
    /// the text inside it, ours or the one UIKit composes for a cell.
    private static func holdsPrivate(_ view: UIView?) -> Bool {
        var budget = textBudget
        func walk(_ view: UIView) -> Bool {
            guard budget > 0 else { return false }
            budget -= 1
            return view.groundcoverPrivate || view.subviews.contains(where: walk)
        }
        return view.map(walk) ?? false
    }

    // MARK: - The path

    /// The views from the outside in (`UIWindow > UIView > UIButton`): the innermost
    /// ``maxPathSegments``, private classes (a leading underscore) left out, cut from the outside
    /// to ``maxPathLength`` characters. The climb stops once it has them.
    static func componentPath(of view: UIView) -> String {
        var names: [String] = []
        var current: UIView? = view
        var climbed = 0
        while let candidate = current, climbed <= maxClimb, names.count < maxPathSegments {
            let name = className(of: candidate)
            if !name.isEmpty, !name.hasPrefix("_") { names.append(name) }
            current = candidate.superview
            climbed += 1
        }
        var segments = Array(names.reversed())
        while segments.count > 1, segments.joined(separator: " > ").count > maxPathLength {
            segments.removeFirst()
        }
        return segments.joined(separator: " > ")
    }

    /// `HostingScrollView` for `SwiftUI.HostingScrollView`, `_UIHostingView` for
    /// `_UIHostingView<Home>`.
    static func className(of object: AnyObject) -> String {
        facts(of: object).name
    }

    /// What the resolver asks of a class on every touch, worked out once per class: a type's name
    /// is reflection, the path wants one per superview, and a protocol check walks the class's
    /// hierarchy, slower still while the system's accessibility hooks it.
    private struct TypeFacts {
        let name: String
        let isSwiftUIs: Bool
        let isTextInput: Bool
    }

    /// Kept on the main thread only, where the resolver runs. An app has a bounded set of classes.
    private static var typeFacts: [ObjectIdentifier: TypeFacts] = [:]

    private static func facts(of object: AnyObject) -> TypeFacts {
        let metatype = type(of: object)
        let key = ObjectIdentifier(metatype)
        let onMain = Thread.isMainThread
        if onMain, let known = typeFacts[key] { return known }
        var name = String(describing: metatype)
        if let generic = name.firstIndex(of: "<") { name = String(name[..<generic]) }
        if let dot = name.lastIndex(of: ".") { name = String(name[name.index(after: dot)...]) }
        let qualified = String(reflecting: metatype)
        let facts = TypeFacts(
            name: name,
            isSwiftUIs: qualified.hasPrefix("SwiftUI.") || qualified.hasPrefix("SwiftUICore."),
            isTextInput: object is UITextInput)
        if onMain { typeFacts[key] = facts }
        return facts
    }

    private static func clean(_ text: String?) -> String {
        guard let text else { return "" }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(maxLabelLength))
    }
}
