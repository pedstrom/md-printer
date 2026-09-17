#if canImport(UIKit)
import UIKit

/// A native search field gives Escape priority over the system's text-editing shortcut.
@MainActor
public final class MobileFindTextField: UITextField, UITextFieldDelegate {
    public var onTextChange: (String) -> Void = { _ in }
    public var onFocusChange: (Bool) -> Void = { _ in }
    public var onSearch: () -> Void = {}
    public var onPrint: () -> Void = {}
    public var onPreviousSearch: () -> Void = {}
    private var requestedFocus = false
    private var focusUpdatePending = false

    public init() {
        super.init(frame: .zero)
        delegate = self
        placeholder = "Find in Markdown"
        accessibilityIdentifier = "find-field"
        accessibilityLabel = "Find in Markdown"
        autocorrectionType = .no
        autocapitalizationType = .none
        returnKeyType = .search
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        addTarget(self, action: #selector(textChanged), for: .editingChanged)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    /// UIKit can ask SwiftUI for the next responder while changing focus.
    /// Apply the latest request after the current SwiftUI layout update ends.
    public func setFocused(_ focused: Bool) {
        requestedFocus = focused
        guard !focusUpdatePending else { return }
        focusUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusUpdatePending = false
            if self.requestedFocus && !self.isFirstResponder {
                self.becomeFirstResponder()
            } else if !self.requestedFocus && self.isFirstResponder {
                self.resignFirstResponder()
            }
        }
    }

    public override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelFind(_:)))
        escape.wantsPriorityOverSystemBehavior = true
        escape.discoverabilityTitle = "Done Finding"
        let next = UIKeyCommand(title: "Find Next", action: #selector(findNext(_:)), input: "g", modifierFlags: .command)
        let previous = UIKeyCommand(title: "Find Previous", action: #selector(findPrevious(_:)), input: "g", modifierFlags: [.command, .shift])
        for command in [next, previous] { command.wantsPriorityOverSystemBehavior = true }
        return [escape, next, previous] + (super.keyCommands ?? [])
    }

    @objc public func cancelFind(_ command: UIKeyCommand? = nil) {
        resignFirstResponder()
        onFocusChange(false)
    }

    public override func find(_ sender: Any?) { becomeFirstResponder(); onFocusChange(true) }
    public override func findNext(_ sender: Any?) { onSearch() }
    public override func findPrevious(_ sender: Any?) { onPreviousSearch() }
    public override func printContent(_ sender: Any?) { onPrint() }
    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if [#selector(cancelFind(_:)), #selector(printContent(_:)), #selector(find(_:)), #selector(findNext(_:)), #selector(findPrevious(_:))].contains(action) { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func textChanged() { onTextChange(text ?? "") }
    public func textFieldDidBeginEditing(_ textField: UITextField) { requestedFocus = true; onFocusChange(true) }
    public func textFieldDidEndEditing(_ textField: UITextField) { requestedFocus = false; onFocusChange(false) }
    public func textFieldShouldReturn(_ textField: UITextField) -> Bool { onSearch(); return false }
}

/// Provides document commands before a text field has focus. The view belongs to one scene.
@MainActor
public final class MobileDocumentKeyView: UIView {
    public var onCommand: (String) -> Void = { _ in }
    public override var canBecomeFirstResponder: Bool { true }

    public override var keyCommands: [UIKeyCommand]? {
        [("f", UIKeyModifierFlags.command, "Find"),
         ("g", .command, "Find Next"),
         ("g", [.command, .shift], "Find Previous"),
         ("s", [.command, .shift], "Share PDF"),
         ("p", .command, "Print PDF")].map { input, modifiers, title in
            let key = UIKeyCommand(title: title, action: #selector(performDocumentCommand(_:)), input: input, modifierFlags: modifiers)
            key.wantsPriorityOverSystemBehavior = true
            return key
        }
    }

    @objc public func performDocumentCommand(_ command: UIKeyCommand) {
        let value = command.input == "g" && command.modifierFlags.contains(.shift) ? "previous" : command.input ?? ""
        onCommand(value)
    }

    public override func find(_ sender: Any?) { onCommand("f") }
    public override func findNext(_ sender: Any?) { onCommand("g") }
    public override func findPrevious(_ sender: Any?) { onCommand("previous") }
    public override func printContent(_ sender: Any?) { onCommand("p") }

    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if [#selector(printContent(_:)), #selector(performDocumentCommand(_:)), #selector(find(_:)), #selector(findNext(_:)), #selector(findPrevious(_:))].contains(action) { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(windowActivated(_:)), name: UIWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowActivated(_:)), name: UIScene.didActivateNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.activateIfNeeded() }
    }

    @objc private func windowActivated(_ notification: Notification) {
        guard let window,
              (notification.object as? UIWindow) === window || (notification.object as? UIScene) === window.windowScene else { return }
        activateIfNeeded()
    }

    public func activateIfNeeded() {
        guard let window, window.windowScene?.activationState != .background,
              !isFirstResponder, !Self.containsTextInputResponder(window) else { return }
        becomeFirstResponder()
    }

    public static func containsTextInputResponder(_ view: UIView) -> Bool {
        (view is any UITextInput && view.isFirstResponder) || view.subviews.contains(where: containsTextInputResponder)
    }
}
#endif
