import UIKit

/// One `input` interaction per edit of a text field or text view, labelled as VoiceOver names the
/// field, and never the text: an edit counts only when the field posted a change, which says that
/// something changed and not what. The edit ends when the field stops editing, or when a tap lands
/// outside it while it is still the one being edited (UIKit keeps a field focused through a tap
/// elsewhere); whichever comes first reports, once. Main thread only.
final class TextFieldObserver {
    private let report: (InteractionCapture) -> Void
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []
    private weak var editing: UIView?
    private var changed = false

    init(center: NotificationCenter = .default, report: @escaping (InteractionCapture) -> Void) {
        self.report = report
        self.center = center
        let begins = [
            UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification,
        ]
        let changes = [UITextField.textDidChangeNotification, UITextView.textDidChangeNotification]
        let ends = [
            UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification,
        ]
        for name in begins {
            observe(name) { [weak self] field in self?.began(field) }
        }
        for name in changes {
            observe(name) { [weak self] field in
                if field === self?.editing { self?.changed = true }
            }
        }
        for name in ends {
            observe(name) { [weak self] field in self?.ended(field) }
        }
    }

    func stop() {
        for token in tokens { center.removeObserver(token) }
        tokens = []
        editing = nil
    }

    /// A tap at `point` in `window`: outside the field being edited, the edit is over.
    func tapped(at point: CGPoint, in window: UIWindow) {
        guard let field = editing, field.window === window else { return }
        if field.convert(field.bounds, to: window).contains(point) { return }
        finish(field)
    }

    private func observe(_ name: Notification.Name, _ handle: @escaping (UIView) -> Void) {
        tokens.append(
            center.addObserver(forName: name, object: nil, queue: nil) { note in
                if let field = note.object as? UIView { handle(field) }
            })
    }

    private func began(_ field: UIView) {
        if let previous = editing, previous !== field { finish(previous) }
        editing = field
        changed = false
    }

    private func ended(_ field: UIView) {
        guard field === editing else { return }
        finish(field)
        editing = nil
    }

    private func finish(_ field: UIView) {
        guard changed else { return }
        changed = false
        report(InteractionCapture(kind: .input, target: TargetResolver.describe(field: field)))
    }
}
