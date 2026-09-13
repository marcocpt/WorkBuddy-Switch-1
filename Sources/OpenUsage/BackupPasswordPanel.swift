import AppKit

/// 备份密码输入面板（独立可激活的 titled NSPanel）。
///
/// 相比 sheet：不依赖宿主窗口，先请求应用 activation（macOS 14+ 为
/// cooperative activation，请求可能不被批准），以 `NSApp.isActive` /
/// `didBecomeActiveNotification` 为门，active 后才 makeKeyAndOrderFront，
/// 下一 runloop 再 makeFirstResponder；activation 未获批准时窗口保持可见，
/// 提示用户点击一次密码框（accessory 应用允许通过点击自身窗口激活）。
@MainActor
final class BackupPasswordPanel: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private enum Mode {
        case export
        case `import`
    }

    private var panel: NSPanel?
    private var mode: Mode = .export
    private var passwordField: NSSecureTextField!
    private var confirmField: NSSecureTextField!
    private var hintLabel: NSTextField!
    private var confirmButton: NSButton!
    private var activationObserver: NSObjectProtocol?
    private var activationTimeout: Timer?
    private var onSubmit: ((String) -> Void)?
    private var onCancel: (() -> Void)?

    var isPresented: Bool { panel != nil }

    /// 导出：需输入两次一致且 ≥ 8 位的密码。
    func presentExport(
        onSubmit: @escaping (String) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        mode = .export
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        show()
    }

    /// 导入：只需输入一次密码。
    func presentImport(
        onSubmit: @escaping (String) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        mode = .import
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        show()
    }

    private func show() {
        guard panel == nil else {
            panel?.makeKeyAndOrderFront(nil)
            return
        }

        let isExport = mode == .export
        let height: CGFloat = isExport ? 230 : 160
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = isExport ? "导出全部账号" : "导入账号"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()

        panel.contentView = buildContent(isExport: isExport, height: height)
        panel.defaultButtonCell = confirmButton.cell as? NSButtonCell
        self.panel = panel

        panel.orderFrontRegardless()
        requestActivationAndFocus()
    }

    /// 请求应用 activation；被批准后 makeKey + 下一 runloop 聚焦密码框；
    /// 超时未批准则提示用户点击一次（accessory 应用点击自身窗口即可激活）。
    private func requestActivationAndFocus() {
        let focusPanel = { [weak self] in
            guard
                let self,
                let panel = self.panel,
                NSApp.isActive
            else { return }
            panel.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                guard let panel = self.panel, panel.isKeyWindow else { return }
                _ = panel.makeFirstResponder(self.passwordField)
            }
        }

        if NSApp.isActive {
            focusPanel()
            return
        }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.handleDidBecomeActive(focus: focusPanel)
        }

        activationTimeout = Timer.scheduledTimer(
            withTimeInterval: 0.4,
            repeats: false
        ) { [weak self] _ in
            self?.handleActivationTimeout()
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleDidBecomeActive(focus: () -> Void) {
        removeActivationObservers()
        focus()
    }

    private func handleActivationTimeout() {
        guard
            let panel,
            !NSApp.isActive
        else { return }
        removeActivationObservers()
        hintLabel.isHidden = false
        hintLabel.stringValue = "请点击密码框后输入。"
        panel.orderFrontRegardless()
    }

    private func removeActivationObservers() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        activationTimeout?.invalidate()
        activationTimeout = nil
    }

    /// 组装面板内容（控件创建与布局集中在此，keep show() 简洁）。
    private func buildContent(isExport: Bool, height: CGFloat) -> NSView {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: height))

        let titleLabel = NSTextField(labelWithString: isExport ? "导出全部账号" : "导入账号")
        titleLabel.font = .boldSystemFont(ofSize: 16)
        titleLabel.frame = NSRect(x: 24, y: height - 44, width: 392, height: 22)

        let subtitle = NSTextField(
            wrappingLabelWithString: isExport
                ? "备份文件将加密保存。请设置一个密码（至少 8 位）并再次确认。\n密码无法找回，请妥善保管。"
                : "请输入备份文件的密码："
        )
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 24, y: height - 74, width: 392, height: isExport ? 34 : 18)

        passwordField = NSSecureTextField(frame: NSRect(x: 24, y: height - 104, width: 392, height: 26))
        passwordField.placeholderString = isExport ? "密码（至少 8 位）" : "密码"
        passwordField.delegate = self

        confirmField = NSSecureTextField(frame: NSRect(x: 24, y: height - 136, width: 392, height: 26))
        confirmField.placeholderString = "确认密码"
        confirmField.delegate = self
        confirmField.isHidden = !isExport

        hintLabel = NSTextField(labelWithString: "")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .systemRed
        hintLabel.isHidden = true
        hintLabel.frame = NSRect(x: 24, y: height - 156, width: 392, height: 14)

        let buttonsView = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 36))
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 250, y: 4, width: 78, height: 28)

        confirmButton = NSButton(
            title: isExport ? "继续导出" : "导入",
            target: self,
            action: #selector(confirmTapped)
        )
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = "\r"
        confirmButton.isEnabled = false
        confirmButton.frame = NSRect(x: 336, y: 4, width: 84, height: 28)

        buttonsView.addSubview(cancelButton)
        buttonsView.addSubview(confirmButton)

        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitle)
        contentView.addSubview(passwordField)
        contentView.addSubview(confirmField)
        contentView.addSubview(hintLabel)
        contentView.addSubview(buttonsView)
        return contentView
    }

    // MARK: - NSWindowDelegate

    /// 标题栏红叉关闭统一进入 cancel teardown，避免 presenter 状态残留。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === panel else { return true }
        finishCancel()
        return false
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let isExport = mode == .export
        let password = passwordField.stringValue

        if isExport {
            let confirmed = confirmField.stringValue
            let validLength = password.count >= 8
            confirmButton.isEnabled = validLength && password == confirmed
            if field === confirmField || field === passwordField, !password.isEmpty, !confirmField.stringValue.isEmpty {
                if password != confirmed || !validLength {
                    hintLabel.stringValue = validLength ? "两次输入的密码不一致。" : "密码至少 8 位。"
                    hintLabel.isHidden = false
                } else {
                    hintLabel.isHidden = true
                }
            }
        } else {
            confirmButton.isEnabled = !password.isEmpty
        }
    }

    // MARK: - Actions

    @objc private func confirmTapped() {
        guard panel != nil else { return }
        let callback = onSubmit
        let password = passwordField.stringValue
        teardown()
        callback?(password)
    }

    @objc private func cancelTapped() {
        finishCancel()
    }

    private func finishCancel() {
        guard panel != nil else { return }
        let callback = onCancel
        teardown()
        callback?()
    }

    private func teardown() {
        removeActivationObservers()
        panel?.orderOut(nil)
        panel?.delegate = nil
        panel = nil
        onSubmit = nil
        onCancel = nil
    }
}
