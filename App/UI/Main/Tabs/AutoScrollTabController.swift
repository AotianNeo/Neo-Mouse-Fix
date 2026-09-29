//
// --------------------------------------------------------------------------
// AutoScrollTabController.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

/// The 'Auto Scroll' tab. Settings for `AutoScroll.swift` in the Helper (the `AutoScroll` dict in config.plist).
///
/// Notes:
/// - Built in code and added to the tab bar by `TabViewController.viewDidLoad()`.
/// - Laid out like the storyboard tabs: A single master stack is `view.subviews[0]` (TabViewController fades it in and out when switching tabs), with 30 pt side margins and 20 pt top and bottom margins.
/// - Defaults and ranges must match `AutoScrollConfig.swift` in the Helper.

import Cocoa
import ReactiveSwift
import ReactiveCocoa

class AutoScrollTabController: NSViewController {

    // MARK: Config

    private let enabled = ConfigValue<Bool>(configPath: "AutoScroll.enabled")
    private let button = ConfigValue<Int>(configPath: "AutoScroll.button")
    private let clickToToggle = ConfigValue<Bool>(configPath: "AutoScroll.clickToToggle")
    private let holdToActivate = ConfigValue<Bool>(configPath: "AutoScroll.holdToActivate")
    private let actAsButtonOverLinks = ConfigValue<Bool>(configPath: "AutoScroll.actAsButtonOverLinks")
    private let smartAutoScroll = ConfigValue<Bool>(configPath: "AutoScroll.smartAutoScroll")
    private let acceleration = ConfigValue<Double>(configPath: "AutoScroll.acceleration")
    private let superSlowdown = ConfigValue<Double>(configPath: "AutoScroll.superSlowdown")
    private let animateRelease = ConfigValue<Bool>(configPath: "AutoScroll.animateRelease")
    private let releaseDuration = ConfigValue<Double>(configPath: "AutoScroll.releaseDuration")
    private let reverseVertical = ConfigValue<Bool>(configPath: "AutoScroll.reverseVertical")
    private let reverseHorizontal = ConfigValue<Bool>(configPath: "AutoScroll.reverseHorizontal")

    private static let contentWidth: CGFloat = 380

    // MARK: Lifecycle

    override func loadView() {

        view = NSView()

        /// Enable + trigger button
        let enableToggle = makeCheckbox(enabled, key: "auto-scroll.enable", defaultValue: false)
        enableToggle.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        enableToggle.toolTip = MFLocalizedString("auto-scroll.enable.hint", comment: "")
        let buttonPicker = makeButtonPicker()
        let header = NSStackView(views: [enableToggle, NSView(), label("auto-scroll.button"), buttonPicker])
        header.alignment = .centerY

        /// Activation
        let activation = [
            makeCheckbox(clickToToggle, key: "auto-scroll.click-to-toggle", defaultValue: true, withHint: true),
            makeCheckbox(holdToActivate, key: "auto-scroll.hold-to-activate", defaultValue: true, withHint: true),
            makeCheckbox(actAsButtonOverLinks, key: "auto-scroll.act-as-button-over-links", defaultValue: true, withHint: true),
            makeCheckbox(smartAutoScroll, key: "auto-scroll.smart", defaultValue: false, withHint: true),
        ]

        /// Speed & release
        let accelerationSlider = makeSlider(acceleration, range: 1...20, step: 1, defaultValue: 10, format: { "\(Int($0))" })
        accelerationSlider.slider.toolTip = MFLocalizedString("auto-scroll.acceleration.hint", comment: "")
        let superSlowdownSlider = makeSlider(superSlowdown, range: 0...20, step: 1, defaultValue: 0, format: { "\(Int($0))" })
        superSlowdownSlider.slider.toolTip = MFLocalizedString("auto-scroll.super-slowdown.hint", comment: "")
        let animateReleaseToggle = makeCheckbox(animateRelease, key: "auto-scroll.animate-release", defaultValue: false)
        animateReleaseToggle.toolTip = MFLocalizedString("auto-scroll.animate-release.hint", comment: "")
        let releaseDurationSlider = makeSlider(releaseDuration, range: 0...3000, step: 50, defaultValue: 400, format: { "\(Int($0)) ms" })

        /// Direction
        ///     One checkbox per row, so column 1 stays as wide as the sliders. (Both in one row made the grid wider than the tab, which truncated the checkboxes and squeezed out the value labels.)
        let reverseVerticalToggle = makeCheckbox(reverseVertical, key: "auto-scroll.reverse-vertical", defaultValue: false)
        let reverseHorizontalToggle = makeCheckbox(reverseHorizontal, key: "auto-scroll.reverse-horizontal", defaultValue: false)

        let grid = NSGridView(views: [
            [label("auto-scroll.acceleration"), accelerationSlider.slider, accelerationSlider.valueLabel],
            [label("auto-scroll.super-slowdown"), superSlowdownSlider.slider, superSlowdownSlider.valueLabel],
            [NSGridCell.emptyContentView, animateReleaseToggle, NSGridCell.emptyContentView],
            [label("auto-scroll.release-duration"), releaseDurationSlider.slider, releaseDurationSlider.valueLabel],
            [label("auto-scroll.scroll-direction"), reverseVerticalToggle, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, reverseHorizontalToggle, NSGridCell.emptyContentView],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 10
        grid.row(at: 2).topPadding = 6
        grid.row(at: 4).topPadding = 6

        /// Master stack
        let master = NSStackView(views: [header, separator()] + activation + [separator(), grid])
        master.orientation = .vertical
        master.alignment = .leading
        master.spacing = 10
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
            header.widthAnchor.constraint(equalTo: master.widthAnchor),
        ])
        for subview in master.arrangedSubviews where subview is NSBox {
            subview.widthAnchor.constraint(equalTo: master.widthAnchor).isActive = true
        }

        /// Don't stretch vertically
        ///     TabViewController measures a tab after making the window huge. The storyboard tabs' views all hug their content with priority 750+, so they keep their natural height. Views created in code default to 250 and would stretch – making the window ~100000 pt tall.
        hugVertically(master)

        /// Everything except the enable toggle is disabled while Auto Scroll is off
        for control in allControls(in: master) where control !== enableToggle {
            if control === releaseDurationSlider.slider {
                control.reactive.isEnabled <~ SignalProducer.combineLatest(enabled.producer.prefix(value: false), animateRelease.producer.prefix(value: false)).map { $0 && $1 }
            } else {
                control.reactive.isEnabled <~ enabled.producer
            }
        }
    }

    // MARK: Building blocks

    private func label(_ key: String) -> NSTextField {
        return NSTextField(labelWithString: MFLocalizedString(key, comment: ""))
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func makeCheckbox(_ configValue: ConfigValue<Bool>, key: String, defaultValue: Bool) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: MFLocalizedString(key, comment: ""), target: nil, action: nil)
        checkbox.state = defaultValue ? .on : .off /// Shown until the config has a value
        checkbox.reactive.boolValue <~ configValue
        configValue <~ checkbox.reactive.boolValues
        return checkbox
    }

    private func makeCheckbox(_ configValue: ConfigValue<Bool>, key: String, defaultValue: Bool, withHint: Bool) -> NSView {

        /// Checkbox with an indented hint below it. Mirrors the 'Trackpad Simulation' toggle on the Scrolling tab.

        let checkbox = makeCheckbox(configValue, key: key, defaultValue: defaultValue)

        let hint = NSTextField(wrappingLabelWithString: MFLocalizedString(key + ".hint", comment: ""))
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = Self.contentWidth - 20

        let indent = NSStackView(views: [hint])
        indent.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        let section = NSStackView(views: [checkbox, indent])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 2
        return section
    }

    private func makeButtonPicker() -> NSPopUpButton {

        let picker = NSPopUpButton()
        for buttonNumber in 3...5 {
            picker.addItem(withTitle: UIStrings.getButtonString(MFMouseButtonNumber(rawValue: UInt32(buttonNumber)), context: kMFButtonStringUsageContextActionTableGroupRow))
            picker.lastItem?.tag = buttonNumber
        }
        picker.selectItem(withTag: 3)

        button.producer.take(during: reactive.lifetime).startWithValues { [weak picker] buttonNumber in
            guard let picker else { return }
            if picker.indexOfItem(withTag: buttonNumber) == -1 { /// The Helper accepts buttons 3...32. Show the configured button even if it's not one of the defaults.
                picker.addItem(withTitle: UIStrings.getButtonString(MFMouseButtonNumber(rawValue: UInt32(buttonNumber)), context: kMFButtonStringUsageContextActionTableGroupRow))
                picker.lastItem?.tag = buttonNumber
            }
            picker.selectItem(withTag: buttonNumber)
        }
        picker.reactive.selectedTags.take(during: reactive.lifetime).observeValues { [weak self] buttonNumber in
            self?.button.set(buttonNumber)
        }
        return picker
    }

    private func makeSlider(_ configValue: ConfigValue<Double>, range: ClosedRange<Double>, step: Double, defaultValue: Double, format: @escaping (Double) -> String) -> (slider: NSSlider, valueLabel: NSTextField) {

        /// Updates the value label while dragging, but only writes the config when the user lets go (or uses the keyboard). Otherwise we'd commit the config (and notify the Helper) for every step of the drag.

        let slider = NSSlider(value: defaultValue, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let valueLabel = NSTextField(labelWithString: format(defaultValue))
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true /// Fits "2000 ms"

        configValue.producer.take(during: reactive.lifetime).startWithValues { [weak slider, weak valueLabel] value in
            slider?.doubleValue = value
            valueLabel?.stringValue = format(value)
        }
        slider.reactive.doubleValues.take(during: reactive.lifetime).observeValues { [weak valueLabel] rawValue in
            let value = (rawValue / step).rounded() * step
            valueLabel?.stringValue = format(value)
            if NSApp.currentEvent?.type != .leftMouseDragged {
                configValue.set(value)
            }
        }
        return (slider, valueLabel)
    }

    private func hugVertically(_ view: NSView) {
        /// 999 instead of required: NSGridView stretches the views in a row to the row's height, which would conflict with required hugging.
        view.setContentHuggingPriority(.init(999), for: .vertical)
        if let stack = view as? NSStackView {
            stack.setHuggingPriority(.init(999), for: .vertical)
        }
        /// Controls and labels must never be squashed below their natural height. (Their default compression resistance is 750, which loses against the 999 hugging above – NSGridView then squashed the labels to a few points.)
        if view is NSControl {
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        for subview in view.subviews {
            hugVertically(subview)
        }
    }

    private func allControls(in view: NSView) -> [NSControl] {
        return view.subviews.flatMap { subview -> [NSControl] in
            if let control = subview as? NSControl, !(control is NSTextField) { return [control] }
            return allControls(in: subview)
        }
    }
}
