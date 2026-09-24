import Cocoa
import AppKit
import VideoOptimizerCore

/// The only chrome in the app: a standard tabbed preferences window (spec §5.2).
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private let store = SettingsStore.shared

    private let outputLocation = NSPopUpButton()
    private let folderLabel = NSTextField(labelWithString: "")
    private let suffixField = NSTextField(string: "")
    private let conflictPolicy = NSPopUpButton()

    private let resolution = NSPopUpButton()
    private let encoderMode = NSSegmentedControl(
        labels: ["Fast", "Balanced", "Smallest"], trackingMode: .selectOne, target: nil, action: nil
    )
    private let codec = NSPopUpButton()
    private let qualityOffset = NSSlider(value: 0, minValue: -3, maxValue: 3, target: nil, action: nil)
    private let qualityOffsetLabel = NSTextField(labelWithString: "0")
    private let useHardware = NSButton(checkboxWithTitle: "Use the Apple media engine (much faster, slightly larger files)", target: nil, action: nil)
    private let analyseVMAF = NSButton(checkboxWithTitle: "Analyse each file for best settings (VMAF)", target: nil, action: nil)

    private let concurrency = NSStepper()
    private let concurrencyLabel = NSTextField(labelWithString: "1")
    private let keepAudio = NSButton(checkboxWithTitle: "Keep all audio tracks", target: nil, action: nil)
    private let keepSubtitles = NSButton(checkboxWithTitle: "Keep subtitles", target: nil, action: nil)
    private let keepChapters = NSButton(checkboxWithTitle: "Keep chapters", target: nil, action: nil)
    private let deleteSource = NSButton(checkboxWithTitle: "Delete source after successful conversion", target: nil, action: nil)
    private let preserveDates = NSButton(checkboxWithTitle: "Preserve file creation and modification dates", target: nil, action: nil)
    private let extraArguments = NSTextField(string: "")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 356),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        self.init(window: window)
        window.delegate = self
        window.contentView = buildTabs()
        loadFromStore()
    }

    // MARK: - Layout

    private func buildTabs() -> NSView {
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false

        for (title, content) in [
            ("General", generalTab()),
            ("Quality", qualityTab()),
            ("Advanced", advancedTab()),
        ] {
            let item = NSTabViewItem()
            item.label = title
            item.view = content
            tabs.addTabViewItem(item)
        }

        let credit = developerCredit()

        let container = NSView()
        container.addSubview(tabs)
        container.addSubview(credit)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            tabs.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            tabs.bottomAnchor.constraint(equalTo: credit.topAnchor, constant: -6),

            credit.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            credit.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            credit.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }

    /// A single quiet line under the tabs — the only "about" this app has.
    private func developerCredit() -> NSView {
        let text = NSMutableAttributedString(
            string: "Developed by Wasim Osman",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        )
        let nameRange = (text.string as NSString).range(of: "Wasim Osman")
        text.addAttributes([
            .link: URL(string: "https://github.com/wasim-osman")!,
            .foregroundColor: NSColor.linkColor,
        ], range: nameRange)

        let field = NSTextField(labelWithAttributedString: text)
        field.isSelectable = true
        field.allowsEditingTextAttributes = true
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func generalTab() -> NSView {
        outputLocation.addItems(withTitles: ["Same folder as source", "Choose a folder…", "Ask each time"])
        outputLocation.target = self
        outputLocation.action = #selector(outputLocationChanged)

        folderLabel.font = .systemFont(ofSize: 11)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle

        let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        chooseButton.bezelStyle = .rounded

        let folderRow = NSStackView(views: [folderLabel, chooseButton])
        folderRow.orientation = .horizontal
        folderRow.spacing = 8

        suffixField.target = self
        suffixField.action = #selector(commitFields)
        suffixField.placeholderString = "_optimized"

        conflictPolicy.addItems(withTitles: ["Overwrite", "Add a number", "Skip"])
        conflictPolicy.target = self
        conflictPolicy.action = #selector(commitFields)

        return grid([
            ("Save output to:", outputLocation),
            ("", folderRow),
            ("Filename suffix:", suffixField),
            ("If output exists:", conflictPolicy),
        ])
    }

    private func qualityTab() -> NSView {
        resolution.addItems(withTitles: ["Same as source", "2160p", "1440p", "1080p", "720p", "480p"])
        resolution.target = self
        resolution.action = #selector(commitFields)

        encoderMode.target = self
        encoderMode.action = #selector(commitFields)

        codec.addItems(withTitles: ["Auto (HEVC)", "H.264", "HEVC", "AV1"])
        codec.target = self
        codec.action = #selector(commitFields)

        qualityOffset.numberOfTickMarks = 7
        qualityOffset.allowsTickMarkValuesOnly = true
        qualityOffset.target = self
        qualityOffset.action = #selector(qualityOffsetChanged)

        let offsetCaption = NSTextField(labelWithString: "Smaller ←→ Higher quality")
        offsetCaption.font = .systemFont(ofSize: 10)
        offsetCaption.textColor = .tertiaryLabelColor

        let offsetRow = NSStackView(views: [qualityOffset, qualityOffsetLabel])
        offsetRow.orientation = .horizontal
        offsetRow.spacing = 8
        qualityOffset.widthAnchor.constraint(equalToConstant: 170).isActive = true

        useHardware.target = self
        useHardware.action = #selector(commitFields)
        useHardware.toolTip = "Encodes with the VideoToolbox HEVC hardware encoder on Apple silicon — roughly 5× faster than software, at the cost of larger files."

        analyseVMAF.target = self
        analyseVMAF.action = #selector(commitFields)
        analyseVMAF.isEnabled = false
        analyseVMAF.toolTip = "Ships in v1.2"

        return grid([
            ("Output resolution:", resolution),
            ("Encoder mode:", encoderMode),
            ("Codec:", codec),
            ("", useHardware),
            ("Quality offset:", offsetRow),
            ("", offsetCaption),
            ("", analyseVMAF),
        ])
    }

    private func advancedTab() -> NSView {
        concurrency.minValue = 1
        concurrency.maxValue = 8
        concurrency.increment = 1
        concurrency.valueWraps = false
        concurrency.target = self
        concurrency.action = #selector(concurrencyChanged)

        let concurrencyRow = NSStackView(views: [concurrencyLabel, concurrency])
        concurrencyRow.orientation = .horizontal
        concurrencyRow.spacing = 6

        let restartNote = NSTextField(labelWithString: "Applies to files dropped from now on.")
        restartNote.font = .systemFont(ofSize: 10)
        restartNote.textColor = .tertiaryLabelColor

        for box in [keepAudio, keepSubtitles, keepChapters, preserveDates] {
            box.target = self
            box.action = #selector(commitFields)
        }
        deleteSource.target = self
        deleteSource.action = #selector(deleteSourceToggled)

        extraArguments.target = self
        extraArguments.action = #selector(commitFields)
        extraArguments.placeholderString = "Extra ffmpeg arguments"

        return grid([
            ("Concurrent jobs:", concurrencyRow),
            ("", restartNote),
            ("", keepAudio),
            ("", keepSubtitles),
            ("", keepChapters),
            ("", preserveDates),
            ("", deleteSource),
            ("Extra arguments:", extraArguments),
        ])
    }

    private func grid(_ rows: [(String, NSView)]) -> NSView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing

        for (title, control) in rows {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            grid.addRow(with: [label, control])
        }

        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -18),
        ])
        return container
    }

    // MARK: - Store ⇄ controls

    private func loadFromStore() {
        let s = store.settings
        outputLocation.selectItem(at: [.sameAsSource, .chooseFolder, .askEachTime].firstIndex(of: s.outputLocation) ?? 0)
        folderLabel.stringValue = s.chosenFolderPath.isEmpty ? "No folder chosen" : s.chosenFolderPath
        suffixField.stringValue = s.suffix
        conflictPolicy.selectItem(at: [.overwrite, .numberIt, .skip].firstIndex(of: s.conflictPolicy) ?? 0)

        resolution.selectItem(at: [.source, .p2160, .p1440, .p1080, .p720, .p480].firstIndex(of: s.outputResolution) ?? 0)
        encoderMode.selectedSegment = [.fast, .balanced, .smallest].firstIndex(of: s.encoderMode) ?? 1
        codec.selectItem(at: [.auto, .h264, .hevc, .av1].firstIndex(of: s.codecChoice) ?? 0)
        qualityOffset.doubleValue = Double(s.qualityOffset)
        qualityOffsetLabel.stringValue = offsetText(s.qualityOffset)
        useHardware.state = s.useHardwareEncoder ? .on : .off
        analyseVMAF.state = s.analyseForBestSettings ? .on : .off

        concurrency.integerValue = s.concurrency
        concurrencyLabel.stringValue = "\(s.concurrency)"
        keepAudio.state = s.keepAudio ? .on : .off
        keepSubtitles.state = s.keepSubtitles ? .on : .off
        keepChapters.state = s.keepChapters ? .on : .off
        deleteSource.state = s.deleteSource ? .on : .off
        preserveDates.state = s.preserveDates ? .on : .off
        extraArguments.stringValue = s.extraArguments

        updateFolderRowEnabled()
    }

    @objc private func commitFields() {
        store.update { s in
            s.outputLocation = [.sameAsSource, .chooseFolder, .askEachTime][outputLocation.indexOfSelectedItem]
            s.suffix = suffixField.stringValue.isEmpty ? "_optimized" : suffixField.stringValue
            s.conflictPolicy = [.overwrite, .numberIt, .skip][conflictPolicy.indexOfSelectedItem]

            s.outputResolution = [.source, .p2160, .p1440, .p1080, .p720, .p480][resolution.indexOfSelectedItem]
            s.encoderMode = [.fast, .balanced, .smallest][encoderMode.selectedSegment]
            s.codecChoice = [.auto, .h264, .hevc, .av1][codec.indexOfSelectedItem]
            s.qualityOffset = Int(qualityOffset.doubleValue.rounded())
            s.useHardwareEncoder = useHardware.state == .on
            s.analyseForBestSettings = analyseVMAF.state == .on

            s.concurrency = concurrency.integerValue
            s.keepAudio = keepAudio.state == .on
            s.keepSubtitles = keepSubtitles.state == .on
            s.keepChapters = keepChapters.state == .on
            s.deleteSource = deleteSource.state == .on
            s.preserveDates = preserveDates.state == .on
            s.extraArguments = extraArguments.stringValue
        }
    }

    @objc private func outputLocationChanged() {
        commitFields()
        updateFolderRowEnabled()
        if store.settings.outputLocation == .chooseFolder && store.settings.chosenFolderPath.isEmpty {
            chooseFolder()
        }
    }

    private func updateFolderRowEnabled() {
        let needsFolder = store.settings.outputLocation == .chooseFolder
        folderLabel.textColor = needsFolder ? .secondaryLabelColor : .tertiaryLabelColor
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.update { $0.chosenFolderPath = url.path }
        folderLabel.stringValue = url.path
    }

    @objc private func qualityOffsetChanged() {
        let value = Int(qualityOffset.doubleValue.rounded())
        qualityOffsetLabel.stringValue = offsetText(value)
        commitFields()
    }

    private func offsetText(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    @objc private func concurrencyChanged() {
        concurrencyLabel.stringValue = "\(concurrency.integerValue)"
        commitFields()
    }

    /// Destructive, so it confirms once on enable (spec §5.2).
    @objc private func deleteSourceToggled() {
        guard deleteSource.state == .on else {
            commitFields()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete source files after conversion?"
        alert.informativeText = "Originals are removed permanently — they do not go to the Trash. This only happens after a conversion succeeds."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Sources")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() != .alertFirstButtonReturn {
            deleteSource.state = .off
        }
        commitFields()
    }
}
