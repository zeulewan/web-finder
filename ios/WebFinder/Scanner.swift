import Foundation
import Network

// MARK: - Models

struct WebService: Identifiable, Codable {
    let id = UUID()
    let title: String
    let port: Int
    let url: URL
    let isHTTPS: Bool

    enum CodingKeys: String, CodingKey {
        case title, port, url, isHTTPS
    }
}

struct Device: Identifiable, Codable {
    let id = UUID()
    let name: String
    let ip: String
    let isLocal: Bool
    let isGateway: Bool
    let os: String?
    let online: Bool
    var services: [WebService]

    enum CodingKeys: String, CodingKey {
        case name, ip, isLocal, isGateway, os, online, services
    }

    init(name: String, ip: String, isLocal: Bool, isGateway: Bool = false, os: String?, online: Bool, services: [WebService]) {
        self.name = name; self.ip = ip; self.isLocal = isLocal; self.isGateway = isGateway
        self.os = os; self.online = online; self.services = services
    }

    static func isMacOS(_ os: String?) -> Bool {
        guard let os = os?.lowercased() else { return false }
        return os == "darwin" || os == "macos"
    }

    var sfIcon: String {
        if isLocal { return "iphone" }
        if isGateway { return "wifi.router" }
        if Device.isMacOS(os) { return "laptopcomputer" }
        switch os?.lowercased() {
        case "linux":   return "server.rack"
        case "ios":     return "iphone"
        default:        return "desktopcomputer"
        }
    }
}

// MARK: - Debug log

@MainActor
class ScanLog: ObservableObject {
    static let shared = ScanLog()
    @Published var entries: [String] = []
    var enabled: Bool { UserDefaults.standard.bool(forKey: "debugMode") }

    func log(_ msg: String) {
        guard enabled else { return }
        let ts = String(format: "%.1f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        let entry = "[\(ts)] \(msg)"
        Task { @MainActor in entries.append(entry) }
    }

    func clear() { entries = [] }
}

private func dlog(_ msg: String) {
    Task { @MainActor in ScanLog.shared.log(msg) }
}

// MARK: - Scanner

enum Scanner {
    // Concurrency limits to avoid overwhelming the Tailscale VPN tunnel on iOS.
    // Without these, scanning 10+ peers x 35 ports = 700+ concurrent HTTP connections.
    private static let maxConcurrentPeers = 3
    private static let maxConcurrentPorts = 6

    // Gateway-only port list (peers use manifest, not port scanning)
    static let ports: [Int] = [
        80, 443,
        1880,
        3000, 3001, 3100, 3460,
        4000, 4001, 4173,
        5000, 5001, 5050, 5173,
        6006, 6052, 7860,
        8000, 8001, 8002, 8003, 8004, 8005,
        8006,
        8080, 8081, 8082,
        8096, 8123, 8443, 8880, 8881, 8888,
        9000, 9001, 9090, 9093, 9321, 9443,
        11434, 18789, 19999, 32400,
    ]

    static let knownServices: [Int: String] = [
        21: "FTP", 22: "SSH", 25: "SMTP", 53: "DNS",
        1880: "Node-RED",
        5353: "mDNS", 6006: "TensorBoard", 6052: "ESPHome",
        8006: "Proxmox", 8096: "Jellyfin", 8123: "Home Assistant",
        9090: "Prometheus", 9093: "Alertmanager", 9321: "Web Finder",
        11434: "Ollama", 18789: "OpenClaw", 19999: "Netdata", 32400: "Plex",
    ]

    static let macOnlyServices: [Int: String] = [5000: "AirPlay"]

    static let httpsFirstPorts: Set<Int> = [443, 3460, 8443, 9443, 18789]

    static let MANIFEST_PORT = 9321
    static let MANIFEST_PATH = "/.well-known/web-finder.json"

    // Per-scan URLSession — created fresh for each scan and invalidated when done.
    // This ensures connections from previous scans are properly cleaned up.
    private static var _scanSession: URLSession?
    
    private static func makeScanSession() -> URLSession {
        // Invalidate previous session to close lingering connections
        _scanSession?.invalidateAndCancel()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.0
        config.timeoutIntervalForResource = 4.0
        config.httpMaximumConnectionsPerHost = 2
        let session = URLSession(configuration: config, delegate: InsecureTLSDelegate.shared, delegateQueue: nil)
        _scanSession = session
        return session
    }
    
    /// Cancel any in-progress scan by invalidating the session.
    static func cancelScan() {
        _scanSession?.invalidateAndCancel()
        _scanSession = nil
    }

    // MARK: - Top-level scan

    static func scanAll(showAll: Bool = false, onProgress: (@Sendable (Double) -> Void)? = nil, onDevice: (@Sendable (Device) -> Void)? = nil) async -> (devices: [Device], error: String?) {
        dlog("scanAll started")
        let _ = makeScanSession()
        async let gatewayResult = scanGateway()
        dlog("calling tailscaleStatus")
        let (status, apiError) = await tailscaleStatus()
        dlog("tailscaleStatus done: \(status != nil ? "ok" : "nil"), error: \(apiError ?? "none")")

        guard let status else {
            return ([], apiError)
        }

        guard let data = status.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesArray = obj["devices"] as? [[String: Any]] else {
            return ([], "Tailscale returned unexpected data")
        }

        let myHostname = ProcessInfo.processInfo.hostName
            .components(separatedBy: ".").first?.lowercased() ?? ""

        struct PeerInfo { let name: String; let ip: String; let dnsName: String; let online: Bool; let os: String? }

        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()
        isoFallback.formatOptions = [.withInternetDateTime]

        dlog("parsed \(devicesArray.count) devices from API")

        let peers: [PeerInfo] = devicesArray.compactMap { device in
            guard let addresses = device["addresses"] as? [String],
                  let ip = addresses.first else { return nil }

            let hostname = device["hostname"] as? String ?? ""
            let rawDNS = ((device["name"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let dnsName = rawDNS.isEmpty ? ip : rawDNS
            let fqdn = rawDNS.components(separatedBy: ".").first ?? ""
            let name = hostname.isEmpty ? (fqdn.isEmpty ? ip : fqdn) : hostname

            if name.lowercased() == myHostname { return nil }

            let os = device["os"] as? String
            var online = false
            if let lastSeenStr = device["lastSeen"] as? String,
               let lastSeen = isoFormatter.date(from: lastSeenStr) ?? isoFallback.date(from: lastSeenStr) {
                online = now.timeIntervalSince(lastSeen) < 300
            }

            return PeerInfo(name: name, ip: ip, dnsName: dnsName, online: online, os: os)
        }

        let onlinePeers = peers.filter { $0.online }
        dlog("\(peers.count) peers, \(onlinePeers.count) online, scanning \(maxConcurrentPeers) at a time...")

        // Throttled peer scanning: max N peers at a time to avoid flooding VPN tunnel.
        let totalPeers = max(peers.count, 1)
        var devices = await withTaskGroup(of: Device.self) { group in
            var iterator = peers.makeIterator()
            var running = 0
            var results: [Device] = []

            // Helper to add one peer scan to the group
            func addNext() -> Bool {
                guard let peer = iterator.next() else { return false }
                group.addTask {
                    guard peer.online else {
                        return Device(name: peer.name, ip: peer.dnsName, isLocal: false,
                                      os: peer.os, online: false, services: [])
                    }
                    dlog("fetching manifest from \(peer.name) (\(peer.ip))...")
                    let services = await fetchManifest(ip: peer.ip) ?? []
                    dlog("  \(peer.name): \(services.count) services from manifest")
                    return Device(name: peer.name, ip: peer.dnsName, isLocal: false,
                                  os: peer.os, online: true, services: services)
                }
                return true
            }

            // Seed initial batch
            while running < maxConcurrentPeers, addNext() { running += 1 }

            // As each completes, deliver progressively and start the next
            for await d in group {
                results.append(d)
                running -= 1
                if Task.isCancelled { group.cancelAll(); break }
                onProgress?(Double(results.count) / Double(totalPeers))
                onDevice?(d)
                if addNext() { running += 1 }
            }
            return results
        }

        dlog("peer scan done, \(devices.count) devices. waiting for gateway...")
        if let gw = await gatewayResult {
            dlog("gateway found: \(gw.name) (\(gw.ip))")
            devices.append(gw)
            onDevice?(gw)
        } else {
            dlog("no gateway found")
        }

        devices.sort {
            let lhs = $0.services.isEmpty ? 1 : 0
            let rhs = $1.services.isEmpty ? 1 : 0
            if lhs != rhs { return lhs < rhs }
            if $0.online != $1.online { return $0.online }
            return $0.name < $1.name
        }
        return (devices, nil)
    }

    // MARK: - Manifest

    /// Fetch the web-finder manifest from a peer. Returns parsed services on success, nil if unavailable.
    static func fetchManifest(ip: String) async -> [WebService]? {
        guard let url = URL(string: "http://\(ip):\(MANIFEST_PORT)\(MANIFEST_PATH)") else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.0
        let session = URLSession(configuration: config)
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let svcs = json["services"] as? [[String: Any]] else { return nil }
            return svcs.compactMap { svc -> WebService? in
                guard let name = svc["name"] as? String,
                      let port = svc["port"] as? Int,
                      let urlStr = svc["url"] as? String,
                      let origURL = URL(string: urlStr) else { return nil }
                // Rewrite localhost URLs to use peer's actual IP (manifest URLs are 127.0.0.1)
                let scheme = origURL.scheme ?? "http"
                guard let svcURL = URL(string: "\(scheme)://\(ip):\(port)") else { return nil }
                return WebService(title: name, port: port, url: svcURL, isHTTPS: scheme == "https")
            }
        } catch {
            return nil
        }
    }

    // MARK: - Tailscale OAuth API

    static func getAccessToken(clientID: String, clientSecret: String) async -> String? {
        guard let url = URL(string: "https://api.tailscale.com/api/v2/oauth/token") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10.0
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let cred = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(cred)", forHTTPHeaderField: "Authorization")
        req.httpBody = Data("grant_type=client_credentials".utf8)

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            return nil
        }
        return token
    }

    static func tailscaleStatus() async -> (String?, String?) {
        let clientID = UserDefaults.standard.string(forKey: "tsClientID") ?? ""
        let clientSecret = UserDefaults.standard.string(forKey: "tsClientSecret") ?? ""

        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            return (nil, "NO_CREDENTIALS")
        }

        guard let token = await getAccessToken(clientID: clientID, clientSecret: clientSecret) else {
            return (nil, "INVALID_CREDENTIALS")
        }

        guard let url = URL(string: "https://api.tailscale.com/api/v2/tailnet/-/devices") else {
            return (nil, "Invalid API URL")
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 10.0
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return (nil, "No HTTP response from Tailscale API")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return (nil, "INVALID_CREDENTIALS")
            }
            if http.statusCode != 200 {
                return (nil, "Tailscale API error: HTTP \(http.statusCode)")
            }
            guard let str = String(data: data, encoding: .utf8) else {
                return (nil, "Could not decode response")
            }
            return (str, nil)
        } catch {
            return (nil, "Request failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Gateway

    static func scanGateway() async -> Device? {
        dlog("gateway: detecting IP...")
        guard let gatewayIP = await getDefaultGateway(), !gatewayIP.isEmpty else {
            dlog("gateway: no IP found")
            return nil
        }
        dlog("gateway: IP = \(gatewayIP)")

        let gatewayPorts = [80, 443, 8080]
        let openPorts = await tcpScanPorts(host: gatewayIP, ports: gatewayPorts)
        dlog("gateway: open ports = \(openPorts)")
        guard !openPorts.isEmpty else { return nil }

        // Fetch services with showAll, rename generic "Port X" to "Admin Page"
        let allServices = await fetchServices(host: gatewayIP, ports: openPorts, hints: [:], showAll: true)
        let services = allServices.map { svc -> WebService in
            if svc.title.hasPrefix("Port ") {
                return WebService(title: "Admin Page", port: svc.port, url: svc.url, isHTTPS: svc.isHTTPS)
            }
            return svc
        }
        guard !services.isEmpty else { return nil }

        // Detect UniFi hardware model, then ISP, then fall back to Gateway.
        // ISP comes before page title because our "Admin Page" rename isn't a real name.
        let model = await detectUnifiModel(host: gatewayIP)
        let name: String
        if let model { name = model }
        else if let isp = await getISPName() { name = "\(isp) Modem" }
        else {
            let realTitle = services.first(where: { $0.title != "Admin Page" })?.title
            name = realTitle ?? "Gateway"
        }

        // For UniFi devices, only keep port 443 (main web UI).
        // Port 80 redirects to 443, 8080 is device inform, 8443 is legacy controller API.
        let filtered = model != nil ? services.filter { $0.port == 443 } : services
        let finalServices = filtered.isEmpty ? services : filtered

        return Device(name: name, ip: gatewayIP, isLocal: false, isGateway: true, os: nil,
                      online: true, services: finalServices)
    }

    /// Detect UniFi hardware model from UNIFI_OS_MANIFEST in the gateway page.
    static func detectUnifiModel(host: String) async -> String? {
        guard let url = URL(string: "https://\(host)") else { return nil }
        do {
            let session = _scanSession ?? makeScanSession()
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            guard let start = html.range(of: "UNIFI_OS_MANIFEST") else { return nil }
            let after = html[start.upperBound...]
            guard let braceStart = after.firstIndex(of: "{"),
                  let scriptEnd = after.range(of: "</script>") else { return nil }
            let jsonStr = String(after[braceStart..<scriptEnd.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard let jsonData = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let modelObj = obj["model"] as? [String: Any] else { return nil }
            return (modelObj["shortName"] as? String) ?? (modelObj["longName"] as? String)
        } catch {
            return nil
        }
    }

    static func getISPName() async -> String? {
        guard let url = URL(string: "https://ipinfo.io/json") else { return nil }
        do {
            let session = _scanSession ?? makeScanSession()
            let (data, _) = try await session.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let org = json["org"] as? String, !org.isEmpty else { return nil }
            return org.replacingOccurrences(of: #"^AS\d+\s+"#, with: "", options: .regularExpression)
        } catch {
            return nil
        }
    }

    /// Find gateway IP using NWPathMonitor (WiFi-specific, bypasses Tailscale VPN)
    private static func getDefaultGateway() async -> String? {
        dlog("gateway: trying NWPathMonitor...")
        if let gw = await getGatewayViaPathMonitor() {
            dlog("gateway: NWPathMonitor found \(gw)")
            return gw
        }
        dlog("gateway: NWPathMonitor failed, trying getifaddrs...")
        if let gw = getGatewayFromInterfaces() {
            dlog("gateway: getifaddrs found \(gw)")
            return gw
        }
        dlog("gateway: all methods failed")
        return nil
    }

    private static func getGatewayViaPathMonitor() async -> String? {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var done = false
            let finish: (String?) -> Void = { result in
                lock.lock(); let first = !done; done = true; lock.unlock()
                if first { continuation.resume(returning: result) }
            }

            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                dlog("gateway/monitor: status=\(path.status), gateways=\(path.gateways.count), interfaces=\(path.availableInterfaces.map { $0.name })")
                guard path.status == .satisfied else { finish(nil); return }

                for gw in path.gateways {
                    if case .hostPort(let host, _) = gw {
                        let ip = "\(host)"
                        dlog("gateway/monitor: gw ip = \(ip)")
                        if !ip.hasPrefix("100.") && !ip.contains(":") {
                            finish(ip)
                            return
                        }
                    }
                }
                finish(nil)
            }
            monitor.start(queue: DispatchQueue(label: "gw-detect"))

            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                monitor.cancel()
                finish(nil)
            }
        }
    }

    /// Fallback: enumerate network interfaces to find a private IPv4, infer gateway as .1
    private static func getGatewayFromInterfaces() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("lo") { continue }

            let addr = ptr.pointee.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let hostOrder = CFSwapInt32BigToHost(addr.sin_addr.s_addr)
            let firstOctet = hostOrder >> 24

            if firstOctet == 100 && ((hostOrder >> 22) & 0x3) == 1 { continue }
            if firstOctet == 169 && ((hostOrder >> 16) & 0xFF) == 254 { continue }
            let isPrivate = firstOctet == 10 ||
                            (firstOctet == 172 && ((hostOrder >> 16) & 0xFF) >= 16 && ((hostOrder >> 16) & 0xFF) <= 31) ||
                            (firstOctet == 192 && ((hostOrder >> 16) & 0xFF) == 168)
            guard isPrivate else { continue }

            let gwHostOrder = (hostOrder & 0xFFFFFF00) | 1
            var gwAddr = in_addr()
            gwAddr.s_addr = CFSwapInt32HostToBig(gwHostOrder)
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &gwAddr, &buf, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buf)
        }
        return nil
    }

    // MARK: - Port scanning (used for gateway only; peers use HTTP probing)

    static func tcpScanPorts(host: String, ports portsToScan: [Int]? = nil) async -> [Int] {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for port in (portsToScan ?? ports) {
                group.addTask { (port, await tcpCheck(host: host, port: port)) }
            }
            var open: [Int] = []
            for await (port, isOpen) in group {
                if isOpen { open.append(port) }
            }
            return open.sorted()
        }
    }

    static func tcpCheck(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let lock = NSLock()
            var done = false
            let finish: (Bool) -> Void = { result in
                lock.lock(); let go = !done; done = true; lock.unlock()
                if go { continuation.resume(returning: result) }
            }
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: UInt16(port))!,
                using: .tcp
            )
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:  conn.cancel(); finish(true)
                case .failed: conn.cancel(); finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { conn.cancel(); finish(false) }
        }
    }

    // MARK: - HTTP probing (throttled)

    /// Probe all ports via HTTP directly (no TCP scan). Used for Tailscale peers
    /// because NWConnection doesn't route through the VPN tunnel on iOS.
    /// Throttled to maxConcurrentPorts at a time per peer.
    // Ports that are APIs or protocol endpoints, not web UIs.
    // Only shown when showAllPorts is enabled.
    static let nonWebPorts: Set<Int> = [11434] // Ollama API
    static let darwinOnlyNonWebPorts: Set<Int> = [5000] // AirPlay Receiver

    static func httpProbeAllPorts(host: String, displayHost: String? = nil, os: String? = nil, showAll: Bool = false) async -> [WebService] {
        let shortHost = (displayHost ?? host).components(separatedBy: ".").first ?? host

        // Warm up the VPN tunnel. First connection to a Tailscale peer can take
        // seconds while WireGuard establishes the tunnel. Use a dedicated session
        // with a longer timeout so it doesn't get capped by the scan session's limits.
        let warmupStart = Date()
        if let warmupURL = URL(string: "https://\(host):443") {
            let warmupConfig = URLSessionConfiguration.ephemeral
            warmupConfig.timeoutIntervalForRequest = 5.0
            warmupConfig.timeoutIntervalForResource = 6.0
            let warmupSession = URLSession(configuration: warmupConfig, delegate: InsecureTLSDelegate.shared, delegateQueue: nil)
            var req = URLRequest(url: warmupURL)
            req.timeoutInterval = 5.0
            do {
                let (_, response) = try await warmupSession.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                dlog("  \(shortHost): warmup ok (HTTP \(code), \(String(format: "%.1f", Date().timeIntervalSince(warmupStart)))s)")
            } catch {
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(warmupStart))
                let nsErr = (error as NSError)
                dlog("  \(shortHost): warmup failed (\(nsErr.domain) \(nsErr.code), \(elapsed)s)")
            }
            warmupSession.invalidateAndCancel()
        }

        // Brief pause after warmup to let the WireGuard tunnel stabilize
        try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        // Ports we want extra diagnostics for when they fail
        let debugPorts: Set<Int> = [443, 3460, 5001]

        // Throttled port scanning: max N ports probed concurrently
        return await withTaskGroup(of: WebService?.self) { group in
            var portIterator = ports.makeIterator()
            var running = 0
            var services: [WebService] = []

            func probePort(_ port: Int) {
                group.addTask {
                    guard let svc = await fetchTitle(host: host, port: port) else {
                        if debugPorts.contains(port) {
                            dlog("  \(shortHost):\(port) -> MISS")
                        }
                        return nil
                    }
                    dlog("  \(shortHost):\(port) -> \(svc.title)")
                    if let dh = displayHost, let url = URL(string: "\(svc.isHTTPS ? "https" : "http")://\(dh):\(port)") {
                        return WebService(title: svc.title, port: port, url: url, isHTTPS: svc.isHTTPS)
                    }
                    return svc
                }
            }

            // Seed initial batch
            while running < maxConcurrentPorts, let port = portIterator.next() {
                probePort(port)
                running += 1
            }

            // As each completes, start the next (stop if scan was cancelled)
            for await s in group {
                running -= 1
                if Task.isCancelled { group.cancelAll(); break }
                if let s { services.append(s) }
                if let port = portIterator.next() {
                    probePort(port)
                    running += 1
                }
            }

            dlog("  \(shortHost): \(services.count) services found")
            var result = dedup(services)
            if !showAll {
                let isDarwin = Device.isMacOS(os)
                result = result.filter { svc in
                    if nonWebPorts.contains(svc.port) { return false }
                    if isDarwin && darwinOnlyNonWebPorts.contains(svc.port) { return false }
                    return true
                }
            }
            return result.sorted { $0.port < $1.port }
        }
    }

    // MARK: - HTTP title fetching

    static func fetchServices(host: String, ports: [Int], hints: [Int: String], os: String? = nil, showAll: Bool = false) async -> [WebService] {
        let isDarwin = Device.isMacOS(os)
        let lookup = isDarwin ? knownServices.merging(macOnlyServices) { _, new in new } : knownServices
        return await withTaskGroup(of: WebService?.self) { group in
            for port in ports {
                group.addTask {
                    if let projectName = hints[port] {
                        let url = URL(string: "http://\(host):\(port)")!
                        return WebService(title: projectName, port: port, url: url, isHTTPS: false)
                    }
                    if let svc = await fetchTitle(host: host, port: port) { return svc }
                    guard showAll else { return nil }
                    let name = lookup[port] ?? "Port \(port)"
                    let scheme = httpsFirstPorts.contains(port) ? "https" : "http"
                    let url = URL(string: "\(scheme)://\(host):\(port)")!
                    return WebService(title: name, port: port, url: url, isHTTPS: httpsFirstPorts.contains(port))
                }
            }
            var services: [WebService] = []
            for await s in group { if let s { services.append(s) } }
            return dedup(services).sorted { $0.port < $1.port }
        }
    }

    /// Remove duplicate/redirect ports.
    private static func dedup(_ services: [WebService]) -> [WebService] {
        // Standard HTTP/HTTPS pairs: remove HTTP variant when HTTPS exists
        let pairs: [(Int, Int)] = [(80, 443), (5000, 5001), (8080, 8443)]
        var skip: Set<Int> = []
        for (httpPort, httpsPort) in pairs {
            if services.contains(where: { $0.port == httpPort }),
               services.contains(where: { $0.port == httpsPort }) {
                skip.insert(httpPort)
            }
        }
        // Remove generic "Port X" entries for common redirect ports (80, 443)
        // when any service with a real title exists on the same device.
        let hasRealTitle = services.contains { !$0.title.hasPrefix("Port ") }
        if hasRealTitle {
            for svc in services where svc.title.hasPrefix("Port ") {
                if svc.port == 80 || svc.port == 443 {
                    skip.insert(svc.port)
                }
            }
        }
        return services.filter { !skip.contains($0.port) }
    }

    // Ports we want detailed fetch logging for
    private static let verbosePorts: Set<Int> = [443, 3460, 5001]

    /// Smart dual-scheme probe: try preferred scheme first.
    /// Only try fallback if the port is actually open (got a response or TLS error).
    /// Skip fallback if the port is closed (timeout/connection refused) to avoid wasting connections.
    static func fetchTitle(host: String, port: Int) async -> WebService? {
        let preferred = httpsFirstPorts.contains(port) ? "https" : "http"
        let fallback = preferred == "https" ? "http" : "https"
        let verbose = verbosePorts.contains(port)
        let shortHost = host.components(separatedBy: ".").first ?? host
        // Track if any probe indicates the port is open (200 OK, 4xx, or SSL error).
        // Used to create a fallback service when no <title> is found.
        var openPortURL: URL?

        if let url = URL(string: "\(preferred)://\(host):\(port)") {
            let result = await httpTitle(url: url)
            if verbose { dlog("    \(shortHost):\(port) \(preferred) -> \(result.debugLabel)") }
            switch result {
            case .found(let title, let finalURL):
                return WebService(title: title, port: port, url: finalURL, isHTTPS: preferred == "https")
            case .redirectedToPort(_):
                return nil
            case .noTitle(let u):
                openPortURL = u
            case .responded:
                openPortURL = openPortURL ?? url // port IS open (SSL error or 4xx)
            case .connectionFailed:
                return nil // port is closed, don't waste a connection on fallback
            }
        }

        if let url = URL(string: "\(fallback)://\(host):\(port)") {
            let result = await httpTitle(url: url)
            if verbose { dlog("    \(shortHost):\(port) \(fallback) -> \(result.debugLabel)") }
            switch result {
            case .found(let title, let finalURL):
                return WebService(title: title, port: port, url: finalURL, isHTTPS: fallback == "https")
            case .noTitle(let u):
                openPortURL = openPortURL ?? u
            case .responded:
                openPortURL = openPortURL ?? url
            default:
                break
            }
        }

        // Port is open but no <title> tag found (SPA, API, or auth-protected).
        // Show with a fallback name.
        if let url = openPortURL {
            let name = knownServices[port] ?? "Port \(port)"
            let isHTTPS = url.scheme == "https"
            return WebService(title: name, port: port, url: url, isHTTPS: isHTTPS)
        }

        return nil
    }

    enum FetchResult {
        case found(String, URL)
        case redirectedToPort(Int)
        case noTitle(URL)       // HTTP 200 OK but no <title> tag (SPA/API - port has a web app)
        case responded          // HTTP 4xx/5xx or non-decodable (port open, try other scheme)
        case connectionFailed   // couldn't connect at all (port closed/timeout, skip fallback)

        var debugLabel: String {
            switch self {
            case .found(let t, _): return "found(\(t))"
            case .redirectedToPort(let p): return "redirect(:\(p))"
            case .noTitle(_): return "200(no title)"
            case .responded: return "responded(error)"
            case .connectionFailed: return "connFailed"
            }
        }
    }

    static func httpTitle(url: URL) async -> FetchResult {
        do {
            let session = _scanSession ?? makeScanSession()
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return .responded }

            // Detect redirect to a different port on the same host
            if let finalURL = http.url,
               let origPort = url.port, let finalPort = finalURL.port,
               finalPort != origPort, finalURL.host == url.host {
                return .redirectedToPort(finalPort)
            }

            if http.statusCode >= 400 { return .responded }

            guard let html = String(data: data, encoding: .utf8)
                          ?? String(data: data, encoding: .isoLatin1) else { return .noTitle(url) }

            // If the response doesn't look like HTML (no tags at all), it's a plain text
            // API endpoint (e.g., Ollama "Ollama is running") or a non-web protocol.
            // Don't create a fallback service for these.
            let lower = html.prefix(2000).lowercased()
            if !lower.contains("<html") && !lower.contains("<!doctype") && !lower.contains("<head") && !lower.contains("<body") {
                return .responded
            }

            guard let range = html.range(of: #"<title[^>]*>([^<]+)</title>"#,
                                          options: [.regularExpression, .caseInsensitive]) else { return .noTitle(url) }
            var raw = String(html[range])
                .replacingOccurrences(of: #"<title[^>]*>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "</title>", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            raw = raw
                .replacingOccurrences(of: "&amp;",  with: "&")
                .replacingOccurrences(of: "&lt;",   with: "<")
                .replacingOccurrences(of: "&gt;",   with: ">")
                .replacingOccurrences(of: "&#39;",  with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&#160;", with: " ")
            // "Page Title - Site Name" -> use site name (last part after separator)
            if let sepRange = raw.range(of: #"\s+[-–—|]\s+"#, options: [.regularExpression, .backwards]) {
                raw = String(raw[sepRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if raw.isEmpty { return .noTitle(url) }
            return .found(raw, url)
        } catch {
            // TLS/SSL errors (code -1200 to -1206) mean the port IS open but doesn't
            // speak TLS. Caller should try the other scheme.
            let nsErr = error as NSError
            let code = nsErr.code
            // Log the underlying error for key ports
            if let port = url.port, verbosePorts.contains(port) {
                let underlying = (nsErr.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
                dlog("    \(url.host ?? "?"):\(port) err: \(nsErr.domain) \(code) underlying:\(underlying ?? 0)")
            }
            if (-1206)...(-1200) ~= code { return .responded }
            // Everything else (timeout, connection refused, etc.) means port is closed.
            return .connectionFailed
        }
    }
}

// MARK: - Demo data

extension Scanner {
    static func demoDevices() -> [Device] {
        [
            Device(name: "workstation", ip: "100.101.214.44", isLocal: false, os: "linux", online: true, services: [
                WebService(title: "Grafana", port: 3000, url: URL(string: "http://workstation:3000")!, isHTTPS: false),
                WebService(title: "Prometheus", port: 9090, url: URL(string: "http://workstation:9090")!, isHTTPS: false),
                WebService(title: "Jupyter Notebook", port: 8888, url: URL(string: "http://workstation:8888")!, isHTTPS: false),
                WebService(title: "Portainer", port: 9443, url: URL(string: "https://workstation:9443")!, isHTTPS: true),
            ]),
            Device(name: "nas", ip: "100.88.12.5", isLocal: false, os: "linux", online: true, services: [
                WebService(title: "Synology DSM", port: 5001, url: URL(string: "https://nas:5001")!, isHTTPS: true),
                WebService(title: "Plex", port: 32400, url: URL(string: "http://nas:32400")!, isHTTPS: false),
                WebService(title: "Jellyfin", port: 8096, url: URL(string: "http://nas:8096")!, isHTTPS: false),
            ]),
            Device(name: "pi-home", ip: "100.77.33.10", isLocal: false, os: "linux", online: true, services: [
                WebService(title: "Home Assistant", port: 8123, url: URL(string: "http://pi-home:8123")!, isHTTPS: false),
                WebService(title: "Node-RED", port: 1880, url: URL(string: "http://pi-home:1880")!, isHTTPS: false),
            ]),
            Device(name: "macbook", ip: "100.117.222.41", isLocal: false, os: "darwin", online: true, services: [
                WebService(title: "Dev Server", port: 5173, url: URL(string: "http://macbook:5173")!, isHTTPS: false),
            ]),
            Device(name: "cloud-vm", ip: "100.64.1.22", isLocal: false, os: "linux", online: false, services: []),
        ]
    }
}

// Accepts self-signed certs (shared singleton)
class InsecureTLSDelegate: NSObject, URLSessionDelegate {
    static let shared = InsecureTLSDelegate()

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
