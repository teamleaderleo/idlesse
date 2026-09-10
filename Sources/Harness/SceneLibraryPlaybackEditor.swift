import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

extension SceneLibraryController {
    func editPlayback() {
        guard let id = filter.selectedItem?.representedObject as? String,
              let collection = store.catalog.collections.first(where: { $0.id == id }),
              let window = presentationWindow else { return }
        let settings = collection.playback ?? SceneLibraryStore.Playback()
        let enabled = NSButton(checkboxWithTitle: "Play on a schedule", target: nil, action: nil)
        enabled.state = settings.startMinute == nil ? .off : .on
        let shuffle = NSButton(checkboxWithTitle: "Shuffle without repeats", target: nil, action: nil)
        shuffle.state = settings.shuffle ? .on : .off
        let interval = NSPopUpButton()
        interval.addItems(withTitles: ["5 minutes", "15 minutes", "30 minutes", "60 minutes"])
        interval.selectItem(at: [5, 15, 30, 60].firstIndex(of: settings.minutes) ?? 2)

        func picker(_ minute: Int) -> NSDatePicker {
            let view = NSDatePicker()
            view.datePickerElements = .hourMinute
            view.datePickerStyle = .textFieldAndStepper
            view.dateValue = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60,
                                                   second: 0, of: Date())!
            return view
        }
        let start = picker(settings.startMinute ?? 420)
        let end = picker(settings.endMinute ?? 1320)
        let dayButtons = (1...7).map { day -> NSButton in
            let button = NSButton(checkboxWithTitle: Calendar.current.shortWeekdaySymbols[day - 1],
                                  target: nil, action: nil)
            button.state = (settings.weekdays?.contains(day) ?? true) ? .on : .off
            return button
        }
        let days = NSStackView(views: dayButtons)
        days.orientation = .horizontal
        days.spacing = 8
        let stack = NSStackView(views: [enabled, days, NSTextField(labelWithString: "From"), start,
            NSTextField(labelWithString: "Until"), end,
            NSTextField(labelWithString: "Change scene every"), interval, shuffle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: 305)
        let alert = NSAlert()
        alert.messageText = collection.name + " Playback"
        alert.informativeText = "Local time. Checked days are when a range starts; an overnight range continues into the following morning. Manual wallpaper choices last until the next boundary. Bedtime dimming stays independent."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn else { return }
            func minute(_ picker: NSDatePicker) -> Int {
                let c = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
                return c.hour! * 60 + c.minute!
            }
            let updated = SceneLibraryStore.Playback(
                minutes: [5, 15, 30, 60][interval.indexOfSelectedItem],
                shuffle: shuffle.state == .on,
                startMinute: enabled.state == .on ? minute(start) : nil,
                endMinute: enabled.state == .on ? minute(end) : nil,
                weekdays: enabled.state == .off ? nil :
                    Set(dayButtons.enumerated().compactMap {
                        $0.element.state == .on ? $0.offset + 1 : nil
                    }))
            do {
                try self.store.setPlayback(id, updated)
                self.scheduleToken = nil
                self.checkSchedule()
                self.preview()
            } catch { self.detail.stringValue = error.localizedDescription }
        }
    }

}
