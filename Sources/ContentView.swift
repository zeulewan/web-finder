import SwiftUI

// MARK: - View model

@MainActor
class ScannerModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var scanning = false
    @Published var lastScan: Date?

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            let result = await Scanner.scanAll()
            self.devices = result
            self.lastScan = Date()
            self.scanning = false
        }
    }
}

// MARK: - Root view

struct ContentView: View {
    @StateObject private var model = ScannerModel()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            scrollContent
            Divider()
            footerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            model.scan()
        }
        // Auto-refresh every 30s while popup is open
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            model.scan()
        }
    }

    // MARK: Header

    var headerBar: some View {
        HStack {
            Text("Web Scanner")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if model.scanning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else {
                Button { model.scan() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Content

    var scrollContent: some View {
        ScrollView {
            if model.devices.isEmpty && !model.scanning {
                Text("No devices found")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(16)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.devices) { device in
                        DeviceSection(device: device)
                        if device.id != model.devices.last?.id {
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
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
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
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 5)
    }

    @ViewBuilder
    var serviceList: some View {
        if !device.online {
            // Show nothing for offline devices (header says it all)
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
