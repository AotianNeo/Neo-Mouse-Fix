//
// --------------------------------------------------------------------------
// WindowsPointerTabController.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

/// The 'Pointer' tab. Settings for `WindowsPointerAcceleration.swift` in the Helper (`Pointer.windowsAcceleration` and `Pointer.windowsSpeed` in config.plist).
///
/// Notes:
/// - Modeled on the 'Pointer Options' of the Windows mouse settings: A pointer speed slider and the 'Enhance pointer precision' checkbox.
/// - Built in code and added to the tab bar by `TabViewController.viewDidLoad()`. Not the same as the unfinished storyboard tab `PointerTabController`, which stays hidden.
/// - Laid out like the storyboard tabs: A single master stack is `view.subviews[0]` (TabViewController fades it in and out when switching tabs), with 30 pt side margins and 20 pt top and bottom margins.
/// - Defaults and ranges must match `WindowsPointerConfig` in the Helper.

import Cocoa
import ReactiveSwift
import ReactiveCocoa

class WindowsPointerTabController: NSViewController {

    private let enabled = ConfigValue<Bool>(configPath: "Pointer.windowsAcceleration")
    private let speed = ConfigValue<Int>(configPath: "Pointer.windowsSpeed")

    private static let contentWidth: CGFloat = 380

    override func loadView() {

        view = NSView()

        /// Enable checkbox + hint
        let checkbox = NSButton(checkboxWithTitle: MFLocalizedString("pointer.windows-acceleration", comment: ""), target: nil, action: nil)
        checkbox.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        checkbox.reactive.boolValue <~ enabled
        enabled <~ checkbox.reactive.boolValues

        let hint = NSTextField(wrappingLabelWithString: MFLocalizedString("pointer.windows-acceleration.hint", comment: ""))
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = Self.contentWidth - 20
        let hintIndent = NSStackView(views: [hint])
        hintIndent.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        /// Speed slider
        ///     1...20 like Windows. Updates the value label while dragging, but only writes the config when the user lets go (or uses the keyboard), so we don't notify the Helper for every step.
        let slider = NSSlider(value: 10, minValue: 1, maxValue: 20, target: nil, action: nil)
        slider.numberOfTickMarks = 20
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.toolTip = MFLocalizedString("pointer.speed.hint", comment: "")
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let valueLabel = NSTextField(labelWithString: "10")
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true

        speed.producer.take(during: reactive.lifetime).startWithValues { [weak slider, weak valueLabel] value in
            slider?.integerValue = value
            valueLabel?.stringValue = "\(value)"
        }
        slider.reactive.integerValues.take(during: reactive.lifetime).observeValues { [weak self, weak valueLabel] value in
            valueLabel?.stringValue = "\(value)"
            if NSApp.currentEvent?.type != .leftMouseDragged {
                self?.speed.set(value)
            }
        }

        let grid = NSGridView(views: [[NSTextField(labelWithString: MFLocalizedString("pointer.speed", comment: "")), slider, valueLabel]])
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8

        /// Master stack
        let master = NSStackView(views: [checkbox, hintIndent, grid])
        master.orientation = .vertical
        master.alignment = .leading
        master.spacing = 10
        master.setCustomSpacing(2, after: checkbox)
        master.setCustomSpacing(16, after: hintIndent)
        master.setHuggingPriority(.required, for: .vertical) /// Like the storyboard tabs. `TabViewController.resizeWindowToFit()` measures the tab after making the window huge, so the tab must not stretch.
        master.setHuggingPriority(.required, for: .horizontal)
        master.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(master)
        NSLayoutConstraint.activate([
            master.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            master.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            master.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            master.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -30),
            master.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])

        /// Don't stretch vertically
        ///     Views created in code hug with priority 250 by default and would stretch when TabViewController makes the window huge to measure the tab (-> the window ends up ~100000 pt tall).
        hugVertically(master)

        /// The slider only applies to Windows pointer acceleration
        slider.reactive.isEnabled <~ enabled.producer.prefix(value: false) /// Off until the config has a value (missing keys don't emit)
    }

    private func hugVertically(_ view: NSView) {
        view.setContentHuggingPriority(.init(999), for: .vertical) /// 999 instead of required: NSGridView stretches the views in a row to the row's height
        if let stack = view as? NSStackView {
            stack.setHuggingPriority(.init(999), for: .vertical)
        }
        if view is NSControl {
            view.setContentCompressionResistancePriority(.required, for: .vertical) /// Never squash controls and labels below their natural height
        }
        for subview in view.subviews {
            hugVertically(subview)
        }
    }
}
