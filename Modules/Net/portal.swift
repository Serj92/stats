//
//  portal.swift
//  Net
//
//  Created by Serhiy Mytrovtsiy on 18/02/2023
//  Using Swift 5.0
//  Running on macOS 13.2
//
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

public class Portal: PortalWrapper {
    private var chart: NetworkChartView? = nil
    private var initialized: Bool = false
    
    private var publicIPField: NSTextField? = nil
    private var publicIPView: NSView? = nil
    private var localIPField: NSTextField? = nil
    private var localIPView: NSView? = nil
    
    // reverseOrderState is only read at load()
    private var reverseOrderState: Bool {
        Store.shared.bool(key: "\(self.name)_reverseOrder", defaultValue: false)
    }

    // cached from Store; refreshed via settingsUpdated() on settings change instead of re-read per tick
    private var base: DataSizeBase = .byte
    private var speedUnit: String = networkSpeedUnit(from: NetworkSpeedUnitAuto).key
    private var chartScale: Scale = .none
    private var chartFixedScale: Int = 12
    private var chartFixedScaleSize: SizeUnit = .MB
    private var publicIPState: Bool = true
    private var downloadColor: NSColor = NSColor.systemBlue
    private var uploadColor: NSColor = NSColor.systemRed

    private func loadSettings() {
        self.base = DataSizeBase(rawValue: Store.shared.string(key: "\(self.name)_base", defaultValue: "byte")) ?? .byte
        self.speedUnit = networkSpeedUnit(from: Store.shared.string(key: "\(self.name)_speedUnit", defaultValue: NetworkSpeedUnitAuto)).key
        self.chartScale = Scale.fromString(Store.shared.string(key: "\(self.name)_chartScale", defaultValue: Scale.none.key))
        self.chartFixedScale = Store.shared.int(key: "\(self.name)_chartFixedScale", defaultValue: 12)
        self.chartFixedScaleSize = SizeUnit.fromString(Store.shared.string(key: "\(self.name)_chartFixedScaleSize", defaultValue: SizeUnit.MB.key))
        self.publicIPState = Store.shared.bool(key: "\(self.name)_publicIP", defaultValue: true)

        let dl = SColor.fromString(Store.shared.string(key: "\(self.name)_downloadColor", defaultValue: SColor.secondBlue.key))
        self.downloadColor = (dl.additional as? NSColor) ?? NSColor.systemBlue
        let ul = SColor.fromString(Store.shared.string(key: "\(self.name)_uploadColor", defaultValue: SColor.secondRed.key))
        self.uploadColor = (ul.additional as? NSColor) ?? NSColor.systemRed
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .networkChartSettings, object: nil)
    }

    // called from the settings callback (base/speedUnit) and from the popup's chart-pref
    // section via .networkChartSettings (colors/scale) — both fire only on a UI change, not per tick
    public func settingsUpdated() {
        self.loadSettings()
        DispatchQueue.main.async(execute: {
            self.chart?.setBase(self.base)
            self.chart?.setSpeedUnit(self.speedUnit)
            self.chart?.setScale(self.chartScale, Double(self.chartFixedScaleSize.toBytes(self.chartFixedScale)))
            self.chart?.setColors(in: self.downloadColor, out: self.uploadColor)
        })
    }

    @objc private func chartSettingsChanged() {
        self.settingsUpdated()
    }

    public override func load() {
        self.loadSettings()
        NotificationCenter.default.addObserver(self, selector: #selector(self.chartSettingsChanged), name: .networkChartSettings, object: nil)
        let view = NSStackView()
        view.orientation = .vertical
        view.distribution = .fill
        view.spacing = Constants.Popup.spacing*2
        view.edgeInsets = NSEdgeInsets(
            top: 0,
            left: Constants.Popup.spacing*2,
            bottom: 0,
            right: Constants.Popup.spacing*2
        )
        
        let container: NSView = NSView(frame: CGRect(x: 0, y: 0, width: self.frame.width - (Constants.Popup.spacing*8), height: 68))
        container.wantsLayer = true
        container.layer?.cornerRadius = 3
        
        let chart = NetworkChartView(
            frame: CGRect(x: 0, y: 0, width: self.frame.width - (Constants.Popup.spacing*8), height: 68),
            num: 120,
            reversedOrder: self.reverseOrderState,
            outColor: self.uploadColor,
            inColor: self.downloadColor,
            scale: self.chartScale,
            fixedScale: Double(self.chartFixedScaleSize.toBytes(self.chartFixedScale))
        )
        chart.setBase(self.base)
        chart.setSpeedUnit(self.speedUnit)
        container.addSubview(chart)
        self.chart = chart
        view.addArrangedSubview(container)
        
        let publicIP = portalRow(view, title: "\(localizedString("Public IP")):", value: localizedString("Unknown"), isSelectable: true)
        self.publicIPField = publicIP.1
        self.publicIPView = publicIP.2
        self.publicIPView?.isHidden = !self.publicIPState
        self.publicIPView?.heightAnchor.constraint(equalToConstant: 16).isActive = true
        
        let localIP = portalRow(view, title: "\(localizedString("Local IP")):", value: localizedString("Unknown"), isSelectable: true)
        self.localIPField = localIP.1
        self.localIPView = localIP.2
        self.localIPView?.isHidden = self.publicIPState
        self.localIPView?.heightAnchor.constraint(equalToConstant: 16).isActive = true
        
        self.addArrangedSubview(view)
    }
    
    public func usageCallback(_ value: Network_Usage) {
        DispatchQueue.main.async(execute: {
            self.chart?.addValue(upload: Double(value.bandwidth.upload), download: Double(value.bandwidth.download))
            
            guard (self.window?.isVisible ?? false) || !self.initialized else { return }
            self.initialized = true

            if self.publicIPState, let view = self.publicIPView, view.isHidden {
                self.publicIPView?.isHidden = false
                self.localIPView?.isHidden = true
            } else if !self.publicIPState, let view = self.publicIPView, !view.isHidden {
                self.publicIPView?.isHidden = true
                self.localIPView?.isHidden = false
            }
            
            if let view = self.publicIPField, view.stringValue != value.raddr.v4 {
                if let addr = value.raddr.v4 {
                    view.stringValue = (value.wifiDetails.countryCode != nil) ? "\(addr) (\(value.wifiDetails.countryCode!))" : addr
                } else {
                    view.stringValue = localizedString("Unknown")
                }
                if let addr = value.raddr.v6 {
                    view.toolTip = "v6: \(addr)"
                } else {
                    view.toolTip = "v6: \(localizedString("Unknown"))"
                }
            }
            
            var privateIP = localizedString("Unknown")
            if let v4 = value.laddr.v4, !v4.isEmpty {
                privateIP = v4
            } else if let v6 = value.laddr.v6, !v6.isEmpty {
                privateIP = v6
            }
            if self.localIPField?.stringValue != privateIP {
                self.localIPField?.stringValue = privateIP
            }
        })
    }
}
