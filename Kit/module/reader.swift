//
//  reader.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 10/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

public protocol Reader_p {
    var popup: Bool { get }
    var preview: Bool { get }
    var sleep: Bool { get }
    
    func setup()
    func read()
    func terminate()
    
    func start()
    func pause()
    func stop()
    
    func lock()
    func unlock()
    
    func initStoreValues(title: String)
    func setInterval(_ value: Int)
    func sleepMode(state: Bool)
}

public protocol ReaderInternal_p {
    associatedtype T
    
    var value: T? { get }
    func read()
}

open class Reader<T: Codable>: NSObject, ReaderInternal_p {
    public var log: NextLog {
        NextLog.shared.copy(category: "\(String(describing: self))")
    }
    private let stateLock = NSLock()
    private var _value: T?
    public var value: T? {
        get { self.stateLock.lock(); defer { self.stateLock.unlock() }; return self._value }
        set { self.stateLock.lock(); self._value = newValue; self.stateLock.unlock() }
    }
    public var name: String {
        String(NSStringFromClass(type(of: self)).split(separator: ".").last ?? "unknown")
    }
    
    public var interval: Double? = nil
    public var defaultInterval: Int = 1
    public var popup: Bool = false
    public var preview: Bool = false
    public var sleep: Bool = false
    
    public var alignToSecondBoundary: Bool = false
    public var alignOffset: TimeInterval = 0
    
    public var callbackHandler: (T?) -> Void
    
    private let module: ModuleType
    private var history: Bool
    // Reader identity is fixed for its lifetime; build the DB/key string once instead of
    // re-interpolating NSStringFromClass(...) on every tick in callback().
    private lazy var moduleKey: String = "\(self.module.stringValue)@\(self.name)"
    private var repeatTask: Repeater?
    private var locked: Bool = true
    private var initlizalized: Bool = false
    
    private var _active: Bool = false
    public var active: Bool {
        get { self.stateLock.lock(); defer { self.stateLock.unlock() }; return self._active }
        set { self.stateLock.lock(); self._active = newValue; self.stateLock.unlock() }
    }
    
    private var lastDBWrite: Date? = nil

    private var alignGeneration: UInt = 0
    private let alignQueue = DispatchQueue(label: "eu.exelban.readerAlignQueue")

    private let readLock = NSLock()
    private var reading: Bool = false
    
    public init(_ module: ModuleType, popup: Bool = false, preview: Bool = false, history: Bool = false, callback: @escaping (T?) -> Void = {_ in }) {
        self.popup = popup
        self.preview = preview
        self.module = module
        self.history = history
        self.callbackHandler = callback
        
        super.init()
        DB.shared.setup(T.self, self.moduleKey)
        if let lastValue = DB.shared.findOne(T.self, key: self.moduleKey) {
            self.value = lastValue
            callback(lastValue)
        }
        self.setup()
        
        debug("Successfully initialize reader", log: self.log)
    }
    
    deinit {
        DB.shared.insert(key: self.moduleKey, value: self.value, ts: self.history)
    }
    
    public func initStoreValues(title: String) {
        guard self.interval == nil else { return }
        let updateInterval = Store.shared.int(key: "\(title)_updateInterval", defaultValue: self.defaultInterval)
        self.interval = Double(updateInterval)
    }
    
    public func callback(_ value: T?) {
        let moduleKey = self.moduleKey
        self.value = value
        if let value {
            self.callbackHandler(value)
            SystemStats.shared.send(key: moduleKey, value: value)
            if let ts = self.lastDBWrite, let interval = self.interval, Date().timeIntervalSince(ts) > interval * 10 {
                DB.shared.insert(key: moduleKey, value: value, ts: self.history)
                self.lastDBWrite = Date()
            } else if self.lastDBWrite == nil {
                DB.shared.insert(key: moduleKey, value: value, ts: self.history)
                self.lastDBWrite = Date()
            }
        }
    }
    
    open func read() {}
    open func setup() {}
    open func terminate() {}

    // read() is not reentrant: readers keep state between samples (previous values, buffers).
    // The repeater and the dispatches in start() fire on different queues, and a read() slower
    // than the interval overlaps the next tick, so drop a scheduled read while one is in flight.
    private func readIfIdle() {
        self.readLock.lock()
        if self.reading {
            self.readLock.unlock()
            return
        }
        self.reading = true
        self.readLock.unlock()

        defer {
            self.readLock.lock()
            self.reading = false
            self.readLock.unlock()
        }

        self.read()
    }

    open func start() {
        if (self.popup || self.preview) && self.locked {
            DispatchQueue.global(qos: .background).async {
                self.readIfIdle()
            }
            return
        }

        self.alignQueue.sync {
            if self.alignToSecondBoundary {
                if self.repeatTask == nil {
                    self.startAlignedRepeater()
                } else {
                    self.repeatTask?.start()
                }
            } else if !self.initlizalized {
                self.startNormalRepeater()
                DispatchQueue.global(qos: .background).async { self.readIfIdle() }
                self.repeatTask?.start()
                self.initlizalized = true
            } else {
                self.repeatTask?.start()
            }
        }

        self.active = true
    }
    
    open func pause() {
        self.alignQueue.sync {
            self.alignGeneration &+= 1
            self.repeatTask?.pause()
        }
        self.active = false
    }
    
    open func stop() {
        self.alignQueue.sync {
            self.alignGeneration &+= 1
            self.repeatTask?.pause()
            self.repeatTask = nil
            self.initlizalized = false
        }
        self.active = false
    }
    
    public func setInterval(_ value: Int) {
        debug("Set update interval: \(value) sec", log: self.log)
        self.interval = Double(value)
        
        self.alignQueue.sync {
            if self.alignToSecondBoundary {
                self.alignGeneration &+= 1
                self.repeatTask?.pause()
                self.repeatTask = nil
                if self.active {
                    self.startAlignedRepeater()
                }
            } else {
                self.repeatTask?.reset(seconds: value, restart: self.active)
            }
        }
    }
    
    public func save(_ value: T) {
        DB.shared.insert(key: self.moduleKey, value: value, ts: self.history, force: true)
    }
    
    private func delayToNextSecondBoundary() -> TimeInterval {
        let now = Date().addingTimeInterval(self.alignOffset)
        let fractional = now.timeIntervalSince1970.truncatingRemainder(dividingBy: 1.0)
        let baseDelay = (fractional == 0) ? 0.0 : (1.0 - fractional)
        let safety: TimeInterval = 0.005 // 5ms past the boundary
        return baseDelay + safety
    }
    
    private func startNormalRepeater() {
        guard let interval = self.interval, self.repeatTask == nil else { return }
        
        if !self.popup && !self.preview {
            debug("Set up update interval: \(Int(interval)) sec", log: self.log)
        }
        
        self.repeatTask = Repeater(seconds: Int(interval)) { [weak self] in
            self?.readIfIdle()
        }
    }

    private func startAlignedRepeater() {
        guard let interval = self.interval, self.repeatTask == nil else { return }
        
        if !self.popup && !self.preview {
            debug("Set up update interval: \(Int(interval)) sec (aligned)", log: self.log)
        }
        
        self.alignGeneration &+= 1
        let generation = self.alignGeneration
        self.alignQueue.asyncAfter(deadline: .now() + self.delayToNextSecondBoundary()) { [weak self] in
            guard let self, self.alignGeneration == generation, self.repeatTask == nil else { return }

            DispatchQueue.global(qos: .background).async { self.readIfIdle() }
            self.repeatTask = Repeater(seconds: Int(interval)) { [weak self] in
                self?.readIfIdle()
            }
            self.repeatTask?.start()
        }
    }
    
    public func sleepMode(state: Bool) {
        guard state != self.sleep else { return }

        debug("Sleep mode: \(state ? "on" : "off")", log: self.log)
        self.sleep = state

        if state {
            self.pause()
        } else {
            self.start()
        }
    }
}

extension Reader: Reader_p {
    public func lock() {
        self.locked = true
    }
    
    public func unlock() {
        self.locked = false
    }
}
