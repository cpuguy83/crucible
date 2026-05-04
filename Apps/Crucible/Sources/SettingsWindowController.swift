import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private let onClose: () -> Void
    private let menuController: SettingsMenuController

    init(viewModel: TrayViewModel, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.menuController = SettingsMenuController(viewModel: viewModel)
        let view = SettingsWindowView(viewModel: viewModel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Crucible Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        let toolbar = NSToolbar(identifier: "CrucibleSettingsToolbar")
        toolbar.showsBaselineSeparator = false
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        toolbar.delegate = self
        removeToolbarChrome()
        DispatchQueue.main.async { [weak self] in
            self?.removeToolbarChrome()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        menuController.install()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        removeToolbarChrome()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            self?.removeToolbarChrome()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        menuController.install()
        removeToolbarChrome()
    }

    func windowDidUpdate(_ notification: Notification) {
        removeToolbarChrome()
    }

    func windowWillClose(_ notification: Notification) {
        menuController.uninstall()
        NSApplication.shared.setActivationPolicy(.accessory)
        onClose()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        nil
    }

    private func removeToolbarChrome() {
        guard let toolbar = window?.toolbar else { return }
        for index in toolbar.items.indices.reversed() {
            toolbar.removeItem(at: index)
        }
        toolbar.showsBaselineSeparator = false
        hideSidebarToggle(in: window?.contentView?.superview)
    }

    private func hideSidebarToggle(in view: NSView?) {
        guard let view else { return }
        if let button = view as? NSButton,
           button.action.map(NSStringFromSelector) == "toggleSidebar:" {
            button.isHidden = true
            button.isEnabled = false
        }
        for subview in view.subviews {
            hideSidebarToggle(in: subview)
        }
    }
}

@MainActor
private final class SettingsMenuController: NSObject, NSMenuItemValidation {
    private weak var viewModel: TrayViewModel?
    private var previousMainMenu: NSMenu?

    init(viewModel: TrayViewModel) {
        self.viewModel = viewModel
    }

    func install() {
        guard NSApp.mainMenu !== settingsMenu else { return }
        if previousMainMenu == nil {
            previousMainMenu = NSApp.mainMenu
        }
        NSApp.mainMenu = settingsMenu
    }

    func uninstall() {
        if NSApp.mainMenu === settingsMenu {
            NSApp.mainMenu = previousMainMenu
        }
        previousMainMenu = nil
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        guard let viewModel else { return false }

        switch action {
        case #selector(startBuilder):
            return viewModel.canStart
        case #selector(stopBuilder):
            return viewModel.canStop
        case #selector(restartBuilder):
            return viewModel.canRestart
        case #selector(copyBuildKitHostEnv):
            return viewModel.displayedSocketPath != nil
        case #selector(copyDockerHostEnv):
            return viewModel.displayedSocketPath != nil
        case #selector(copyBuildxCreateCommand):
            return viewModel.displayedSocketPath != nil
        case #selector(copyDockerContextCommand):
            return viewModel.displayedSocketPath != nil
        default:
            return true
        }
    }

    private lazy var settingsMenu: NSMenu = {
        let mainMenu = NSMenu(title: "Main Menu")
        mainMenu.addItem(menuItem("Crucible", submenu: appMenu))
        mainMenu.addItem(menuItem("Builder", submenu: builderMenu))
        mainMenu.addItem(menuItem("Integrations", submenu: integrationsMenu))
        mainMenu.addItem(menuItem("Window", submenu: windowMenu))
        return mainMenu
    }()

    private lazy var appMenu: NSMenu = {
        let menu = NSMenu(title: "Crucible")
        menu.addItem(item("About Crucible", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Close Settings", action: #selector(closeSettings), key: "q"))
        return menu
    }()

    private lazy var builderMenu: NSMenu = {
        let menu = NSMenu(title: "Builder")
        menu.addItem(item("Start", action: #selector(startBuilder)))
        menu.addItem(item("Stop", action: #selector(stopBuilder)))
        menu.addItem(item("Restart", action: #selector(restartBuilder)))
        return menu
    }()

    private lazy var integrationsMenu: NSMenu = {
        let menu = NSMenu(title: "Integrations")
        menu.addItem(item("Copy BUILDKIT_HOST Env", action: #selector(copyBuildKitHostEnv)))
        menu.addItem(item("Copy DOCKER_HOST Env", action: #selector(copyDockerHostEnv)))
        menu.addItem(item("Copy buildx Create Command", action: #selector(copyBuildxCreateCommand)))
        menu.addItem(item("Copy Docker Context Command", action: #selector(copyDockerContextCommand)))
        return menu
    }()

    private lazy var windowMenu: NSMenu = {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Close Settings", action: #selector(closeSettings), key: "w"))
        return menu
    }()

    private func menuItem(_ title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func item(_ title: String, action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    @objc private func closeSettings() {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(nil)
    }

    @objc private func startBuilder() {
        viewModel?.startFromMenu()
    }

    @objc private func stopBuilder() {
        viewModel?.stop()
    }

    @objc private func restartBuilder() {
        viewModel?.restart()
    }

    @objc private func copyBuildKitHostEnv() {
        viewModel?.copyBuildKitHostEnv()
    }

    @objc private func copyDockerHostEnv() {
        viewModel?.copyDockerHostEnv()
    }

    @objc private func copyBuildxCreateCommand() {
        viewModel?.copyBuildxCreateCommand()
    }

    @objc private func copyDockerContextCommand() {
        viewModel?.copyDockerContextCreateCommand()
    }

}
