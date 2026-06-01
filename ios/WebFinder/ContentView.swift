import SwiftUI
import SafariServices

enum AppBuild {
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    static let kind = Bundle.main.infoDictionary?["WFBuildKind"] as? String ?? ""
    static let label: String = {
        let base = "\(version) (\(build))"
        return kind.isEmpty || kind == "APPSTORE" ? base : "\(kind) \(base)"
    }()
}

// MARK: - Safari in-app browser

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

// MARK: - View model

@MainActor
class ScannerModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var scanning = false
    @Published var scanProgress: Double = 0
    @Published var lastScan: Date?
    @Published var scanError: String?
    @Published var demoMode = false
    @Published var showAllPorts = false {
        didSet { UserDefaults.standard.set(showAllPorts, forKey: "showAllPorts") }
    }
    @Published var showAllDevices = false {
        didSet { UserDefaults.standard.set(showAllDevices, forKey: "showAllDevices") }
    }
    @Published var debugMode = false {
        didSet { UserDefaults.standard.set(debugMode, forKey: "debugMode") }
    }
    @Published var minimalMode = true {
        didSet { UserDefaults.standard.set(minimalMode, forKey: "minimalMode") }
    }

    var needsSetup: Bool { scanError == "NO_CREDENTIALS" && !demoMode }
    var invalidCreds: Bool { scanError == "INVALID_CREDENTIALS" }
    var isConfigured: Bool {
        if demoMode { return true }
        let id = UserDefaults.standard.string(forKey: "tsClientID") ?? ""
        let secret = UserDefaults.standard.string(forKey: "tsClientSecret") ?? ""
        return !id.isEmpty && !secret.isEmpty
    }

    func loadDemo() {
        demoMode = true
        devices = Scanner.demoDevices()
        scanError = nil
        lastScan = Date()
        scanning = false
    }

    init() {
        showAllPorts = UserDefaults.standard.bool(forKey: "showAllPorts")
        showAllDevices = UserDefaults.standard.bool(forKey: "showAllDevices")
        debugMode = UserDefaults.standard.bool(forKey: "debugMode")
        // Default true for new installs (object == nil means never set)
        if UserDefaults.standard.object(forKey: "minimalMode") == nil {
            minimalMode = true
        } else {
            minimalMode = UserDefaults.standard.bool(forKey: "minimalMode")
        }
        // Load cached results for instant display on launch
        devices = Self.loadCache()
    }

    private var scanTask: Task<Void, Never>?
    private var showingCurrentScanResults = false

    func scan() {
        if demoMode { return }
        // Cancel any in-progress scan before starting a new one
        scanTask?.cancel()
        Scanner.cancelScan()
        let previousDevices = devices
        scanning = true
        scanProgress = 0
        showingCurrentScanResults = false
        scanError = nil
        ScanLog.shared.clear()
        scanTask = Task {
            let (result, error) = await Scanner.scanAll(showAll: showAllPorts, probeOfflinePeers: debugMode, onProgress: { progress in
                Task { @MainActor in self.scanProgress = progress }
            }, onDevice: { device in
                Task { @MainActor in
                    if !self.showingCurrentScanResults {
                        self.devices = []
                        self.showingCurrentScanResults = true
                    }
                    self.devices.append(device)
                    self.sortDevices()
                }
            })
            // Final consistent state
            self.scanError = error
            if error == nil || !result.isEmpty {
                let finalResult = Self.preserveServicesForTransientMisses(result, previous: previousDevices)
                self.devices = finalResult
                Self.saveCache(finalResult)
            }
            self.lastScan = Date()
            self.scanProgress = 1
            self.scanning = false
        }
    }

    private func sortDevices() {
        devices.sort {
            let lhs = $0.services.isEmpty ? 1 : 0
            let rhs = $1.services.isEmpty ? 1 : 0
            if lhs != rhs { return lhs < rhs }
            if $0.online != $1.online { return $0.online }
            return $0.name < $1.name
        }
    }

    // MARK: - Cache

    private static let cacheKey = "cachedDevices"

    private static func saveCache(_ devices: [Device]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    static func loadCache() -> [Device] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let devices = try? JSONDecoder().decode([Device].self, from: data) else { return [] }
        return devices
    }

    private static func preserveServicesForTransientMisses(_ devices: [Device], previous: [Device]) -> [Device] {
        let previousByKey = Dictionary(
            previous.map { ("\($0.name)|\($0.ip)", $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return devices.map { device in
            guard device.manifestUnavailable,
                  device.online,
                  device.services.isEmpty,
                  let prior = previousByKey["\(device.name)|\(device.ip)"],
                  !prior.services.isEmpty else {
                return device
            }

            var preserved = device
            preserved.services = prior.services
            return preserved
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
            if model.demoMode {
                Section {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.orange)
                        Text("Demo Mode")
                            .font(.subheadline.bold())
                        Spacer()
                        Button("Connect") {
                            model.demoMode = false
                            model.devices = []
                            model.scanError = "NO_CREDENTIALS"
                        }
                        .font(.subheadline)
                    }
                }
            }

            if model.scanning {
                Section {
                    ProgressView(value: model.scanProgress)
                        .tint(.accentColor)
                }
            }

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
            }

            if model.devices.isEmpty && !model.scanning {
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
                    DeviceSection(device: device, minimal: model.minimalMode, isDemo: model.demoMode)
                }
            }

            if model.debugMode {
                DebugLogSection()
            }

            Section {
                HStack {
                    Spacer()
                    Text(AppBuild.label)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .listRowBackground(Color.clear)
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
    @State private var showSafari = false

    static let oauthURL = URL(string: "https://login.tailscale.com/admin/settings/trust-credentials/add")

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
                showSafari = true
            } label: {
                Label("Open Tailscale OAuth", systemImage: "arrow.up.right")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .sheet(isPresented: $showSafari) {
                if let oauthURL = Self.oauthURL {
                    SafariView(url: oauthURL)
                }
            }

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

            Button {
                model.loadDemo()
            } label: {
                Text("Try Demo")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)

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
    @AppStorage("tsClientID") private var clientID = ""
    @AppStorage("tsClientSecret") private var clientSecret = ""
    @State private var showSafari = false

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
                        showSafari = true
                    }
                    .sheet(isPresented: $showSafari) {
                        if let oauthURL = SetupView.oauthURL {
                            SafariView(url: oauthURL)
                        }
                    }
                } header: {
                    Text("Tailscale")
                } footer: {
                    Text("OAuth client credentials. Never expires.")
                }

                Section {
                    Toggle(isOn: $model.minimalMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Minimal mode")
                            Text("Hide port numbers and IP addresses")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

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

                    Toggle(isOn: $model.debugMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Debug mode")
                            Text("Show scan log at bottom of device list")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Display")
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
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "\u{2014}")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Build") {
                        Text(AppBuild.label)
                            .font(.footnote.monospaced())
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
    let minimal: Bool
    let isDemo: Bool

    var body: some View {
        Section {
            if !device.online {
                Text("Offline")
                    .foregroundStyle(.tertiary)
            } else if device.services.isEmpty {
                Text("No web services")
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(device.services.sorted { $0.title < $1.title }) { service in
                    ServiceRow(service: service, minimal: minimal, isDemo: isDemo)
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
                Spacer()
                if !minimal {
                    Text(device.ip)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textCase(nil)
                }
            }
        }
    }
}

// MARK: - Debug log

struct DebugLogSection: View {
    @ObservedObject private var log = ScanLog.shared
    @State private var copied = false

    var body: some View {
        Section {
            if log.entries.isEmpty {
                Text("No log entries")
                    .foregroundStyle(.tertiary)
            } else {
                Button {
                    UIPasteboard.general.string = log.entries.joined(separator: "\n")
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied!" : "Copy Log",
                          systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(copied ? .green : .accentColor)
                }
                ForEach(Array(log.entries.reversed().enumerated()), id: \.offset) { _, entry in
                    Text(entry)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Debug Log")
        }
    }
}

// MARK: - Service row

struct ServiceRow: View {
    let service: WebService
    let minimal: Bool
    let isDemo: Bool
    @Environment(\.openURL) private var openURL
    @State private var showDemoAlert = false

    var body: some View {
        Button {
            if isDemo {
                showDemoAlert = true
            } else {
                openURL(service.url)
            }
        } label: {
            HStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)

                Text(service.title)
                    .lineLimit(1)

                Spacer()

                if !minimal {
                    Text(":\(service.port)")
                        .font(.footnote.monospaced())
                        .foregroundColor(.secondary)
                }

                Image(systemName: "arrow.up.right.square")
                    .font(.footnote)
                    .foregroundColor(.accentColor)
            }
            .foregroundColor(.primary)
        }
        .alert("Demo Mode", isPresented: $showDemoAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Connect your Tailscale account to open services on your devices.")
        }
        .contextMenu {
            if !isDemo {
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
}
