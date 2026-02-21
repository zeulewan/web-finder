import SwiftUI

// MARK: - View model

@MainActor
class ScannerModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var scanning = false
    @Published var lastScan: Date?
    @Published var scanError: String?
    @Published var showAllPorts = false {
        didSet { UserDefaults.standard.set(showAllPorts, forKey: "showAllPorts") }
    }
    @Published var showAllDevices = false {
        didSet { UserDefaults.standard.set(showAllDevices, forKey: "showAllDevices") }
    }

    var needsSetup: Bool { scanError == "NO_CREDENTIALS" }
    var invalidCreds: Bool { scanError == "INVALID_CREDENTIALS" }
    var isConfigured: Bool {
        let id = UserDefaults.standard.string(forKey: "tsClientID") ?? ""
        let secret = UserDefaults.standard.string(forKey: "tsClientSecret") ?? ""
        return !id.isEmpty && !secret.isEmpty
    }

    init() {
        showAllPorts = UserDefaults.standard.bool(forKey: "showAllPorts")
        showAllDevices = UserDefaults.standard.bool(forKey: "showAllDevices")
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            let (result, error) = await Scanner.scanAll(showAll: showAllPorts)
            self.devices = result
            self.scanError = error
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
        NavigationStack {
            Group {
                if model.needsSetup || model.invalidCreds {
                    SetupView()
                } else {
                    deviceList
                }
            }
            .navigationTitle("Web Finder")
            .toolbar {
                if model.isConfigured {
                    ToolbarItem(placement: .topBarTrailing) {
                        if model.scanning {
                            ProgressView()
                        } else {
                            Button { model.scan() } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
            .refreshable {
                await withCheckedContinuation { continuation in
                    model.scan()
                    Task {
                        while model.scanning {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        }
                        continuation.resume()
                    }
                }
            }
            .onAppear { model.scan() }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    var deviceList: some View {
        List {
            if let error = model.scanError {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else if model.devices.isEmpty && !model.scanning {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "network.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No Devices Found")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
            } else {
                let visible = model.showAllDevices ? model.devices : activeDevices
                ForEach(visible) { device in
                    DeviceSection(device: device)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    var activeDevices: [Device] {
        model.devices.filter { $0.online && !$0.services.isEmpty }
    }
}

// MARK: - Setup / onboarding

struct SetupView: View {
    @EnvironmentObject private var model: ScannerModel
    @State private var clientID = ""
    @State private var clientSecret = ""
    @Environment(\.openURL) private var openURL

    static let oauthURL = URL(string: "https://login.tailscale.com/admin/settings/trust-credentials/add")!

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "network")
                .font(.system(size: 40))
                .foregroundStyle(.accent)

            if model.invalidCreds {
                Text("Invalid Credentials")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                Text("Check your Client ID and Secret, or create a new OAuth client.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Connect to Tailscale")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                Text("One-time setup. Create an OAuth client to let Web Finder discover your devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 10) {
                stepRow(number: "1", text: "Tap below to open Tailscale OAuth settings")
                stepRow(number: "2", text: "Under Scopes, expand Devices and check Core: Read")
                stepRow(number: "3", text: "Hit Generate credential, then copy the Client ID and Secret below")
            }
            .padding(.horizontal)

            Button {
                openURL(Self.oauthURL)
            } label: {
                Label("Open Tailscale OAuth", systemImage: "arrow.up.right")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            VStack(spacing: 10) {
                HStack {
                    Text(clientID.isEmpty ? "Client ID" : clientID)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(clientID.isEmpty ? .tertiary : .primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)

                    Button {
                        if let str = UIPasteboard.general.string {
                            clientID = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.body)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                HStack {
                    Text(clientSecret.isEmpty ? "Client Secret" : String(repeating: "\u{2022}", count: min(clientSecret.count, 20)))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(clientSecret.isEmpty ? .tertiary : .primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)

                    Button {
                        if let str = UIPasteboard.general.string {
                            clientSecret = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.body)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                Button {
                    saveAndScan()
                } label: {
                    Text("Connect")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty ||
                          clientSecret.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.horizontal)
            }

            Spacer()
        }
        .padding()
    }

    func stepRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor)
                .clipShape(Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    func saveAndScan() {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { return }
        UserDefaults.standard.set(id, forKey: "tsClientID")
        UserDefaults.standard.set(secret, forKey: "tsClientSecret")
        model.scan()
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var model: ScannerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("tsClientID") private var clientID = ""
    @AppStorage("tsClientSecret") private var clientSecret = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Client ID", text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))

                    SecureField("Client Secret", text: $clientSecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))

                    Button("Open Tailscale OAuth") {
                        openURL(SetupView.oauthURL)
                    }
                } header: {
                    Text("Tailscale")
                } footer: {
                    Text("OAuth client credentials. Never expires.")
                }

                Section {
                    Toggle(isOn: $model.showAllPorts) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show non-web ports")
                            Text("AirPlay, SSH, and ports without a web page")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: model.showAllPorts) { _ in
                        model.scan()
                    }

                    Toggle(isOn: $model.showAllDevices) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show all devices")
                            Text("Include devices with no web services")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Filtering")
                }

                if let ts = model.lastScan {
                    Section {
                        LabeledContent("Last scan") {
                            Text(ts, style: .time)
                                .monospacedDigit()
                        }
                    }
                }

                Section {
                    LabeledContent("Version") {
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        UserDefaults.standard.removeObject(forKey: "tsClientID")
                        UserDefaults.standard.removeObject(forKey: "tsClientSecret")
                        clientID = ""
                        clientSecret = ""
                        model.devices = []
                        model.lastScan = nil
                        model.scanError = "NO_CREDENTIALS"
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Log Out")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Device section

struct DeviceSection: View {
    let device: Device

    var body: some View {
        Section {
            if !device.online {
                Text("Offline")
                    .foregroundStyle(.tertiary)
            } else if device.services.isEmpty {
                Text("No web services")
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(device.services) { service in
                    ServiceRow(service: service)
                }
            }
        } header: {
            HStack(spacing: 5) {
                Image(systemName: device.sfIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(device.online ? Color.accentColor : .secondary)
                Text(device.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(device.online ? .primary : .secondary)
                if !device.online {
                    Text("offline")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Service row

struct ServiceRow: View {
    let service: WebService
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(service.url)
        } label: {
            HStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)

                Text(service.title)
                    .lineLimit(1)

                Spacer()

                Text(":\(service.port)")
                    .font(.footnote.monospaced())
                    .foregroundColor(.secondary)

                Image(systemName: "arrow.up.right.square")
                    .font(.footnote)
                    .foregroundColor(.accentColor)
            }
            .foregroundColor(.primary)
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = service.url.absoluteString
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }
            Button {
                openURL(service.url)
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
        }
    }
}
