import AppKit
import UniformTypeIdentifiers

// MARK: - Connect Menu

extension VPhoneMenuController {
    func buildConnectMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Connect")
        menu.addItem(makeItem("File Browser", action: #selector(openFiles)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Install IPA...", action: #selector(installIPAViaGuest)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Developer Mode Status", action: #selector(devModeStatus)))
        menu.addItem(makeItem("Enable Developer Mode [WIP]", action: #selector(devModeEnable)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Ping", action: #selector(sendPing)))
        menu.addItem(makeItem("Guest Version", action: #selector(queryGuestVersion)))
        item.submenu = menu
        return item
    }

    @objc func openFiles() {
        onFilesPressed?()
    }

    @objc func devModeStatus() {
        Task {
            do {
                let status = try await control.sendDevModeStatus()
                showAlert(
                    title: "Developer Mode",
                    message: status.enabled ? "Developer Mode is enabled." : "Developer Mode is disabled.",
                    style: .informational
                )
            } catch {
                showAlert(title: "Developer Mode", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func devModeEnable() {
        Task {
            do {
                let result = try await control.sendDevModeEnable()
                showAlert(
                    title: "Developer Mode",
                    message: result.message.isEmpty
                        ? (result.alreadyEnabled ? "Developer Mode already enabled." : "Developer Mode enabled.")
                        : result.message,
                    style: .informational
                )
            } catch {
                showAlert(title: "Developer Mode", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func sendPing() {
        Task {
            do {
                try await control.sendPing()
                showAlert(title: "Ping", message: "pong", style: .informational)
            } catch {
                showAlert(title: "Ping", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func queryGuestVersion() {
        Task {
            do {
                let hash = try await control.sendVersion()
                showAlert(title: "Guest Version", message: "build: \(hash)", style: .informational)
            } catch {
                showAlert(title: "Guest Version", message: "\(error)", style: .warning)
            }
        }
    }

    // MARK: - Install IPA (Guest)

    @objc func installIPAViaGuest() {
        let panel = NSOpenPanel()
        panel.title = "Select IPA to Install"
        panel.allowedContentTypes = [.init(filenameExtension: "ipa")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Find the menu item and disable it during install
        let menuItem = NSApp.mainMenu?
            .item(withTitle: "Connect")?
            .submenu?
            .item(withTitle: "Install IPA...")

        menuItem?.isEnabled = false

        Task {
            defer { menuItem?.isEnabled = true }

            let result = try await control.installApp(localPath: url.path)
            if let errorMessage = result.errorMessage {
                let stageInfo = result.failedStage.map { " (stage: \($0))" } ?? ""
                showAlert(
                    title: "Install IPA",
                    message: "Failed\(stageInfo): \(errorMessage)",
                    style: .warning
                )
            } else {
                let bundleInfo = result.bundleId ?? "unknown"
                showAlert(
                    title: "Install IPA",
                    message: "Installed successfully.\nBundle ID: \(bundleInfo)",
                    style: .informational
                )
            }
        }
    }

    // MARK: - Alert

    func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
