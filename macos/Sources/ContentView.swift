import SwiftUI

// MARK: - View model

@MainActor
class ScannerModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var scanning = false
    @Published var scanProgress: Double = 0
    @Published var lastScan: Date?
    @Published var tailscaleWarning: String?
    private var queuedScan = false
    private var retryTask: Task<Void, Never>?
    @Published var showAllPorts = false {
        didSet { UserDefaults.standard.set(showAllPorts, forKey: "showAllPorts") }
    }
    @Published var showAllDevices = false {
        didSet { UserDefaults.standard.set(showAllDevices, forKey: "showAllDevices") }
    }
    @Published var minimalMode = true {
        didSet { UserDefaults.standard.set(minimalMode, forKey: "minimalMode") }
    }

    init() {
        showAllPorts = UserDefaults.standard.bool(forKey: "showAllPorts")
        showAllDevices = UserDefaults.standard.bool(forKey: "showAllDevices")
        if UserDefaults.standard.object(forKey: "minimalMode") == nil {
            minimalMode = true
        } else {
            minimalMode = UserDefaults.standard.bool(forKey: "minimalMode")
        }
    }

    func scan(retryAttempts: Int = 2) {
        if scanning {
            queuedScan = true
            return
        }
        retryTask?.cancel()
        retryTask = nil
        scanning = true
        scanProgress = 0
        tailscaleWarning = nil
        Task {
            let result = await Scanner.scanAll(showAll: showAllPorts) { progress in
                Task { @MainActor in self.scanProgress = progress }
            }
            self.devices = result.devices
            self.tailscaleWarning = result.tailscaleWarning
            self.lastScan = Date()
            self.scanProgress = 1
            self.scanning = false
            if self.queuedScan {
                self.queuedScan = false
                self.scan(retryAttempts: retryAttempts)
            } else if result.tailscaleWarning != nil && retryAttempts > 0 {
                self.scheduleRetry(retryAttempts: retryAttempts - 1)
            }
        }
    }

    private func scheduleRetry(retryAttempts: Int) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.scanning, self.tailscaleWarning != nil else { return }
                self.scan(retryAttempts: retryAttempts)
            }
        }
    }
}

// MARK: - Root view

struct ContentView: View {
    @EnvironmentObject private var model: ScannerModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if model.scanning {
                ProgressView(value: model.scanProgress)
                    .tint(.accentColor)
                    .frame(height: 2)
            } else {
                Divider()
            }
            if showSettings {
                settingsView
            } else {
                scrollContent
            }
            Divider()
            footerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            model.scan()
        }
    }

    // MARK: Header

    var headerBar: some View {
        HStack {
            Text("Web Finder")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            HoverButton {
                withAnimation(.easeInOut(duration: 0.15)) { showSettings.toggle() }
            } label: {
                Image(systemName: showSettings ? "xmark" : "gearshape")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            if model.scanning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else {
                HoverButton {
                    model.scan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Settings

    var settingsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            settingsRow(title: "Minimal mode",
                        subtitle: "Hide port numbers and IP addresses",
                        isOn: $model.minimalMode)

            settingsRow(title: "Show non-web ports",
                        subtitle: "AirPlay, SSH, and ports without a web page",
                        isOn: $model.showAllPorts)
                .onChange(of: model.showAllPorts) { _ in model.scan() }

            settingsRow(title: "Show all devices",
                        subtitle: "Include devices with no web services",
                        isOn: $model.showAllDevices)

            Spacer()

            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "\u{2014}")")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func settingsRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    // MARK: Content

    var activeDevices: [Device] {
        model.devices.filter { $0.online && !$0.services.isEmpty }
    }

    var inactiveDevices: [Device] {
        model.devices.filter { !$0.online || $0.services.isEmpty }
    }

    var scrollContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if let warning = model.tailscaleWarning {
                    TailscaleWarningView(message: warning)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }

                let visible = model.showAllDevices ? model.devices : activeDevices
                if visible.isEmpty && !model.scanning {
                    Text(model.tailscaleWarning == nil ? "No devices found" : "No web services found")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(visible) { device in
                        DeviceSection(device: device, minimal: model.minimalMode)
                        if device.id != visible.last?.id {
                            Divider().padding(.horizontal, 10)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    var footerBar: some View {
        HStack {
            HoverButton {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let ts = model.lastScan {
                Text(ts, style: .time)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(.tertiaryLabelColor))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Tailscale warning

struct TailscaleWarningView: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.orange)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Device section

struct DeviceSection: View {
    let device: Device
    let minimal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            deviceHeader
            serviceList
        }
    }

    var deviceHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: device.sfIcon)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(device.online ? Color.accentColor.opacity(0.8) : .secondary)
            Text(device.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(device.online ? .primary : .secondary)
                .tracking(0.2)
            if !device.online {
                Text("offline")
                    .font(.system(size: 9))
                    .foregroundColor(Color(.tertiaryLabelColor))
            }
            if device.isLocal {
                Text("this mac")
                    .font(.system(size: 9))
                    .foregroundColor(Color(.tertiaryLabelColor))
            }
            Spacer()
            if !minimal {
                Text(device.ip)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(.tertiaryLabelColor))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 5)
    }

    @ViewBuilder
    var serviceList: some View {
        if !device.online {
            EmptyView()
        } else if device.services.isEmpty {
            Text("No web services")
                .font(.system(size: 11))
                .foregroundColor(Color(.tertiaryLabelColor))
                .padding(.leading, 24)
                .padding(.bottom, 8)
        } else {
            ForEach(device.services) { service in
                ServiceRow(service: service, minimal: minimal)
            }
            .padding(.bottom, 4)
        }
    }
}

// MARK: - Service row

struct ServiceRow: View {
    let service: WebService
    let minimal: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
                .padding(.leading, 8)

            Text(service.title)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer()

            if !minimal {
                Text(":\(service.port)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Button {
                NSWorkspace.shared.open(service.url)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 13))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(hovered ? Color(.selectedControlColor).opacity(0.3) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 8)
        .onHover { hovered = $0 }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(service.url.absoluteString, forType: .string)
            }
            Button("Open in Browser") {
                NSWorkspace.shared.open(service.url)
            }
        }
    }
}

// MARK: - Hover button

struct HoverButton<Label: View>: View {
    let action: () -> Void
    let label: () -> Label
    @State private var hovered = false

    init(action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(hovered ? Color(.selectedControlColor).opacity(0.3) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
