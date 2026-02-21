import SwiftUI

// MARK: - View model

@MainActor
class ScannerModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var scanning = false
    @Published var lastScan: Date?
    @Published var showAllPorts = false {
        didSet { UserDefaults.standard.set(showAllPorts, forKey: "showAllPorts") }
    }
    @Published var showAllDevices = false {
        didSet { UserDefaults.standard.set(showAllDevices, forKey: "showAllDevices") }
    }

    init() {
        showAllPorts = UserDefaults.standard.bool(forKey: "showAllPorts")
        showAllDevices = UserDefaults.standard.bool(forKey: "showAllDevices")
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            let result = await Scanner.scanAll(showAll: showAllPorts)
            self.devices = result
            self.lastScan = Date()
            self.scanning = false
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
            Divider()
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
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
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

            Toggle(isOn: $model.showAllPorts) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show non-web ports")
                        .font(.system(size: 12))
                    Text("AirPlay, SSH, and ports without a web page")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: model.showAllPorts) { _ in
                model.scan()
            }

            Toggle(isOn: $model.showAllDevices) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show all devices")
                        .font(.system(size: 12))
                    Text("Include devices with no web services")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Spacer()

            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Content

    var activeDevices: [Device] {
        model.devices.filter { $0.online && !$0.services.isEmpty }
    }

    var inactiveDevices: [Device] {
        model.devices.filter { !$0.online || $0.services.isEmpty }
    }

    var scrollContent: some View {
        ScrollView {
            if model.devices.isEmpty && !model.scanning {
                Text("No devices found")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(16)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    let visible = model.showAllDevices ? model.devices : activeDevices
                    ForEach(visible) { device in
                        DeviceSection(device: device)
                        if device.id != visible.last?.id {
                            Divider().padding(.horizontal, 10)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
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

// MARK: - Device section

struct DeviceSection: View {
    let device: Device

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
            Text(device.ip)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Color(.tertiaryLabelColor))
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
                ServiceRow(service: service)
            }
            .padding(.bottom, 4)
        }
    }
}

// MARK: - Service row

struct ServiceRow: View {
    let service: WebService
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

            Text(":\(service.port)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)

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
