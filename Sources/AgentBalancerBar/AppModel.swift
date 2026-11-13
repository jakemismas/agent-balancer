import AppKit
import Core
import ServiceManagement
import SwiftUI

/// Owns the controller and the few things only the app can do: copy, open the usage page, the
/// login item and quit. It keeps no preferences and writes no file.
@MainActor @Observable
final class AppModel {
    let controller: MenuController
    private(set) var loginItemOn = false
    private(set) var loginItemError: String?

    init() {
        controller = MenuController(context: ToolContext.current())
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
            copy: { [weak self] in self?.copy($0) ?? () })
    }
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
    }
}
