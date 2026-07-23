//
//  KeyboardViewController.swift
//  TshunhueKeyboard
//
//  Bridges iOS keyboard lifecycle and document-proxy actions into the shared KeyboardView.
//

import SwiftUI
import UIKit

/// The thin UIKit entry point required by Apple's custom-keyboard extension point.
final class KeyboardViewController: UIInputViewController {
    /// The App Group shared with the containing Tshunhue application.
    private static let appGroupIdentifier = "group.tw.poren.Tshunhue"
    /// The extension-local preference storing the last selected category.
    private static let selectedCategoryKey = "keyboardSelectedCategory"

    /// Observation state retained for this controller's lifetime.
    private var model: KeyboardModel?
    /// The directly hosted reusable SwiftUI keyboard.
    private var host: UIHostingController<KeyboardView>?
    /// The current appearance or cleanup task.
    private var lifecycleTask: Task<Void, Never>?
    /// The primary view height requested from UIKit for the current size class.
    private var keyboardHeightConstraint: NSLayoutConstraint?

    /// The regular-height and compact-height keyboard dimensions used by this UI.
    private static let regularKeyboardHeight: CGFloat = 300
    private static let compactKeyboardHeight: CGFloat = 220

    /// Creates the shared model and pins its SwiftUI view to the system keyboard bounds.
    override func viewDidLoad() {
        super.viewDidLoad()

        let applicationSupport = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        )?.appendingPathComponent("Tshunhue", isDirectory: true)
        let model = KeyboardModel(
            dataProvider: KeyboardDataStore(applicationSupport: applicationSupport),
            selectedCategory: Self.restoreSelectedCategory(),
            persistCategory: { Self.persistSelectedCategory($0) }
        )
        let rootView = KeyboardView(
            model: model,
            inputModeController: { [weak self] in self },
            insertCaption: { [weak self] frame in self?.insertCaption(frame) },
            insertSpace: { [weak self] in self?.insertSpace() },
            deleteBackward: { [weak self] in self?.deleteBackward() }
        )
        let host = UIHostingController(rootView: rootView)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.model = model
        self.host = host
    }

    /// Keeps the custom keyboard large enough for its result row and editing keys.
    override func updateViewConstraints() {
        super.updateViewConstraints()
        if let keyboardHeightConstraint {
            keyboardHeightConstraint.constant = preferredKeyboardHeight
        } else {
            let constraint = view.heightAnchor.constraint(equalToConstant: preferredKeyboardHeight)
            constraint.isActive = true
            keyboardHeightConstraint = constraint
        }
    }

    /// Chooses a shorter height when the system reports a compact vertical layout.
    private var preferredKeyboardHeight: CGFloat {
        traitCollection.verticalSizeClass == .compact
            ? Self.compactKeyboardHeight
            : Self.regularKeyboardHeight
    }

    /// Refreshes host text and permission-dependent state whenever the keyboard appears.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshQuery()
        lifecycleTask?.cancel()
        let mode: KeyboardAccessMode = hasFullAccess ? .images : .text
        let requiresInputModeSwitchKey = self.needsInputModeSwitchKey
        lifecycleTask = Task { [weak model] in
            await model?.activate(
                mode: mode,
                needsInputModeSwitchKey: requiresInputModeSwitchKey
            )
        }
    }

    /// Cancels view-scoped work and releases decoded images after dismissal.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        lifecycleTask?.cancel()
        lifecycleTask = Task { [weak model] in await model?.deactivate() }
    }

    /// Releases decoded image memory when iOS warns the extension process.
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        Task { [weak model] in await model?.handleMemoryWarning() }
    }

    // MARK: - Document Context

    /// Tracks edits made by the host app or another keyboard.
    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        refreshQuery()
    }

    /// Tracks caret and selection changes made by the host app.
    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        refreshQuery()
    }

    /// Updates the model from selected text or the current host line around the caret.
    private func refreshQuery() {
        model?.updateQuery(KeyboardQueryContext.query(
            selectedText: textDocumentProxy.selectedText,
            beforeInput: textDocumentProxy.documentContextBeforeInput,
            afterInput: textDocumentProxy.documentContextAfterInput
        ))
    }

    /// Lets the host finish its proxy mutation before reading the next text context.
    private func refreshQueryAfterDocumentChange() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.refreshQuery()
        }
    }

    // MARK: - Keyboard Actions

    /// Inserts a caption in Text Mode and publishes local completion feedback.
    private func insertCaption(_ frame: CatalogFrame) {
        textDocumentProxy.insertText(frame.frame.caption)
        model?.didInsertCaption(frame)
        refreshQueryAfterDocumentChange()
    }

    /// Inserts one space so the user can refine the current host-derived query.
    private func insertSpace() {
        textDocumentProxy.insertText(" ")
        refreshQueryAfterDocumentChange()
    }

    /// Deletes one character through Apple's document proxy.
    private func deleteBackward() {
        textDocumentProxy.deleteBackward()
        refreshQueryAfterDocumentChange()
    }

    // MARK: - Preferences

    /// Decodes the last category selected within this keyboard extension.
    private static func restoreSelectedCategory() -> CategoryKey? {
        guard let data = UserDefaults.standard.data(forKey: selectedCategoryKey) else { return nil }
        return try? JSONDecoder().decode(CategoryKey.self, from: data)
    }

    /// Stores the category locally because App Group writes require Full Access.
    private static func persistSelectedCategory(_ category: CategoryKey?) {
        if let category, let data = try? JSONEncoder().encode(category) {
            UserDefaults.standard.set(data, forKey: selectedCategoryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedCategoryKey)
        }
    }
}
