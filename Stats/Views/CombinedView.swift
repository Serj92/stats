//
//  CombinedView.swift
//  Stats
//
//  Created by Serhiy Mytrovtsiy on 09/01/2023
//  Using Swift 5.0
//  Running on macOS 13.1
//
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class CombinedView: NSObject, NSGestureRecognizerDelegate {
    private var menuBarItem: NSStatusItem? = nil
    private var view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: Constants.Widget.height))
    private var popup: PopupWindow? = nil
    
    private var status: Bool {
        Store.shared.bool(key: "CombinedModules", defaultValue: false)
    }
    private var spacing: CGFloat {
        CGFloat(Int(Store.shared.string(key: "CombinedModules_spacing", defaultValue: "")) ?? 0)
    }
    private var separator: Bool {
        Store.shared.bool(key: "CombinedModules_separator", defaultValue: false)
    }
    
    private var activeModules: [Module] {
        modules.filter({ $0.enabled }).sorted(by: { $0.combinedPosition < $1.combinedPosition })
    }
    
    private var combinedModulesPopup: Bool {
        get { Store.shared.bool(key: "CombinedModules_popup", defaultValue: true) }
        set { Store.shared.set(key: "CombinedModules_popup", value: newValue) }
    }
    
    override init() {
        super.init()
        
        modules.forEach { (m: Module) in
            m.menuBar.callback = { [weak self] in
                if let s = self?.status, s {
                    DispatchQueue.main.async(execute: {
                        self?.recalculate()
                    })
                }
            }
        }
        
        self.popup = PopupWindow(title: "Combined modules", module: .combined, view: Popup()) { _ in }
        
        if self.status {
            self.enable()
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(listenForOneView), name: .toggleOneView, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenForModuleRearrrange), name: .moduleRearrange, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: .toggleOneView, object: nil)
        NotificationCenter.default.removeObserver(self, name: .moduleRearrange, object: nil)
    }
    
    public func enable() {
        self.menuBarItem = NSStatusBar.system.statusItem(withLength: 0)
        DispatchQueue.main.async(execute: {
            self.menuBarItem?.autosaveName = "CombinedModules"
        })
        self.menuBarItem?.button?.addSubview(self.view)
        self.menuBarItem?.button?.image = NSImage()
        self.menuBarItem?.button?.toolTip = localizedString("Combined modules")
        
        self.menuBarItem?.button?.target = self
        self.menuBarItem?.button?.action = #selector(self.handleClick)
        self.menuBarItem?.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        
        DispatchQueue.main.async(execute: {
            self.recalculate()
        })
    }
    
    public func disable() {
        if let item = self.menuBarItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        self.menuBarItem = nil
    }
    
    private func recalculate() {
        self.view.subviews.forEach({ $0.removeFromSuperview() })
        
        let visibleModules = self.activeModules.filter({ !$0.menuBar.activeWidgets.isEmpty })
        var w: CGFloat = 0
        visibleModules.enumerated().forEach { (i, m) in
            if i != 0 {
                w += self.spacing
                if self.separator {
                    self.view.addSubview(SeparatorLineView(frame: NSRect(x: w, y: 3, width: 1, height: Constants.Widget.height-6)))
                    w += 3 + self.spacing
                }
            }
            self.view.addSubview(m.menuBar.view)
            m.menuBar.view.setFrameOrigin(NSPoint(x: w, y: 0))
            w += m.menuBar.view.frame.width
        }
        self.view.setFrameSize(NSSize(width: w, height: self.view.frame.height))
        self.menuBarItem?.length = w
    }
    
    // call when popup appear/disappear
    private func visibilityCallback(_ state: Bool) {}
    
    @objc private func handleClick() {
        if self.combinedModulesPopup {
            self.togglePopup()
        } else {
            self.openModulePopup()
        }
    }
    
    private func openModulePopup() {
        guard let window = self.menuBarItem?.button?.window else { return }
        let location = self.view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let visibleModules = self.activeModules.filter({ !$0.menuBar.activeWidgets.isEmpty })
        guard let module = visibleModules.last(where: { $0.menuBar.view.frame.minX <= location.x }) ?? visibleModules.first else { return }
        
        var userInfo: [String: Any] = [
            "module": module.name,
            "origin": window.frame.origin,
            "center": window.frame.width/2
        ]
        let widgetLocation = module.menuBar.view.convert(location, from: self.view)
        let widgets = module.menuBar.activeWidgets
        if let widget = widgets.last(where: { $0.item.frame.minX <= widgetLocation.x }) ?? widgets.first {
            userInfo["widget"] = widget.type
        }
        NotificationCenter.default.post(name: .togglePopup, object: nil, userInfo: userInfo)
    }
    
    private func togglePopup() {
        guard let popup = self.popup, let item = self.menuBarItem, let window = item.button?.window else { return }
        let openedWindows = NSApplication.shared.windows.filter{ $0 is NSPanel }
        openedWindows.forEach{ $0.setIsVisible(false) }
        
        if popup.occlusionState.rawValue == 8192 {
            NSApplication.shared.activate(ignoringOtherApps: true)
            
            popup.contentView?.invalidateIntrinsicContentSize()
            
            let windowCenter = popup.contentView!.intrinsicContentSize.width / 2
            var x = window.frame.origin.x - windowCenter + window.frame.width/2
            let y = window.frame.origin.y - popup.contentView!.intrinsicContentSize.height - 3
            
            let buttonPoint = NSPoint(x: window.frame.midX, y: window.frame.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(buttonPoint) }) ?? NSScreen.main {
                if x + popup.contentView!.intrinsicContentSize.width > screen.frame.maxX {
                    x = screen.frame.maxX - popup.contentView!.intrinsicContentSize.width - 3
                }
                if x < screen.frame.minX {
                    x = screen.frame.minX + 3
                }
            }
            
            popup.setFrameOrigin(NSPoint(x: x, y: y))
            popup.setIsVisible(true)
        } else {
            popup.setIsVisible(false)
        }
    }
    
    @objc private func listenForOneView(_ notification: Notification) {
        guard notification.userInfo?["module"] == nil else { return }
        
        if self.status {
            self.enable()
        } else {
            self.disable()
        }
    }
    
    @objc private func listenForModuleRearrrange() {
        self.recalculate()
    }
}

private class SeparatorLineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        (self.isDarkMode ? NSColor.white : NSColor.black).setFill()
        dirtyRect.fill()
    }
    
    override func viewDidChangeEffectiveAppearance() {
        self.needsDisplay = true
    }
}

private class Popup: NSStackView, Popup_p {
    fileprivate var keyboardShortcut: [UInt16] = []
    fileprivate var sizeCallback: ((NSSize) -> Void)? = nil

    // Combined details laid out as a grid instead of one tall single-column "sausage": module
    // portals keep their native 264pt width and are placed side by side, N per row. maxColumns
    // trades window width for height (2 → ~528pt wide, half as tall). Bump to 3 for a wider grid.
    private let maxColumns = 2

    // Standalone cards appended after the module portals — self-contained live widgets that aren't
    // a whole-module portal. First one: the fan-control card (boost toggles + live speed), which
    // otherwise lives only inside the CPU popup. Only shown when its daemon is installed.
    private lazy var extraCards: [NSView] = FanControlCard.isInstalled ? [FanControlCard()] : []
    
    init() {
        self.keyboardShortcut = Store.shared.array(key: "CombinedModules_popup_keyboardShortcut", defaultValue: []) as? [UInt16] ?? []
        
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))
        
        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .width
        self.spacing = Constants.Popup.spacing
        
        self.reinit()
        
        NotificationCenter.default.addObserver(self, selector: #selector(reinit), name: .toggleModule, object: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: .toggleOneView, object: nil)
    }
    
    fileprivate func settings() -> NSView? { return nil }
    fileprivate func appear() {}
    fileprivate func disappear() {}
    fileprivate func setKeyboardShortcut(_ binding: [UInt16]) {
        self.keyboardShortcut = binding
        Store.shared.set(key: "CombinedModules_popup_keyboardShortcut", value: binding)
    }
    
    @objc private func reinit() {
        self.subviews.forEach({ $0.removeFromSuperview() })

        let portals: [NSView] = modules.filter({ $0.enabled && $0.portal != nil }).compactMap({ $0.portal })
        let cells: [NSView] = portals + self.extraCards
        guard !cells.isEmpty else { return }

        let gap = Constants.Popup.spacing
        let cols = min(self.maxColumns, cells.count)
        let rowsCount = Int(ceil(Double(cells.count) / Double(cols)))

        // One horizontal row per grid line; .fillEqually splits the row into equal 264pt cells.
        // Short last rows get filler views so every cell stays a fixed 264pt (no stretching).
        for r in 0..<rowsCount {
            let row = NSStackView()
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = gap
            for c in 0..<cols {
                let i = r*cols + c
                row.addArrangedSubview(i < cells.count ? cells[i] : NSView())
            }
            self.addArrangedSubview(row)
        }

        let w = CGFloat(cols)*Constants.Popup.width + CGFloat(cols-1)*gap
        let h = CGFloat(rowsCount)*Constants.Popup.portalHeight + CGFloat(rowsCount-1)*self.spacing
        self.setFrameSize(NSSize(width: w, height: h))
        self.sizeCallback?(self.frame.size)
    }
}

// A self-contained fan-control card for the combined grid: the boost level toggles + a live
// "current speed" readout, styled like a module portal (264×120). Fully autonomous — reads/writes
// the fun-fan-control flag files directly and polls its status file on its own light timer while
// visible, so it needs no module reader. Mirrors the fan section of the CPU popup; the two write
// the same `boost` file and stay in sync. (Follow-up: de-dup the shared file logic between them.)
private class FanControlCard: NSStackView {
    static var fancurvedDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fancurved")
    }
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: FanControlCard.fancurvedDir.path)
    }
    private var boostURL: URL { FanControlCard.fancurvedDir.appendingPathComponent("boost") }
    private var statusURL: URL { FanControlCard.fancurvedDir.appendingPathComponent("status") }

    private let levels: [(level: Int, label: String)] = [
        (100, "Fan speed 100%"), (50, "Fan speed 50%"), (25, "Fan speed 25%")
    ]
    private var switches: [NSSwitch] = []
    private var statusField: ValueField? = nil
    private var timer: Timer? = nil

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: Constants.Popup.portalHeight))

        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.layer?.cornerRadius = 3
        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .width
        self.spacing = Constants.Popup.spacing
        self.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        self.heightAnchor.constraint(equalToConstant: Constants.Popup.portalHeight).isActive = true

        let header = LabelField(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 16), localizedString("Fans"))
        header.alignment = .center
        header.textColor = .textColor
        header.heightAnchor.constraint(equalToConstant: 16).isActive = true
        self.addArrangedSubview(header)

        for item in self.levels {
            let row = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 20))
            row.heightAnchor.constraint(equalToConstant: 20).isActive = true

            let label = LabelField(frame: NSRect(x: 2, y: (20-14)/2, width: row.frame.width - 60, height: 14), localizedString(item.label), size: 11)
            label.autoresizingMask = [.width]

            let sw = NSSwitch()
            sw.controlSize = .mini
            sw.tag = item.level
            sw.target = self
            sw.action = #selector(self.toggle)
            sw.sizeToFit()
            sw.frame = NSRect(x: row.frame.width - sw.frame.width - 2, y: (20-sw.frame.height)/2, width: sw.frame.width, height: sw.frame.height)
            sw.autoresizingMask = [.minXMargin]
            self.switches.append(sw)

            row.addSubview(label)
            row.addSubview(sw)
            self.addArrangedSubview(row)
        }

        let (_, value, _) = portalRow(self, title: localizedString("Current speed"), value: "—")
        self.statusField = value

        self.addArrangedSubview(NSView())  // trailing spacer pads content to the fixed 120pt height

        self.sync()
        self.timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.refresh()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { self.timer?.invalidate() }

    public override func updateLayer() {
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    private var currentLevel: Int? {
        guard let data = try? Data(contentsOf: self.boostURL) else { return nil }
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return 100 }
        return Int(raw)
    }

    private func syncSwitches() {
        let level = self.currentLevel
        for sw in self.switches { sw.state = sw.tag == level ? .on : .off }
    }

    // Read the daemon's status file (same format as the CPU popup): "<pct> <rpm0,rpm1,…> <driver>".
    private func refresh() {
        self.syncSwitches()
        guard let field = self.statusField else { return }
        guard let data = try? Data(contentsOf: self.statusURL),
              let mtime = try? self.statusURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              Date().timeIntervalSince(mtime) < 6 else {
            field.stringValue = "—"
            return
        }
        let parts = String(decoding: data, as: UTF8.self).split(separator: " ")
        guard parts.count >= 2, let pct = Int(parts[0]) else {
            field.stringValue = "—"
            return
        }
        let rpms = parts[1].split(separator: ",").compactMap { Int($0) }
        let rpmStr: String
        if rpms.isEmpty {
            rpmStr = ""
        } else if rpms.allSatisfy({ $0 == rpms[0] }) {
            rpmStr = "\(rpms[0])"
        } else {
            rpmStr = rpms.map(String.init).joined(separator: "/")
        }
        field.stringValue = rpmStr.isEmpty ? "\(pct)%" : "\(rpmStr) rpm · \(pct)%"
    }

    private func sync() { self.refresh() }

    @objc private func toggle(_ sender: NSSwitch) {
        let fm = FileManager.default
        if sender.state == .on {
            for sw in self.switches where sw !== sender { sw.state = .off }
            try? fm.createDirectory(at: FanControlCard.fancurvedDir, withIntermediateDirectories: true)
            try? Data("\(sender.tag)".utf8).write(to: self.boostURL)
        } else {
            try? fm.removeItem(at: self.boostURL)
        }
        self.refresh()
    }
}
