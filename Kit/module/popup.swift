//
//  popup.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 11/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

public final class PopupCache<T> {
    public var value: T?
    public var initialized: Bool = false
    
    public init() {}
    
    public func apply(_ value: T, visible: Bool, render: (T) -> Void) {
        self.value = value
        if visible || !self.initialized {
            render(value)
            self.initialized = true
        }
    }
    
    public func replay(render: (T) -> Void) {
        if let v = self.value { render(v) }
    }
}

public protocol Popup_p: NSView {
    var keyboardShortcut: [UInt16] { get }
    var sizeCallback: ((NSSize) -> Void)? { get set }
    
    func settings() -> NSView?
    
    func appear()
    func disappear()
    func setKeyboardShortcut(_ binding: [UInt16])
}

open class PopupWrapper: NSStackView, Popup_p {
    public var title: String
    public var keyboardShortcut: [UInt16] = []
    open var sizeCallback: ((NSSize) -> Void)? = nil

    // Two-column layout state; unused by popups that stay single-column.
    private var columnLeft: NSStackView? = nil
    private var columnRight: NSStackView? = nil
    private var sections: [NSView] = []
    private var stretchHandlers: [ObjectIdentifier: (CGFloat) -> Void] = [:]
    private var appliedStretch: [ObjectIdentifier: CGFloat] = [:]
    /// Ceiling on how far a single section may be inflated to close the gap. Deliberately small: a
    /// chart only fills the fraction of its box that the value calls for, so a graph stretched much
    /// past its natural size is just grey emptiness with a trace along the bottom — worse-looking
    /// than the gap it was closing. Anything above this stays as a strip at the bottom instead.
    private let maxStretch: CGFloat = 60

    public init(_ typ: ModuleType, frame: NSRect) {
        self.title = typ.stringValue
        self.keyboardShortcut = Store.shared.array(key: "\(typ.stringValue)_popup_keyboardShortcut", defaultValue: []) as? [UInt16] ?? []
        
        super.init(frame: frame)
    }
    
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    open func settings() -> NSView? { return nil }
    open func appear() {}
    open func disappear() {}
    
    open func setKeyboardShortcut(_ binding: [UInt16]) {
        self.keyboardShortcut = binding
        Store.shared.set(key: "\(self.title)_popup_keyboardShortcut", value: binding)
        NotificationCenter.default.post(name: .keyboardShortcutChanged, object: nil)
    }
    
    public func apply<T>(_ value: T, to cache: PopupCache<T>, render: @escaping (T) -> Void) {
        DispatchQueue.main.async {
            cache.apply(value, visible: self.window?.isVisible ?? false, render: render)
        }
    }
    
    public func replay<T>(_ cache: PopupCache<T>, render: (T) -> Void) {
        cache.replay(render: render)
    }

    // MARK: - balanced two-column layout

    /// Turn the popup into two side-by-side columns of the standard 264pt width. Sections are
    /// registered separately with `setSections`; single-column popups never call this.
    public func makeTwoColumns() {
        self.orientation = .horizontal
        self.distribution = .fillEqually
        self.alignment = .top
        self.spacing = Constants.Popup.margins

        let left = NSStackView(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))
        let right = NSStackView(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))
        for col in [left, right] {
            col.orientation = .vertical
            col.spacing = 0
            col.alignment = .width
        }
        self.columnLeft = left
        self.columnRight = right
        self.addArrangedSubview(left)
        self.addArrangedSubview(right)
        self.setFrameSize(NSSize(width: Constants.Popup.width*2 + self.spacing, height: 0))
    }

    /// Register the sections in canonical top-to-bottom reading order. Which column each one ends
    /// up in is decided by `layoutColumns`, not here.
    public func setSections(_ views: [NSView]) {
        self.sections = views
    }

    /// Both of these drop any existing registration of the view first, so a section that is toggled
    /// off and back on cannot end up in the list twice.
    public func insertSection(_ view: NSView, at index: Int) {
        self.sections.removeAll(where: { $0 === view })
        self.sections.insert(view, at: max(0, min(index, self.sections.count)))
    }

    public func appendSection(_ view: NSView) {
        self.sections.removeAll(where: { $0 === view })
        self.sections.append(view)
    }

    /// Position of a registered section in canonical order, or nil if it is not registered. Lets a
    /// module place a new section relative to an existing one instead of at a hardcoded index.
    public func sectionIndex(of view: NSView) -> Int? {
        self.sections.firstIndex(where: { $0 === view })
    }

    public func removeSection(_ view: NSView) {
        self.sections.removeAll(where: { $0 === view })
        self.stretchHandlers.removeValue(forKey: ObjectIdentifier(view))
        self.appliedStretch.removeValue(forKey: ObjectIdentifier(view))
    }

    /// Mark a section as able to soak up leftover height. The handler receives the absolute number
    /// of extra points to add on top of the section's natural height (0 resets it), so it can be
    /// called repeatedly without accumulating.
    public func setStretchable(_ view: NSView, _ handler: @escaping (CGFloat) -> Void) {
        self.stretchHandlers[ObjectIdentifier(view)] = handler
    }

    /// Deal the registered sections into the two columns and resize the popup.
    ///
    /// The canonical order is preserved — the first N sections go left, the rest go right — and the
    /// cut is picked to leave as little empty space as possible. Up to `maxStretch` of the height
    /// difference is handed to a stretchable section in the shorter column; whatever the cap or the
    /// absence of a stretchable section leaves over lands as a strip along the bottom of the
    /// shorter column, rather than a hole carved out of one side.
    public func layoutColumns() {
        guard let left = self.columnLeft, let right = self.columnRight, self.sections.count > 1 else { return }

        let heights = self.sections.map { self.naturalHeight($0) }
        let total = heights.reduce(0, +)

        var bestCut: Int = 1
        var bestStretch: CGFloat = 0
        var bestCost: CGFloat = .greatestFiniteMagnitude
        for cut in 1..<self.sections.count {
            let leftH = heights[0..<cut].reduce(0, +)
            let gap = abs(leftH - (total - leftH))
            let shorter = leftH < (total - leftH) ? 0..<cut : cut..<self.sections.count
            let canStretch = shorter.contains(where: {
                self.stretchHandlers[ObjectIdentifier(self.sections[$0])] != nil
            })
            // Absorb what the cap allows and score the cut by what is still left over, so a cut
            // that lands nearly balanced on its own beats one that only looks flush because a
            // section was blown out of shape to get there.
            let stretch = canStretch ? min(gap, self.maxStretch) : 0
            let cost = gap - stretch
            if cost < bestCost {
                bestCost = cost
                bestCut = cut
                bestStretch = stretch
            }
        }

        // Undo previous stretching before re-applying: `heights` above is already net of it.
        self.sections.forEach { v in
            let id = ObjectIdentifier(v)
            guard let applied = self.appliedStretch[id], applied != 0 else { return }
            self.stretchHandlers[id]?(0)
            self.appliedStretch[id] = 0
        }

        self.fill(left, with: Array(self.sections[0..<bestCut]))
        self.fill(right, with: Array(self.sections[bestCut...]))

        let leftH = heights[0..<bestCut].reduce(0, +)
        if bestStretch > 0 {
            let shorter = leftH < (total - leftH) ? 0..<bestCut : bestCut..<self.sections.count
            if let v = self.sections[shorter].first(where: { self.stretchHandlers[ObjectIdentifier($0)] != nil }) {
                self.stretchHandlers[ObjectIdentifier(v)]?(bestStretch)
                self.appliedStretch[ObjectIdentifier(v)] = bestStretch
            }
        }

        let h = max(leftH, total - leftH)
        let w = Constants.Popup.width*2 + self.spacing
        if self.frame.size.height != h || self.frame.size.width != w {
            self.setFrameSize(NSSize(width: w, height: h))
            self.sizeCallback?(self.frame.size)
        }
    }

    private func fill(_ column: NSStackView, with views: [NSView]) {
        guard column.arrangedSubviews != views else { return }
        column.arrangedSubviews.forEach {
            column.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        views.forEach { column.addArrangedSubview($0) }
    }

    /// Height the section would have with no stretching applied. Sections built as a stack measure
    /// by their arranged subviews; the rest report their own bounds.
    private func naturalHeight(_ view: NSView) -> CGFloat {
        var h: CGFloat = 0
        if let stack = view as? NSStackView {
            h = stack.arrangedSubviews.map({ $0.bounds.height + stack.spacing }).reduce(0, +)
        } else {
            h = view.bounds.height
        }
        return h - (self.appliedStretch[ObjectIdentifier(view)] ?? 0)
    }
}

public class PopupWindow: NSWindow, NSWindowDelegate {
    private let viewController: PopupViewController
    internal var locked: Bool = false
    internal var openedBy: widget_t? = nil
    
    public init(title: String, module: ModuleType, view: Popup_p?, visibilityCallback: @escaping (_ state: Bool) -> Void) {
        self.viewController = PopupViewController(module: module)
        self.viewController.setup(title: title, view: view)
        
        super.init(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: self.viewController.view.frame.width,
                height: self.viewController.view.frame.height
            ),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        
        self.viewController.visibilityCallback = { [weak self] state in
            self?.locked = false
            visibilityCallback(state)
        }
        
        self.title = title
        self.titleVisibility = .hidden
        self.contentViewController = self.viewController
        self.titlebarAppearsTransparent = true
        self.animationBehavior = .default
        self.collectionBehavior = .moveToActiveSpace
        self.backgroundColor = .clear
        self.hasShadow = true
        self.setIsVisible(false)
        self.delegate = self
    }
    
    public func windowWillMove(_ notification: Notification) {
        self.viewController.setCloseButton(true)
        self.locked = true
    }
    
    public func windowDidResignKey(_ notification: Notification) {
        if self.locked {
            return
        }
        
        self.viewController.setCloseButton(false)
        self.setIsVisible(false)
    }
}

internal class PopupViewController: NSViewController {
    fileprivate var visibilityCallback: (_ state: Bool) -> Void = {_ in }
    private var popup: PopupView
    
    public init(module: ModuleType) {
        self.popup = PopupView(frame: NSRect(
            x: 0,
            y: 0,
            width: Constants.Popup.width + (Constants.Popup.margins * 2),
            height: Constants.Popup.height+Constants.Popup.headerHeight
        ), module: module)
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func loadView() {
        self.view = self.popup
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        
        self.popup.appear()
        self.visibilityCallback(true)
    }
    
    override func viewWillDisappear() {
        super.viewWillDisappear()
        
        self.popup.disappear()
        self.visibilityCallback(false)
    }
    
    fileprivate func setup(title: String, view: Popup_p?) {
        self.title = title
        self.popup.setTitle(title)
        self.popup.setView(view)
    }
    
    fileprivate func setCloseButton(_ state: Bool) {
        self.popup.setCloseButton(state)
    }
}

internal class PopupView: NSView {
    private var view: Popup_p? = nil
    
    private var foreground: NSVisualEffectView
    private var background: NSView
    
    private let header: HeaderView
    private let body: NSScrollView
    
    override var intrinsicContentSize: CGSize {
        return CGSize(width: self.frame.width, height: self.frame.height)
    }
    private var windowHeight: CGFloat?
    private var containerHeight: CGFloat?
    
    init(frame: NSRect, module: ModuleType) {
        self.header = HeaderView(frame: NSRect(
            x: 0,
            y: frame.height - Constants.Popup.headerHeight,
            width: frame.width,
            height: Constants.Popup.headerHeight
        ), module: module)
        self.body = NSScrollView(frame: NSRect(
            x: Constants.Popup.margins,
            y: Constants.Popup.margins,
            width: frame.width - Constants.Popup.margins*2,
            height: frame.height - self.header.frame.height - Constants.Popup.margins*2
        ))
        self.windowHeight = NSScreen.main?.visibleFrame.height
        self.containerHeight = self.body.documentView?.frame.height
        
        self.foreground = NSVisualEffectView(frame: frame)
        self.foreground.material = .titlebar
        self.foreground.blendingMode = .behindWindow
        self.foreground.state = .active
        self.foreground.wantsLayer = true
        self.foreground.layer?.backgroundColor = NSColor.red.cgColor
        self.foreground.layer?.cornerRadius = 6
        
        self.background = NSView(frame: frame)
        self.background.wantsLayer = true
        self.foreground.addSubview(self.background)
        
        super.init(frame: frame)
        
        self.body.drawsBackground = false
        self.body.translatesAutoresizingMaskIntoConstraints = true
        self.body.borderType = .noBorder
        self.body.hasVerticalScroller = true
        self.body.hasHorizontalScroller = false
        self.body.autohidesScrollers = true
        self.body.horizontalScrollElasticity = .none
        
        self.addSubview(self.foreground, positioned: .below, relativeTo: .none)
        self.addSubview(self.header)
        self.addSubview(self.body)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func updateLayer() {
        self.background.layer?.backgroundColor = self.isDarkMode ? .clear : NSColor.white.cgColor
    }
    
    fileprivate func setView(_ view: Popup_p?) {
        self.view = view
        
        var isScrollVisible: Bool = false
        var size: NSSize = NSSize(
            width: (view?.frame.width ?? Constants.Popup.width) + (Constants.Popup.margins*2),
            height: (view?.frame.height ?? 0) + Constants.Popup.headerHeight + (Constants.Popup.margins*2)
        )
        
        self.windowHeight = NSScreen.main?.visibleFrame.height // for height recalculate when appear/disappear
        self.containerHeight = self.body.documentView?.frame.height // for scroll diff calculation
        if let screenHeight = NSScreen.main?.visibleFrame.height, size.height > screenHeight {
            size.height = screenHeight - Constants.Widget.height
            isScrollVisible = true
        }
        if let screenWidth = NSScreen.main?.visibleFrame.width, size.width > screenWidth {
            size.width = screenWidth
        }
        
        self.setFrameSize(size)
        self.foreground.setFrameSize(size)
        self.background.setFrameSize(size)
        self.resizeBody(size, scrollVisible: isScrollVisible)
        // The header is built once at the module's initial width; without this it keeps that width
        // forever and a wider popup gets a half-empty header band with the title off to one side.
        self.header.setFrameSize(NSSize(width: size.width, height: Constants.Popup.headerHeight))
        self.header.setFrameOrigin(NSPoint(x: 0, y: size.height - Constants.Popup.headerHeight))
        
        if let view = view {
            self.body.documentView = view
            view.sizeCallback = { [weak self] size in
                self?.recalculateHeight(size)
            }
        }
    }
    
    fileprivate func setTitle(_ newTitle: String) {
        self.header.setTitle(newTitle)
    }
    
    fileprivate func setCloseButton(_ state: Bool) {
        self.header.setCloseButton(state)
    }
    
    internal func appear() {
        self.view?.appear()
        
        self.display()
        self.body.subviews.first?.display()
        
        if let screenHeight = NSScreen.main?.visibleFrame.height, let size = self.body.documentView?.frame.size {
            if screenHeight != self.windowHeight {
                self.recalculateHeight(size)
            }
        }
        
        if let documentView = self.body.documentView {
            documentView.scroll(NSPoint(x: 0, y: documentView.bounds.size.height))
        }
    }
    internal func disappear() {
        self.header.setCloseButton(false)
        self.view?.disappear()
    }
    
    private func recalculateHeight(_ size: NSSize) {
        var isScrollVisible: Bool = false
        var windowSize: NSSize = NSSize(
            width: size.width + (Constants.Popup.margins*2),
            height: size.height + Constants.Popup.headerHeight + (Constants.Popup.margins*2)
        )
        let h0 = self.containerHeight ?? 0
        
        self.windowHeight = NSScreen.main?.visibleFrame.height // for height recalculate when appear/disappear
        self.containerHeight = self.body.documentView?.frame.height // for scroll diff calculation
        if let screenHeight = NSScreen.main?.visibleFrame.height, windowSize.height > screenHeight {
            windowSize.height = screenHeight - Constants.Widget.height
            isScrollVisible = true
        }
        if let screenWidth = NSScreen.main?.visibleFrame.width, windowSize.width > screenWidth {
            windowSize.width = screenWidth
        }
        
        self.window?.setContentSize(windowSize)
        self.foreground.setFrameSize(windowSize)
        self.background.setFrameSize(windowSize)
        self.resizeBody(windowSize, scrollVisible: isScrollVisible)
        self.header.setFrameSize(NSSize(width: windowSize.width, height: Constants.Popup.headerHeight))
        self.header.setFrameOrigin(NSPoint(
            x: self.header.frame.origin.x,
            y: self.body.frame.height + (Constants.Popup.margins*2)
        ))
        
        if let documentView = self.body.documentView {
            let diff = h0 - (self.body.documentView?.frame.height ?? 0)
            documentView.scroll(NSPoint(
                x: 0,
                y: self.body.documentVisibleRect.origin.y - (diff < 0 ? diff : 0)
            ))
        }
    }
    
    private func resizeBody(_ windowSize: NSSize, scrollVisible: Bool) {
        let offset: CGFloat = scrollVisible ? 20 : 0
        let isRTL = self.body.userInterfaceLayoutDirection == .rightToLeft
        self.body.frame = NSRect(
            x: Constants.Popup.margins - (isRTL ? offset : 0),
            y: Constants.Popup.margins,
            width: windowSize.width - (Constants.Popup.margins*2) + offset,
            height: windowSize.height - Constants.Popup.headerHeight - (Constants.Popup.margins*2)
        )
    }
}

internal class HeaderView: NSStackView {
    private var titleView: NSTextField? = nil
    private var activityButton: NSButton?
    /// Kept so the title can re-span the header when the popup is wider than the width this view
    /// was built at (two-column popups).
    private var titleWidth: NSLayoutConstraint? = nil
    private var buttonsWidth: CGFloat = 0

    private var title: String = ""
    private var isCloseAction: Bool = false
    private let activityMonitor: URL?
    private let calendar: URL?
    private var module: ModuleType
    
    init(frame: NSRect, module: ModuleType) {
        self.module = module
        self.activityMonitor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor")
        self.calendar = URL(fileURLWithPath: "/System/Applications/Calendar.app")
        
        super.init(frame: CGRect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height))
        
        self.orientation = .horizontal
        self.distribution = .gravityAreas
        self.spacing = 0
        
        let activity = NSButtonWithPadding()
        activity.frame = CGRect(x: 0, y: 0, width: 24, height: self.frame.height)
        // Was derived from the header height; pinned so slimming the band does not shove the two
        // corner icons out to the very edges.
        activity.horizontalPadding = 18
        activity.bezelStyle = .regularSquare
        activity.translatesAutoresizingMaskIntoConstraints = false
        activity.imageScaling = .scaleNone
        activity.contentTintColor = .lightGray
        activity.isBordered = false
        activity.target = self
        activity.focusRingType = .none
        self.activityButton = activity
        self.setupActionButton()
        
        let title = NSTextField(frame: NSRect(x: 0, y: 0, width: frame.width/2, height: 18))
        title.isEditable = false
        title.isSelectable = false
        title.isBezeled = false
        title.wantsLayer = true
        title.textColor = .textColor
        title.backgroundColor = .clear
        title.canDrawSubviewsIntoLayer = true
        title.alignment = .center
        title.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        title.stringValue = ""
        self.titleView = title
        
        let settings = NSButtonWithPadding()
        settings.frame = CGRect(x: 0, y: 0, width: 24, height: self.frame.height)
        settings.horizontalPadding = 18
        settings.bezelStyle = .regularSquare
        settings.translatesAutoresizingMaskIntoConstraints = false
        settings.imageScaling = .scaleNone
        settings.image = iconFromSymbol(name: "command", scale: .large)
        settings.contentTintColor = .lightGray
        settings.isBordered = false
        settings.action = #selector(self.openSettings)
        settings.target = self
        settings.toolTip = localizedString("Open module")
        settings.focusRingType = .none
        
        self.addArrangedSubview(activity)
        self.addArrangedSubview(title)
        self.addArrangedSubview(settings)
        
        self.buttonsWidth = activity.intrinsicContentSize.width + settings.intrinsicContentSize.width
        let titleWidth = title.widthAnchor.constraint(equalToConstant: self.frame.width - self.buttonsWidth)
        self.titleWidth = titleWidth
        NSLayoutConstraint.activate([titleWidth])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Title takes whatever the two side buttons leave, so it stays centred on the popup.
        self.titleWidth?.constant = max(0, newSize.width - self.buttonsWidth)
    }

    fileprivate func setTitle(_ newTitle: String) {
        self.title = newTitle
        self.titleView?.stringValue = localizedString(newTitle)
    }
    
    private func setupActionButton() {
        guard let button = self.activityButton else { return }
        
        if self.isCloseAction {
            button.action = #selector(self.closePopup)
            button.image = iconFromSymbol(name: "xmark.circle.fill", scale: .xlarge)
            button.toolTip = localizedString("Close")
            return
        }
        
        if self.module == .clock {
            button.action = #selector(self.openCalendar)
            button.image = iconFromSymbol(name: "calendar", scale: .large)
            button.toolTip = localizedString("Open Calendar")
            return
        } else if self.module == .remote {
            button.action = #selector(self.openSystemStats)
            button.image = iconFromSymbol(name: "globe", scale: .large)
            button.toolTip = localizedString("Open System Stats")
            return
        }
        
        button.action = #selector(self.openActivityMonitor)
        button.image = iconFromSymbol(name: "chart.bar.fill", scale: .medium)
        button.toolTip = localizedString("Open Activity Monitor")
    }
    
    @objc func openActivityMonitor() {
        guard let app = self.activityMonitor else { return }
        if let tab = self.module.activityMonitorTab {
            UserDefaults(suiteName: "com.apple.ActivityMonitor")?.set(tab, forKey: "SelectedTab")
        }
        NSWorkspace.shared.open([], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    
    @objc func openCalendar() {
        guard let app = self.calendar else { return }
        NSWorkspace.shared.open([], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    
    @objc func openSystemStats() {
        guard let url = URL(string: "https://app.system-stats.com") else { return }
        NSWorkspace.shared.open(url)
    }
    
    @objc func openSettings() {
        NotificationCenter.default.post(name: .toggleSettings, object: nil, userInfo: ["module": self.title])
    }
    
    @objc private func closePopup() {
        self.window?.setIsVisible(false)
        self.setCloseButton(false)
        return
    }
    
    fileprivate func setCloseButton(_ state: Bool) {
        guard state != self.isCloseAction else { return }
        self.isCloseAction = state
        self.setupActionButton()
    }
}
