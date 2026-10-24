import AppKit

// 不抢焦点的状态条。文字仍写入当前输入框，这里只提示是否在听。
final class FloatingStatusController {
    private let model: AppModel
    private let panel: StatusPanel
    private let pill = PillView()
    private let titleField = NSTextField(labelWithString: "")
    private let lineField = TailLabel()
    private let bars = WaveBars()
    private var pulse: Timer?
    private var hideItem: DispatchWorkItem?
    private var keepFront: Timer?
    private var visible = false
    private let shadowInset: CGFloat = 18

    init(model: AppModel) {
        self.model = model
        panel = StatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false

        let container = NSView(frame: panel.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        panel.contentView = container
        container.addSubview(pill)

        configure(titleField, size: 13, weight: .semibold, alpha: 0.96)
        lineField.font = .systemFont(ofSize: 12, weight: .regular)
        lineField.textColor = NSColor.white.withAlphaComponent(0.72)
        pill.addSubview(bars)
        pill.addSubview(titleField)
        pill.addSubview(lineField)
    }

    func refresh() {
        let short = model.statusShort
        if short == "空闲" || short == "已停止" {
            hideNow(animated: false)
            return
        }
        let pulsing = short == "录音" || short == "启动"
        show(title: Self.title(for: short), subtitle: subtitle(for: short), pulsing: pulsing, tint: Self.tint(for: short))
        if Self.sticky.contains(short) {
            hideItem?.cancel()
            hideItem = nil
        } else {
            scheduleHide()
        }
    }

    private func subtitle(for short: String) -> String {
        if !model.overlayText.isEmpty {
            return model.overlayText
        }
        let detail = model.statusDetail
        if detail.isEmpty || detail == short || detail == Self.title(for: short) {
            return ""
        }
        return detail
    }

    private func show(title: String, subtitle: String, pulsing: Bool, tint: NSColor) {
        titleField.stringValue = title
        lineField.isHidden = subtitle.isEmpty
        bars.tint = tint
        bars.active = pulsing
        let visual = layout(title: title, subtitle: subtitle)
        place(visual: visual)
        bars.needsDisplay = true
        if pulsing {
            startPulse()
        } else {
            stopPulse()
        }
        reveal()
    }

    private func reveal() {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        panel.alphaValue = 1
        NSAnimationContext.endGrouping()
        panel.orderFrontRegardless()
        visible = true
        startKeepFront()
    }

    private func startKeepFront() {
        guard keepFront == nil else { return }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self, self.visible else { return }
            if !self.panel.isVisible || self.panel.alphaValue < 0.9 {
                self.panel.alphaValue = 1
                self.panel.orderFrontRegardless()
            }
        }
        keepFront = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func layout(title: String, subtitle: String) -> CGSize {
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let lineFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let titleWidth = measure(title, font: titleFont)
        let lineWidth = subtitle.isEmpty ? 0 : measure(subtitle, font: lineFont)
        let textWidth = min(300, max(titleWidth, lineWidth))
        let width = 14 + 18 + 10 + textWidth + 14
        let height: CGFloat = subtitle.isEmpty ? 36 : 50
        let textX: CGFloat = 42
        bars.frame = NSRect(x: 14, y: (height - 16) / 2, width: 18, height: 16)
        if subtitle.isEmpty {
            titleField.frame = NSRect(x: textX, y: (height - 16) / 2, width: textWidth, height: 16)
        } else {
            titleField.frame = NSRect(x: textX, y: height - 22, width: textWidth, height: 16)
            lineField.frame = NSRect(x: textX, y: 8, width: textWidth, height: 15)
            lineField.setText(subtitle)
        }
        pill.frame = NSRect(x: shadowInset, y: shadowInset, width: width, height: height)
        pill.update(radius: height / 2, tint: bars.tint)
        return CGSize(width: width, height: height)
    }

    private func place(visual: CGSize) {
        let anchor = model.focusRect
        let screen = screen(for: anchor) ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        var pillX = visibleFrame.midX - visual.width / 2
        var pillY = visibleFrame.maxY - visual.height - 8
        if let anchor {
            pillX = anchor.minX
            pillY = anchor.maxY + 8
            if pillY + visual.height > visibleFrame.maxY - 4 {
                pillY = anchor.minY - visual.height - 8
            }
        } else {
            let mouse = NSEvent.mouseLocation
            pillX = mouse.x - visual.width / 2
            pillY = mouse.y + 18
        }
        pillX = min(max(pillX, visibleFrame.minX + 8), visibleFrame.maxX - visual.width - 8)
        pillY = min(max(pillY, visibleFrame.minY + 8), visibleFrame.maxY - visual.height - 8)
        panel.setFrame(
            NSRect(
                x: pillX - shadowInset,
                y: pillY - shadowInset,
                width: visual.width + shadowInset * 2,
                height: visual.height + shadowInset * 2
            ),
            display: true
        )
    }

    private func screen(for rect: CGRect?) -> NSScreen? {
        guard let rect else { return nil }
        return NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
    }

    private func scheduleHide() {
        hideItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hideNow()
        }
        hideItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }

    private func hideNow(animated: Bool = true) {
        hideItem?.cancel()
        hideItem = nil
        stopPulse()
        stopKeepFront()
        lineField.setText("")
        guard visible else { return }
        visible = false
        guard animated else {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.visible else { return }
            self.panel.orderOut(nil)
        })
    }

    private func startPulse() {
        guard pulse == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.bars.phase += 0.28
            self.bars.needsDisplay = true
        }
        pulse = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPulse() {
        pulse?.invalidate()
        pulse = nil
        bars.active = false
        bars.needsDisplay = true
    }

    private func stopKeepFront() {
        keepFront?.invalidate()
        keepFront = nil
    }

    private func configure(_ field: NSTextField, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = NSColor.white.withAlphaComponent(alpha)
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.drawsBackground = false
        field.isBezeled = false
        field.isBordered = false
        field.isEditable = false
        field.isSelectable = false
        field.backgroundColor = .clear
    }

    private func measure(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static let sticky: Set<String> = ["启动", "录音", "收尾", "请稍后"]

    private static func title(for short: String) -> String {
        switch short {
        case "录音": return "正在听"
        case "启动": return "准备中"
        case "收尾": return "识别中"
        case "请稍后": return "请稍等"
        default: return short
        }
    }

    private static func tint(for short: String) -> NSColor {
        switch short {
        case "已输入", "已完成":
            return NSColor(srgbRed: 0.45, green: 0.86, blue: 0.62, alpha: 1)
        case "已停止", "无法输入", "识别失败", "连接超时", "无权限", "无麦克风", "无密钥", "无辅助功能", "无输入监控", "麦克风失败":
            return NSColor(srgbRed: 0.98, green: 0.62, blue: 0.42, alpha: 1)
        default:
            return NSColor(srgbRed: 0.62, green: 0.90, blue: 0.96, alpha: 1)
        }
    }
}

private final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PillView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(radius: CGFloat, tint: NSColor) {
        layer?.cornerRadius = radius
        layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.12, blue: 0.15, alpha: 0.94).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = tint.withAlphaComponent(0.28).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.32
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)
    }
}

private final class TailLabel: NSView {
    var font = NSFont.systemFont(ofSize: 12)
    var textColor = NSColor.white.withAlphaComponent(0.72)
    private var text = ""
    private var offset: CGFloat = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setText(_ text: String) {
        guard text != self.text else { return }
        self.text = text
        if text.isEmpty {
            offset = 0
            timer?.invalidate()
            timer = nil
            needsDisplay = true
            return
        }
        if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        needsDisplay = true
    }

    private func tick() {
        let target = targetOffset()
        let delta = target - offset
        if abs(delta) < 0.4 {
            offset = target
            timer?.invalidate()
            timer = nil
        } else {
            offset += delta * 0.28
        }
        needsDisplay = true
    }

    private func targetOffset() -> CGFloat {
        min(0, bounds.width - measuredWidth())
    }

    private func measuredWidth() -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty, bounds.width > 0 else { return }
        let size = (text as NSString).size(withAttributes: [.font: font])
        let y = (bounds.height - size.height) / 2
        (text as NSString).draw(at: NSPoint(x: offset, y: y), withAttributes: [
            .font: font,
            .foregroundColor: textColor
        ])
    }
}

private final class WaveBars: NSView {
    var phase: CGFloat = 0
    var active = false
    var tint: NSColor = NSColor(srgbRed: 0.62, green: 0.90, blue: 0.96, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        tint.setFill()
        let count = 5
        let gap: CGFloat = 2
        let barW: CGFloat = 2
        let mid = bounds.midY
        let pattern: [CGFloat] = [0.42, 0.72, 1, 0.62, 0.34]
        for index in 0..<count {
            let wave = active ? 0.45 + 0.55 * abs(sin(phase + CGFloat(index) * 0.7)) : 0.55
            let height = max(3, bounds.height * pattern[index] * wave)
            let x = CGFloat(index) * (barW + gap)
            NSBezierPath(
                roundedRect: NSRect(x: x, y: mid - height / 2, width: barW, height: height),
                xRadius: 1,
                yRadius: 1
            ).fill()
        }
    }
}
