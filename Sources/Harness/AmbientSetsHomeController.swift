import AppKit

/// Home destination for ordered Ambient Sets. The controller edits the same
/// persisted catalog consumed by AmbientModesController and never owns timers
/// or decision logic itself.
final class AmbientSetsHomeController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static let dragType = NSPasteboard.PasteboardType("com.teamleaderleo.idlesse.ambient-set")
    private final class TargetChoice: NSObject {
        let target: AmbientWallpaperTarget?
        init(_ target: AmbientWallpaperTarget?) { self.target = target }
    }

    private let modes: AmbientModesController
    private let indexURL: URL
    private var sets: [AmbientSet] = []
    private var selectedID: String?
    private var lastResolutionKey = ""
    private var loadingEditor = false

    private let table = NSTableView()
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private let explanationLabel = NSTextField(wrappingLabelWithString: "")
    private let nextLabel = NSTextField(wrappingLabelWithString: "")
    private let authorityButton = NSButton(title: "Use Ambient Sets", target: nil, action: nil)
    private let migrateButton = NSButton(title: "Create from Existing Automation…", target: nil, action: nil)
    private let addButton = NSButton(title: "+", target: nil, action: nil)
    private let removeButton = NSButton(title: "−", target: nil, action: nil)
    private let upButton = NSButton(title: "Move Up", target: nil, action: nil)
    private let downButton = NSButton(title: "Move Down", target: nil, action: nil)
    private let activateButton = NSButton(title: "Use Until Next Change", target: nil, action: nil)
    private let keepButton = NSButton(title: "Keep Until I Resume", target: nil, action: nil)
    private let resumeButton = NSButton(title: "Resume Automation", target: nil, action: nil)

    private let nameField = NSTextField(string: "")
    private let enabledButton = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let wallpaperPopup = NSPopUpButton()
    private let filesPopup = NSPopUpButton()
    private let widgetsPopup = NSPopUpButton()
    private let dimPopup = NSPopUpButton()
    private let dimSlider = NSSlider(value: 90, minValue: 20, maxValue: 98, target: nil, action: nil)
    private let dimValue = NSTextField(labelWithString: "90%")
    private let automaticButton = NSButton(checkboxWithTitle: "Automatic When", target: nil, action: nil)
    private let timeButton = NSButton(checkboxWithTitle: "Time range", target: nil, action: nil)
    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private let weekdaysButton = NSButton(checkboxWithTitle: "Weekdays", target: nil, action: nil)
    private var weekdayButtons: [NSButton] = []
    private let solarButton = NSButton(checkboxWithTitle: "After sunset until sunrise", target: nil, action: nil)

    init(modes: AmbientModesController, indexURL: URL) {
        self.modes = modes
        self.indexURL = indexURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: .zero)
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root
        buildUI(in: root)
        reloadCatalog(selecting: nil)
    }

    func refreshResolution() {
        let key = Self.resolutionKey(modes.currentAmbientResolution, authoritative: modes.isAmbientSetsAuthoritative)
        guard key != lastResolutionKey else { return }
        lastResolutionKey = key
        updateStateLabels()
        table.reloadData()
    }

    func reloadCatalog(selecting id: String?) {
        sets = modes.ambientSets
        if let id, sets.contains(where: { $0.id == id }) {
            selectedID = id
        } else if let selectedID, sets.contains(where: { $0.id == selectedID }) {
            self.selectedID = selectedID
        } else {
            selectedID = sets.first?.id
        }
        table.reloadData()
        selectCurrentRow()
        loadSelectedSet()
        updateStateLabels()
    }

    // MARK: - Shared status formatting

    static func chipTitle(_ resolution: AmbientResolution?, authoritative: Bool) -> String {
        guard authoritative else { return "◐ Ambient Sets · Off" }
        guard let explanation = resolution?.explanation else { return "◐ Ambient Sets" }
        let name = explanation.activeSetName ?? "Arrangement Default"
        let suffix = explanation.nextChange.map { " · until \(shortTime($0.date))" } ?? ""
        switch explanation.source {
        case .manualSet, .manualOverrides:
            return "✋ \(name)\(suffix)"
        case .automatic:
            return "◐ \(name)\(suffix)"
        case .arrangementDefault:
            return "◐ Arrangement Default\(suffix)"
        }
    }

    static func explanationText(_ resolution: AmbientResolution?) -> String {
        guard let resolution else { return "Ambient Sets have not resolved yet." }
        let explanation = resolution.explanation
        var parts: [String] = []
        switch explanation.source {
        case .manualSet:
            parts.append("\(explanation.activeSetName ?? "This set") is active by manual hold.")
        case .manualOverrides:
            parts.append("Manual desktop changes are active by manual hold.")
        case .automatic:
            parts.append("\(explanation.activeSetName ?? "This set") is the first matching automatic set.")
        case .arrangementDefault:
            parts.append("Arrangement Default is active because no automatic set wins.")
        }
        let reasonStrings = explanation.reasons.compactMap(reasonText)
        if !reasonStrings.isEmpty { parts.append(reasonStrings.joined(separator: " · ")) }
        if !explanation.alsoMatched.isEmpty {
            parts.append("Also matched: " + explanation.alsoMatched.map { "#\($0.priority) \($0.name)" }.joined(separator: ", ") + ".")
        }
        return parts.joined(separator: " ")
    }

    static func resolvedStateText(_ resolution: AmbientResolution?) -> String {
        guard let state = resolution?.state else { return "" }
        let wallpaper: String
        if AmbientSetActuationPolicy.isArrangementDefault(state.wallpaper) || state.wallpaper == nil {
            wallpaper = "Arrangement Default"
        } else if AmbientSetActuationPolicy.isCurrentSelection(state.wallpaper) {
            wallpaper = "Manual wallpaper"
        } else if let target = state.wallpaper {
            wallpaper = target.kind == .scene ? "Scene" : "Collection"
        } else {
            wallpaper = "Arrangement Default"
        }
        let dim = state.dimming.enabled ? "\(Int((state.dimming.level * 100).rounded()))% dim" : "Dimming off"
        return "\(wallpaper) · Files \(state.filesVisible ? "shown" : "hidden") · Widgets \(state.widgetsVisible ? "shown" : "hidden") · \(dim)"
    }

    static func nextChangeText(_ resolution: AmbientResolution?) -> String {
        guard let change = resolution?.explanation.nextChange else { return "No scheduled winner change" }
        return "Next change \(shortDateTime(change.date))"
    }

    private static func resolutionKey(_ resolution: AmbientResolution?, authoritative: Bool) -> String {
        guard authoritative else { return "off" }
        guard let resolution else { return "pending" }
        let e = resolution.explanation
        return "\(e.source.rawValue)|\(e.activeSetID ?? "-")|\(e.activeSetName ?? "-")|\(e.nextChange?.date.timeIntervalSince1970 ?? -1)|\(e.alsoMatched.map(\.id).joined(separator: ","))"
    }

    private static func reasonText(_ reason: AmbientExplanationReason) -> String? {
        switch reason {
        case .manualHold:
            return "Manual Hold"
        case .priority(let priority):
            return "Priority #\(priority)"
        case .timeRange(let range):
            return "\(clock(range.startMinute))–\(clock(range.endMinute))"
        case .weekday(let weekday):
            let symbols = Calendar.current.weekdaySymbols
            return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : nil
        case .solarNight(let sunrise, let sunset):
            return "Sunset \(shortTime(sunset)) · sunrise \(shortTime(sunrise))"
        case .arrangementDefault:
            return "Arrangement Default"
        }
    }

    private static func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private static func shortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        return formatter.string(from: date)
    }

    // MARK: - UI

    private func buildUI(in root: NSView) {
        let title = NSTextField(labelWithString: "Ambient Sets")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString:
            "Name desktop states, order their priority, and let one resolver choose the active result.")
        intro.textColor = .secondaryLabelColor

        stateLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        explanationLabel.textColor = .secondaryLabelColor
        nextLabel.textColor = .secondaryLabelColor

        authorityButton.target = self
        authorityButton.action = #selector(toggleAuthority)
        authorityButton.bezelStyle = .rounded
        migrateButton.target = self
        migrateButton.action = #selector(migrateLegacy)
        migrateButton.bezelStyle = .rounded
        let authorityRow = NSStackView(views: [authorityButton, migrateButton, resumeButton])
        authorityRow.spacing = 8
        resumeButton.target = self
        resumeButton.action = #selector(resumeAutomation)
        resumeButton.bezelStyle = .rounded

        let header = NSStackView(views: [title, intro, stateLabel, explanationLabel, nextLabel, authorityRow])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 7
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        intro.widthAnchor.constraint(lessThanOrEqualToConstant: 760).isActive = true
        explanationLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 760).isActive = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)

        let listPane = NSView(frame: .zero)
        let detailPane = NSView(frame: .zero)
        split.addArrangedSubview(listPane)
        split.addArrangedSubview(detailPane)
        listPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        listPane.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true

        buildList(in: listPane)
        buildEditor(in: detailPane)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -28),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            split.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])
    }

    private func buildList(in pane: NSView) {
        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(scroll)
        table.headerView = nil
        table.rowHeight = 46
        table.allowsMultipleSelection = false
        table.delegate = self
        table.dataSource = self
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("AmbientSet"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        scroll.documentView = table

        for button in [addButton, removeButton, upButton, downButton] {
            button.bezelStyle = .rounded
        }
        addButton.target = self; addButton.action = #selector(addSet)
        removeButton.target = self; removeButton.action = #selector(removeSet)
        upButton.target = self; upButton.action = #selector(moveUp)
        downButton.target = self; downButton.action = #selector(moveDown)
        let buttons = NSStackView(views: [addButton, removeButton, NSView(), upButton, downButton])
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(buttons)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: pane.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            buttons.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
    }

    private func buildEditor(in pane: NSView) {
        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(scroll)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 620))
        scroll.documentView = document

        nameField.delegate = self
        enabledButton.target = self; enabledButton.action = #selector(editorChanged)
        nameField.target = self; nameField.action = #selector(editorChanged)
        configurePopup(filesPopup, titles: ["Default", "Show", "Hide"])
        configurePopup(widgetsPopup, titles: ["Default", "Show", "Hide"])
        configurePopup(dimPopup, titles: ["Default", "Off", "On"])
        wallpaperPopup.target = self; wallpaperPopup.action = #selector(editorChanged)
        filesPopup.target = self; filesPopup.action = #selector(editorChanged)
        widgetsPopup.target = self; widgetsPopup.action = #selector(editorChanged)
        dimPopup.target = self; dimPopup.action = #selector(editorChanged)
        dimSlider.target = self; dimSlider.action = #selector(editorChanged)
        dimSlider.isContinuous = true

        automaticButton.target = self; automaticButton.action = #selector(editorChanged)
        timeButton.target = self; timeButton.action = #selector(editorChanged)
        weekdaysButton.target = self; weekdaysButton.action = #selector(editorChanged)
        solarButton.target = self; solarButton.action = #selector(editorChanged)
        for picker in [startPicker, endPicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.hourMinute]
            picker.target = self
            picker.action = #selector(editorChanged)
        }

        let weekdaySymbols = Calendar.current.shortWeekdaySymbols
        for weekday in 1...7 {
            let title = weekdaySymbols.indices.contains(weekday - 1) ? weekdaySymbols[weekday - 1] : "\(weekday)"
            let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(editorChanged))
            button.tag = weekday
            weekdayButtons.append(button)
        }
        let weekdayRow = NSStackView(views: weekdayButtons)
        weekdayRow.spacing = 6

        let dimRow = NSStackView(views: [dimPopup, dimSlider, dimValue])
        dimRow.spacing = 8
        dimSlider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        dimValue.widthAnchor.constraint(equalToConstant: 42).isActive = true

        let timeRow = NSStackView(views: [timeButton, startPicker, NSTextField(labelWithString: "to"), endPicker])
        timeRow.spacing = 7
        let weekdayCondition = NSStackView(views: [weekdaysButton, weekdayRow])
        weekdayCondition.spacing = 8

        activateButton.target = self; activateButton.action = #selector(activateUntilChange)
        keepButton.target = self; keepButton.action = #selector(activateUntilResume)
        activateButton.bezelStyle = .rounded
        keepButton.bezelStyle = .rounded
        let activationRow = NSStackView(views: [activateButton, keepButton])
        activationRow.spacing = 8

        let grid = NSGridView(views: [
            [fieldLabel("Name"), nameField],
            [NSView(), enabledButton],
            [fieldLabel("Wallpaper"), wallpaperPopup],
            [fieldLabel("Files"), filesPopup],
            [fieldLabel("Widgets"), widgetsPopup],
            [fieldLabel("Dimming"), dimRow],
            [fieldLabel("Activation"), automaticButton],
            [NSView(), timeRow],
            [NSView(), weekdayCondition],
            [NSView(), solarButton],
            [NSView(), activationRow],
        ])
        grid.rowSpacing = 13
        grid.columnSpacing = 14
        grid.column(at: 0).width = 84
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(grid)
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        wallpaperPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 18),
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: 6),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -16),
        ])
    }

    private func configurePopup(_ popup: NSPopUpButton, titles: [String]) {
        popup.removeAllItems()
        popup.addItems(withTitles: titles)
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { sets.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard sets.indices.contains(row) else { return nil }
        let set = sets[row]
        let cell = NSTableCellView(frame: .zero)
        let title = NSTextField(labelWithString: "\(row + 1). \(set.name)")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithString: activationSummary(set))
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let active = modes.currentAmbientResolution?.explanation.activeSetID == set.id
        let marker = NSTextField(labelWithString: active ? "●" : "")
        marker.textColor = .controlAccentColor
        for view in [marker, title, subtitle] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([
            marker.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            marker.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 12),
            title.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 4),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard sets.indices.contains(table.selectedRow) else { return }
        selectedID = sets[table.selectedRow].id
        loadSelectedSet()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard sets.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(sets[row].id, forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingPasteboard.string(forType: Self.dragType) != nil else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let id = info.draggingPasteboard.string(forType: Self.dragType),
              let source = sets.firstIndex(where: { $0.id == id }) else { return false }
        let item = sets.remove(at: source)
        let destination = min(max(0, row > source ? row - 1 : row), sets.count)
        sets.insert(item, at: destination)
        persistSets(selecting: id)
        return true
    }

    private func selectCurrentRow() {
        guard let selectedID, let index = sets.firstIndex(where: { $0.id == selectedID }) else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    private func activationSummary(_ set: AmbientSet) -> String {
        guard let activation = set.activation else { return "Manual Only" }
        var parts: [String] = []
        if let range = activation.timeRange { parts.append("\(Self.clock(range.startMinute))–\(Self.clock(range.endMinute))") }
        if let weekdays = activation.weekdays { parts.append("\(weekdays.count) day\(weekdays.count == 1 ? "" : "s")") }
        if activation.solar != nil { parts.append("Sunset → sunrise") }
        return parts.isEmpty ? "Always automatic" : parts.joined(separator: " · ")
    }

    // MARK: - Editor

    private func loadSelectedSet() {
        loadingEditor = true
        defer { loadingEditor = false; updateEditorEnabledState() }
        guard let set = selectedSet() else {
            nameField.stringValue = ""
            for control in editorControls() { control.isEnabled = false }
            removeButton.isEnabled = false
            upButton.isEnabled = false
            downButton.isEnabled = false
            activateButton.isEnabled = false
            keepButton.isEnabled = false
            return
        }
        for control in editorControls() { control.isEnabled = true }
        removeButton.isEnabled = true
        nameField.stringValue = set.name
        enabledButton.state = set.isEnabled ? .on : .off
        populateWallpaperPopup(selected: set.overrides.wallpaper)
        setOverridePopup(filesPopup, value: set.overrides.filesVisible)
        setOverridePopup(widgetsPopup, value: set.overrides.widgetsVisible)
        if let dim = set.overrides.dimming {
            dimPopup.selectItem(at: dim.enabled ? 2 : 1)
            dimSlider.doubleValue = (dim.level ?? 0.9) * 100
        } else {
            dimPopup.selectItem(at: 0)
            dimSlider.doubleValue = 90
        }
        dimValue.stringValue = "\(Int(dimSlider.doubleValue.rounded()))%"
        automaticButton.state = set.activation == nil ? .off : .on
        let activation = set.activation
        if let range = activation?.timeRange {
            timeButton.state = .on
            startPicker.dateValue = DimSchedule.pickerDate(minute: range.startMinute, on: Date())
            endPicker.dateValue = DimSchedule.pickerDate(minute: range.endMinute, on: Date())
        } else {
            timeButton.state = .off
            startPicker.dateValue = DimSchedule.pickerDate(minute: 18 * 60, on: Date())
            endPicker.dateValue = DimSchedule.pickerDate(minute: 23 * 60, on: Date())
        }
        if let weekdays = activation?.weekdays {
            weekdaysButton.state = .on
            for button in weekdayButtons { button.state = weekdays.contains(button.tag) ? .on : .off }
        } else {
            weekdaysButton.state = .off
            for button in weekdayButtons { button.state = .on }
        }
        solarButton.state = activation?.solar == .night ? .on : .off
        if let index = sets.firstIndex(where: { $0.id == set.id }) {
            upButton.isEnabled = index > 0
            downButton.isEnabled = index + 1 < sets.count
        }
        activateButton.isEnabled = set.isEnabled && modes.isAmbientSetsAuthoritative
        keepButton.isEnabled = set.isEnabled && modes.isAmbientSetsAuthoritative
    }

    private func updateEditorEnabledState() {
        let hasSet = selectedSet() != nil
        let automatic = hasSet && automaticButton.state == .on
        timeButton.isEnabled = automatic
        weekdaysButton.isEnabled = automatic
        solarButton.isEnabled = automatic
        startPicker.isEnabled = automatic && timeButton.state == .on
        endPicker.isEnabled = automatic && timeButton.state == .on
        for button in weekdayButtons { button.isEnabled = automatic && weekdaysButton.state == .on }
        dimSlider.isEnabled = hasSet && dimPopup.indexOfSelectedItem == 2
        dimValue.isEnabled = dimSlider.isEnabled
    }

    private func editorControls() -> [NSControl] {
        [nameField, enabledButton, wallpaperPopup, filesPopup, widgetsPopup, dimPopup, dimSlider,
         automaticButton, timeButton, startPicker, endPicker, weekdaysButton, solarButton] + weekdayButtons.map { $0 as NSControl }
    }

    private func selectedSet() -> AmbientSet? {
        guard let selectedID else { return nil }
        return sets.first(where: { $0.id == selectedID })
    }

    @objc private func editorChanged() {
        guard !loadingEditor, let selectedID, let index = sets.firstIndex(where: { $0.id == selectedID }) else { return }
        var set = sets[index]
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { set.name = String(trimmed.prefix(AmbientSet.maxNameLength)) }
        set.isEnabled = enabledButton.state == .on
        set.overrides.wallpaper = (wallpaperPopup.selectedItem?.representedObject as? TargetChoice)?.target
        set.overrides.filesVisible = overrideValue(filesPopup)
        set.overrides.widgetsVisible = overrideValue(widgetsPopup)
        switch dimPopup.indexOfSelectedItem {
        case 1: set.overrides.dimming = AmbientDimmingOverride(enabled: false)
        case 2: set.overrides.dimming = AmbientDimmingOverride(enabled: true, level: dimSlider.doubleValue / 100)
        default: set.overrides.dimming = nil
        }
        dimValue.stringValue = "\(Int(dimSlider.doubleValue.rounded()))%"

        if automaticButton.state == .on {
            var range: AmbientTimeRange?
            if timeButton.state == .on {
                let start = minute(startPicker)
                let end = minute(endPicker)
                if start == end {
                    let adjusted = (end + 60) % 1440
                    endPicker.dateValue = DimSchedule.pickerDate(minute: adjusted, on: Date())
                    range = AmbientTimeRange(startMinute: start, endMinute: adjusted)
                } else {
                    range = AmbientTimeRange(startMinute: start, endMinute: end)
                }
            }
            var weekdays: Set<Int>?
            if weekdaysButton.state == .on {
                var selected = Set(weekdayButtons.filter { $0.state == .on }.map(\.tag))
                if selected.isEmpty {
                    selected = Set(1...7)
                    weekdayButtons.forEach { $0.state = .on }
                }
                weekdays = selected.count == 7 ? nil : selected
            }
            set.activation = AmbientActivation(timeRange: range, weekdays: weekdays,
                                               solar: solarButton.state == .on ? .night : nil)
        } else {
            set.activation = nil
        }
        sets[index] = set
        persistSets(selecting: set.id)
        updateEditorEnabledState()
    }

    func controlTextDidEndEditing(_ obj: Notification) { editorChanged() }

    private func minute(_ picker: NSDatePicker) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func setOverridePopup(_ popup: NSPopUpButton, value: Bool?) {
        if let value { popup.selectItem(at: value ? 1 : 2) } else { popup.selectItem(at: 0) }
    }

    private func overrideValue(_ popup: NSPopUpButton) -> Bool? {
        switch popup.indexOfSelectedItem {
        case 1: return true
        case 2: return false
        default: return nil
        }
    }

    private func populateWallpaperPopup(selected: AmbientWallpaperTarget?) {
        wallpaperPopup.removeAllItems()
        addTargetItem("Arrangement Default", target: nil)
        let builtins = SceneLibraryController.builtinScenes()
        if !builtins.isEmpty {
            let separator = NSMenuItem.separator(); wallpaperPopup.menu?.addItem(separator)
            for item in builtins {
                addTargetItem("Scene · \(item.name)", target: .scene("builtin.\(item.name)"))
            }
        }
        if let store = try? SceneLibraryStore(file: indexURL) {
            if !store.catalog.entries.isEmpty { wallpaperPopup.menu?.addItem(.separator()) }
            for entry in store.catalog.entries.prefix(SceneLibraryStore.maxEntries) {
                addTargetItem("Scene · \(entry.title)", target: .scene(entry.id))
            }
            if !store.catalog.collections.isEmpty { wallpaperPopup.menu?.addItem(.separator()) }
            for collection in store.catalog.collections.prefix(SceneLibraryStore.maxEntries) {
                addTargetItem("Collection · \(collection.name)", target: .collection(collection.id))
            }
        }
        let selectedIndex = wallpaperPopup.itemArray.firstIndex {
            (($0.representedObject as? TargetChoice)?.target) == selected
        } ?? 0
        wallpaperPopup.selectItem(at: selectedIndex)
    }

    private func addTargetItem(_ title: String, target: AmbientWallpaperTarget?) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = TargetChoice(target)
        wallpaperPopup.menu?.addItem(item)
    }

    // MARK: - Actions

    @objc private func addSet() {
        guard sets.count < AmbientSetResolver.maxSets else { return }
        let set = AmbientSet(name: "Ambient Set", activation: nil)
        sets.append(set)
        persistSets(selecting: set.id)
    }

    @objc private func removeSet() {
        guard let selectedID else { return }
        sets.removeAll { $0.id == selectedID }
        let next = sets.first?.id
        persistSets(selecting: next)
    }

    @objc private func moveUp() { moveSelected(by: -1) }
    @objc private func moveDown() { moveSelected(by: 1) }

    private func moveSelected(by delta: Int) {
        guard let selectedID, let index = sets.firstIndex(where: { $0.id == selectedID }) else { return }
        let destination = index + delta
        guard sets.indices.contains(destination) else { return }
        sets.swapAt(index, destination)
        persistSets(selecting: selectedID)
    }

    @objc private func activateUntilChange() {
        guard let selectedID else { return }
        run { try modes.activateAmbientSet(id: selectedID, untilResumed: false) }
    }

    @objc private func activateUntilResume() {
        guard let selectedID else { return }
        run { try modes.activateAmbientSet(id: selectedID, untilResumed: true) }
    }

    @objc private func resumeAutomation() {
        run { try modes.resumeAutomaticAmbientSets() }
    }

    @objc private func toggleAuthority() {
        if modes.isAmbientSetsAuthoritative {
            run { try modes.disableAmbientSets() }
        } else {
            run { try modes.enableAmbientSets(sets) }
        }
    }

    @objc private func migrateLegacy() {
        run { _ = try modes.migrateLegacyToAmbientSets() }
        reloadCatalog(selecting: modes.ambientSets.first?.id)
    }

    private func persistSets(selecting id: String?) {
        do {
            try modes.replaceAmbientSets(sets)
            reloadCatalog(selecting: id)
        } catch {
            present(error)
            reloadCatalog(selecting: selectedID)
        }
    }

    private func run(_ operation: () throws -> Void) {
        do {
            try operation()
            reloadCatalog(selecting: selectedID)
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Ambient Sets"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }

    private func updateStateLabels() {
        let authoritative = modes.isAmbientSetsAuthoritative
        authorityButton.title = authoritative ? "Restore Legacy Automation" : "Use Ambient Sets"
        migrateButton.isHidden = authoritative
        resumeButton.isHidden = modes.currentAmbientResolution?.explanation.source != .manualSet &&
                                modes.currentAmbientResolution?.explanation.source != .manualOverrides
        stateLabel.stringValue = Self.chipTitle(modes.currentAmbientResolution, authoritative: authoritative)
        explanationLabel.stringValue = authoritative ? Self.explanationText(modes.currentAmbientResolution) :
            "Ambient Sets are saved but legacy automation still has authority."
        nextLabel.stringValue = authoritative ? [Self.resolvedStateText(modes.currentAmbientResolution), Self.nextChangeText(modes.currentAmbientResolution)]
            .filter { !$0.isEmpty }.joined(separator: " · ") : ""
        activateButton.isEnabled = authoritative && (selectedSet()?.isEnabled ?? false)
        keepButton.isEnabled = activateButton.isEnabled
    }
}
