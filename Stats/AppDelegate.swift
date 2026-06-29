//
//  AppDelegate.swift
//  Stats
//
//  Created by Serhiy Mytrovtsiy on 28.05.2019.
//  Copyright © 2019 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

import Kit
import UserNotifications

import CPU
import RAM
import Disk
import Net
import Battery
import Sensors
import GPU
import Bluetooth
import Clock
import Remote

let updater = Updater(github: "exelban/stats", url: "https://api.mac-stats.com/release/latest")
var modules: [Module] = [
    CPU(),
    GPU(),
    RAM(),
    Disk(),
    Sensors(),
    Network(),
    Battery(),
    Bluetooth(),
    Clock(),
    Remote()
]

@main
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    internal var settingsWindow: SettingsWindow?
    internal var updateWindow: UpdateWindow?
    internal var setupWindow: SetupWindow?
    internal var supportWindow: SupportWindow?
    
    internal var menuBarItem: NSStatusItem? = nil
    internal var combinedView: CombinedView = CombinedView()
    
    internal let updateActivity = NSBackgroundActivityScheduler(identifier: "eu.exelban.Stats.updateCheck")
    internal let supportActivity = NSBackgroundActivityScheduler(identifier: "eu.exelban.Stats.support")
    
    internal var clickInNotification: Bool = false
    
    internal var pauseState: Bool {
        Store.shared.bool(key: "pause", defaultValue: false)
    }
    
    private var startTS: Date?
    private var launchStart: Date?

    // Readers are paused while nothing is visible. Track each input separately and only
    // resume when the display is on, the screen is unlocked, and the menu bar is showing
    // (a wake event can arrive while the lock screen is still up).
    private var displayAsleep: Bool = false
    private var screenLocked: Bool = false
    private var menuBarHidden: Bool = false
    
    static func main() {
        let launchStart = Date()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.launchStart = launchStart
        app.delegate = delegate
        app.run()
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let startingPoint = self.launchStart ?? Date()
        
        self.parseArguments()
        self.parseVersion()
        SMCHelper.shared.checkForUpdate()
        self.setup {
            modules.reversed().forEach{ $0.mount() }
            self.showSettingsIfNoActiveWidgets()
        }
        self.defaultValues()
        self.icon()
        
        NotificationCenter.default.addObserver(self, selector: #selector(listenForAppPause), name: .pause, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleToggleSettings), name: .toggleSettings, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleRemoteAuthenticated), name: .remoteAuthenticated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleRemoteUpdate), name: .remoteUpdate, object: nil)

        // Pause polling while nothing is visible (display asleep / screen locked) to save energy.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(self, selector: #selector(self.screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(self.screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        let distributedCenter = DistributedNotificationCenter.default()
        distributedCenter.addObserver(self, selector: #selector(self.screenDidLock), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        distributedCenter.addObserver(self, selector: #selector(self.screenDidUnlock), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        // Fullscreen apps auto-hide the menu bar; our status-item windows then lose the
        // .visible occlusion flag, so pause too when no menu-bar item is on screen.
        NotificationCenter.default.addObserver(self, selector: #selector(self.menuBarOcclusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
        
        info("Stats started in \((startingPoint.timeIntervalSinceNow * -1).rounded(toPlaces: 4)) seconds")
        self.startTS = Date()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        modules.forEach{ $0.terminate() }
        SystemStats.shared.terminate()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - pause readers while nothing is visible

    @objc private func screensDidSleep() {
        self.displayAsleep = true
        self.updateModulesSleep()
    }
    @objc private func screensDidWake() {
        self.displayAsleep = false
        self.updateModulesSleep()
    }
    @objc private func screenDidLock() {
        self.screenLocked = true
        self.updateModulesSleep()
    }
    @objc private func screenDidUnlock() {
        self.screenLocked = false
        self.updateModulesSleep()
    }
    @objc private func menuBarOcclusionChanged() {
        // Re-evaluate from our own status-item windows. Fail safe: if none are found,
        // treat the menu bar as visible so widgets never freeze when we cannot tell.
        let statusWindows = NSApp.windows.filter { $0.className == "NSStatusBarWindow" }
        self.menuBarHidden = !statusWindows.isEmpty && !statusWindows.contains { $0.occlusionState.contains(.visible) }
        self.updateModulesSleep()
    }
    private func updateModulesSleep() {
        let shouldSleep = self.displayAsleep || self.screenLocked || self.menuBarHidden
        modules.forEach { $0.setReadersSleep(shouldSleep) }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if self.clickInNotification {
            self.clickInNotification = false
            return true
        }
        guard let startTS = self.startTS, Date().timeIntervalSince(startTS) > 2 else { return false }
        
        let window = self.ensureSettingsWindow()
        if flag {
            window.makeKeyAndOrderFront(self)
        } else {
            window.setIsVisible(true)
        }
        
        return true
    }
    
    @objc private func handleToggleSettings(_ notification: Notification) {
        let module = notification.userInfo?["module"] as? String
        self.ensureSettingsWindow().open(module: module)
    }
    
    @objc private func handleRemoteAuthenticated() {
        DispatchQueue.main.async {
            self.checkIfShouldShowSupportWindow()
        }
    }
    
    @objc private func handleRemoteUpdate() {
        DispatchQueue.main.async {
            self.checkForNewVersion(silent: true)
        }
    }
    
    private func showSettingsIfNoActiveWidgets() {
        if self.pauseState { return }
        let hasActive = modules.contains(where: { $0.enabled != false && $0.available != false && !$0.menuBar.widgets.filter({ $0.isActive }).isEmpty })
        if hasActive { return }
        self.ensureSettingsWindow().setIsVisible(true)
    }
    
    internal func ensureSettingsWindow() -> SettingsWindow {
        if let w = self.settingsWindow { return w }
        let w = SettingsWindow()
        w.onClose = { [weak self] in self?.settingsWindow = nil }
        self.settingsWindow = w
        return w
    }
    
    internal func ensureUpdateWindow() -> UpdateWindow {
        if let w = self.updateWindow { return w }
        let w = UpdateWindow()
        w.onClose = { [weak self] in self?.updateWindow = nil }
        self.updateWindow = w
        return w
    }
    
    internal func ensureSetupWindow() -> SetupWindow {
        if let w = self.setupWindow { return w }
        let w = SetupWindow()
        w.onClose = { [weak self] in self?.setupWindow = nil }
        self.setupWindow = w
        return w
    }
    
    internal func ensureSupportWindow() -> SupportWindow {
        if let w = self.supportWindow { return w }
        let w = SupportWindow()
        w.onClose = { [weak self] in self?.supportWindow = nil }
        self.supportWindow = w
        return w
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        self.clickInNotification = true
        
        if let uri = response.notification.request.content.userInfo["url"] as? String {
            debug("Downloading new version of app...")
            if let url = URL(string: uri) {
                updater.download(url, completion: { path in
                    updater.install(path: path) { error in
                        if let error {
                            showAlert("Error update Stats", error, .critical)
                        }
                    }
                })
            }
        }
        
        completionHandler()
    }
}
