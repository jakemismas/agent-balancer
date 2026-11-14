import AppKit
import Core
import ServiceManagement
import SwiftUI

/// Owns the controller and the few things only the app can do: copy, open the usage page, the
/// login item and quit. It keeps no preferences and writes no file.
@MainActor @Observable
final class AppModel {
    let controller: MenuController
    let manage: ManageViewModel
    private(set) var loginItemOn = false
    private(set) var loginItemError: String?

    init() {
        let context = ToolContext.current()
        controller = MenuController(context: context)
        manage = ManageViewModel(context: context)
        controller.afterFileRead = { [manage] in manage.statusMayHaveChanged() }
        refreshLoginItem()
        controller.start()
    }

    func refreshLoginItem() {
        loginItemOn = SMAppService.mainApp.status == .enabled
    }

    func toggleLoginItem() {
        do {
            if loginItemOn {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Could not change Open at login."
        }
        refreshLoginItem()
    }

    func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    var actions: PanelActions {
        PanelActions(
            refresh: { [controller] in Task { await controller.refreshNow() } },
            toggleLogin: { [weak self] in self?.toggleLoginItem() },
            quit: { NSApplication.shared.terminate(nil) },
            copy: { [weak self] in self?.copy($0) ?? () },
            manage: { [manage] label in
                if let label { manage.select(label) } else { manage.reload() }
            })
    }
}

enum ManageWindowID { static let value = "manage" }

/// A Window scene opens at launch on macOS 14. The window opens only after the person asks for
/// it, and any other first appearance closes it so the app stays menu bar only.
@MainActor
enum ManageWindowGate {
    static var requested = false
}

struct AgentBalancerBarApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(
                screen: model.controller.screen, refreshState: model.controller.refreshState,
                loginItemOn: model.loginItemOn, loginItemError: model.loginItemError,
                actions: model.actions)
        } label: {
            Image(nsImage: MenuIcon.image())
        }
        .menuBarExtraStyle(.window)
        Window("Manage accounts", id: ManageWindowID.value) {
            ManageWindowView(model: model.manage, copy: model.copy)
        }
        .windowResizability(.contentMinSize)
    }
}
