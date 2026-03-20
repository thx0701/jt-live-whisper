import Cocoa

class SubtitleWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: SubtitleWindow!
    var enLabel: NSTextField!
    var zhLabel: NSTextField!
    var logPath: String = ""
    var fileOffset: UInt64 = 0
    var lastEN: String = ""
    var lastZH: String = ""
    var isDragging = false
    var dragOrigin: NSPoint = .zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Find latest log file
        logPath = findLatestLog()
        if logPath.isEmpty {
            print("No log file found in logs/. Start jt-live-whisper first.")
            NSApp.terminate(nil)
            return
        }
        print("Watching: \(logPath)")

        // Seek to end of file
        if let fh = FileHandle(forReadingAtPath: logPath) {
            fileOffset = fh.seekToEndOfFile()
            fh.closeFile()
        }

        // Create overlay window
        let screenFrame = NSScreen.main!.frame
        let w: CGFloat = min(screenFrame.width * 0.7, 1000)
        let h: CGFloat = 90
        let x = (screenFrame.width - w) / 2
        let y: CGFloat = 60

        window = SubtitleWindow(
            contentRect: NSRect(x: x, y: y, width: w, height: h),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(Int(CGShieldingWindowLevel()) + 1)
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = true

        // Content view
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 12

        // EN label (top, smaller, dimmer)
        enLabel = makeLabel(frame: NSRect(x: 16, y: 44, width: w - 32, height: 34),
                           fontSize: 16, color: NSColor.white.withAlphaComponent(0.7))
        contentView.addSubview(enLabel)

        // ZH label (bottom, bigger, bright)
        zhLabel = makeLabel(frame: NSRect(x: 16, y: 8, width: w - 32, height: 38),
                           fontSize: 22, color: NSColor(calibratedRed: 0.4, green: 1.0, blue: 0.7, alpha: 1.0))
        zhLabel.font = NSFont.boldSystemFont(ofSize: 22)
        contentView.addSubview(zhLabel)

        window.contentView = contentView
        window.orderFrontRegardless()

        // Poll log file every 0.3s
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkLog()
        }
    }

    func makeLabel(frame: NSRect, fontSize: CGFloat, color: NSColor) -> NSTextField {
        let label = NSTextField(frame: frame)
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.textColor = color
        label.font = NSFont.systemFont(ofSize: fontSize)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        return label
    }

    func findLatestLog() -> String {
        let logsDir = ProcessInfo.processInfo.environment["SUBTITLE_LOG_DIR"]
            ?? (FileManager.default.currentDirectoryPath + "/logs")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: logsDir) else { return "" }
        let txts = files.filter { $0.hasSuffix(".txt") && $0.contains("逐字稿") }.sorted()
        guard let latest = txts.last else { return "" }
        return logsDir + "/" + latest
    }

    func checkLog() {
        guard let fh = FileHandle(forReadingAtPath: logPath) else { return }
        fh.seek(toFileOffset: fileOffset)
        let data = fh.readDataToEndOfFile()
        let newOffset = fh.offsetInFile
        fh.closeFile()

        guard data.count > 0, let text = String(data: data, encoding: .utf8) else { return }
        fileOffset = newOffset

        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("[EN]") {
                lastEN = extractText(trimmed, tag: "[EN]")
            } else if trimmed.contains("[中]") {
                lastZH = extractText(trimmed, tag: "[中]")
                updateLabels()
            }
        }
    }

    func extractText(_ line: String, tag: String) -> String {
        guard let range = line.range(of: tag) else { return line }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    func updateLabels() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.enLabel.stringValue = self.lastEN
            self.zhLabel.stringValue = self.lastZH
        }
    }
}

// Main
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // No dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
