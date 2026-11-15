import AppKit
import Core
import SwiftUI

/// The Manage accounts window: ordinary window content with the Add and Remove sheets. Every
/// change is one agent-balancer command run through the view model.
struct ManageWindowView: View {
    @Bindable var model: ManageViewModel
    let copy: (String) -> Void

    var body: some View {
        ManageContent(
            rows: model.rows, selection: model.selection, panel: model.panel,
            notice: model.notice, bar: model.bar, offReason: model.offReason,
            canAdd: model.canAct, removeEnabled: removeEnabled,
            endsDate: $model.endsDate, actions: actions
        )
        .frame(minWidth: 648, minHeight: 420)
        .background(WindowDock(title: "Manage accounts"))
        .sheet(
            isPresented: Binding(
                get: { model.add != nil }, set: { if !$0 { model.closeAdd() } })
        ) {
            AddSheetContent(
                draft: Binding(get: { model.add ?? AddDraft() }, set: { model.add = $0 }),
                problem: model.add.flatMap { model.addProblem($0) },
                steps: model.add.map { model.addSteps($0) } ?? [], busy: model.busy,
                tokenMode: model.settings.tokenSignIn,
                actions: AddSheetActions(
                    copy: copy, close: { model.closeAdd() },
                    submit: { Task { await model.submitAdd() } },
                    runStep: { step in Task { await model.runStep(step) } }),
                note: model.add.flatMap { model.addNote($0) }
            )
            // Esc stays off while a command runs, like the Cancel button.
            .interactiveDismissDisabled(model.busy)
        }
        .sheet(
            isPresented: Binding(
                get: { model.removeSheet != nil }, set: { if !$0 { model.closeRemove() } })
        ) {
            RemoveSheetContent(
                draft: Binding(
                    get: { model.removeSheet ?? RemoveDraft(label: "", text: "") },
                    set: { model.removeSheet = $0 }),
                canConfirm: model.removeSheet.map { model.canConfirmRemove($0) } ?? false,
                busy: model.busy,
                actions: RemoveSheetActions(
                    cancel: { model.closeRemove() },
                    confirm: { Task { await model.confirmRemove() } })
            )
            // Esc stays off while `remove` runs, like the Cancel button.
            .interactiveDismissDisabled(model.busy)
        }
        .onAppear {
            guard ManageWindowGate.requested else {
                NSApp.windows.first { $0.title == "Manage accounts" }?.close()
                return
            }
            model.windowOpened()
        }
        .onDisappear {
            ManageWindowGate.requested = false
            Task { await model.finishEndDate() }
            model.windowClosed()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
            note in
            // The window or one of its sheets became key, so a change made in Terminal shows.
            guard let window = note.object as? NSWindow else { return }
            if (window.sheetParent ?? window).title == "Manage accounts" {
                model.statusMayHaveChanged()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
            note in
            // Leaving the window ends an edit of the end date, as leaving the picker does.
            guard let window = note.object as? NSWindow, window.title == "Manage accounts" else {
                return
            }
            Task { await model.finishEndDate() }
        }
    }

    private var removeEnabled: Bool { model.panel?.remove?.enabled ?? false }

    private var actions: ManageActions {
        ManageActions(
            copy: copy,
            select: { label in
                // An end date edit under way is saved for the account it was made on.
                Task { await model.finishEndDate() }
                model.selection = label
            },
            openAdd: { model.openAdd() },
            openRemove: { model.openRemove() },
            signIn: {
                if let label = model.selection { Task { await model.signIn(label) } }
            },
            changeEnds: { choice in
                if let label = model.selection {
                    Task { await model.changeEnds(label: label, to: choice) }
                }
            },
            stepEndDate: { date in
                if let label = model.selection { model.stepEndDate(label: label, to: date) }
            },
            finishEndDate: { Task { await model.finishEndDate() } })
    }
}

/// While the window is open the app shows its icon in the Dock and the app switcher, and the
/// title bar carries the same icon. Closing the window puts the app back in the menu bar only.
/// The view model calls `apply` as the window opens and closes.
@MainActor
enum DockMode {
    static func apply(shown: Bool) {
        if shown {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// Sets the window title and puts the tile icon in the title bar, once per window.
struct WindowDock: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.title = title
            guard window.titlebarAccessoryViewControllers.isEmpty else { return }
            let icon = NSHostingView(rootView: TileIcon().frame(width: 18, height: 18))
            icon.frame = NSRect(x: 0, y: 0, width: 28, height: 18)
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = icon
            accessory.layoutAttribute = .leading
            window.addTitlebarAccessoryViewController(accessory)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
