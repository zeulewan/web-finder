import Foundation
import Network

// MARK: - Models

struct WebService: Identifiable {
    let id = UUID()
    let title: String
    let port: Int
    let url: URL
    let isHTTPS: Bool
}

struct Device: Identifiable {
    let id = UUID()
    let name: String
    let ip: String
    let isLocal: Bool
    let os: String?
    let online: Bool
    var services: [WebService]

    var sfIcon: String {
        if isLocal { return "iphone" }
        switch os?.lowercased() {
        case "linux":   return "server.rack"
        case "darwin":  return "laptopcomputer"
        case "ios":     return "iphone"
        default:        return "desktopcomputer"
        }
    }
}

// MARK: - Scanner

enum Scanner {
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
        8096, 8123, 8443, 8888,
        9000, 9001, 9090, 9093, 9443,
        11434, 19999, 32400,
    ]

    static let knownServices: [Int: String] = [
        21: "FTP", 22: "SSH", 25: "SMTP", 53: "DNS",
        1880: "Node-RED",
        5353: "mDNS", 6006: "TensorBoard", 6052: "ESPHome",
        8006: "Proxmox", 8096: "Jellyfin", 8123: "Home Assistant",
        9090: "Prometheus", 9093: "Alertmanager",
        11434: "Ollama", 19999: "Netdata", 32400: "Plex",
    ]

    static let macOnlyServices: [Int: String] = [5000: "AirPlay"]

    // MARK: - Top-level scan

    static func scanAll(showAll: Bool = false) async -> (devices: [Device], error: String?) {
        let (status, apiError) = await tailscaleStatus()

        guard let status else {
            return ([], apiError)
        }

        guard let data = status.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesArray = obj["devices"] as? [[String: Any]] else {
            return ([], "Tailscale returned unexpected data")
        }

        // Get this device's hostname so we can skip ourselves
        let myHostname = ProcessInfo.processInfo.hostName
            .components(separatedBy: ".").first?.lowercased() ?? ""

        struct PeerInfo { let name: String; let ip: String; let dnsName: String; let online: Bool; let os: String? }

        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()
        isoFallback.formatOptions = [.withInternetDateTime]

        let peers: [PeerInfo] = devicesArray.compactMap { device in
            guard let addresses = device["addresses"] as? [String],
                  let ip = addresses.first else { return nil }

            let hostname = device["hostname"] as? String ?? ""
            // Full MagicDNS name for HTTPS URLs (strip trailing dot)
            let rawDNS = ((device["name"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let dnsName = rawDNS.isEmpty ? ip : rawDNS
            let fqdn = rawDNS.components(separatedBy: ".").first ?? ""
            let name = hostname.isEmpty ? (fqdn.isEmpty ? ip : fqdn) : hostname

            // Skip this device
            if name.lowercased() == myHostname { return nil }

            // Use lastSeen to determine online status (within last 5 minutes = online)
            let os = device["os"] as? String
            var online = false
            if let lastSeenStr = device["lastSeen"] as? String,
               let lastSeen = isoFormatter.date(from: lastSeenStr) ?? isoFallback.date(from: lastSeenStr) {
                online = now.timeIntervalSince(lastSeen) < 300
            }

            return PeerInfo(name: name, ip: ip, dnsName: dnsName, online: online, os: os)
        }

        var devices = await withTaskGroup(of: Device.self) { group in
            for peer in peers {
                group.addTask {
                    guard peer.online else {
                        return Device(name: peer.name, ip: peer.dnsName, isLocal: false,
                                      os: peer.os, online: false, services: [])
                    }
                    // Scan using IP (fast), build URLs with MagicDNS name (valid HTTPS certs)
                    let openPorts = await tcpScanPorts(host: peer.ip)
                    let services = await fetchServices(host: peer.dnsName, ports: openPorts, hints: [:], os: peer.os, showAll: showAll)
                    return Device(name: peer.name, ip: peer.dnsName, isLocal: false,
                                  os: peer.os, online: true, services: services)
                }
            }
            var results: [Device] = []
            for await d in group { results.append(d) }
            return results
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

    // MARK: - Tailscale OAuth API

    /// Get an OAuth access token using client credentials
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

    /// Fetch device list from the Tailscale API using OAuth
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

    // MARK: - Port scanning

    static func tcpScanPorts(host: String) async -> [Int] {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for port in ports {
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
                case .failed: finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { conn.cancel(); finish(false) }
        }
    }

    // MARK: - HTTP title fetching

    static func fetchServices(host: String, ports: [Int], hints: [Int: String], os: String? = nil, showAll: Bool = false) async -> [WebService] {
        let isDarwin = os?.lowercased() == "darwin"
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
            let httpsPairs: [(Int, Int)] = [(80, 443), (8080, 8443)]
            var skipPorts: Set<Int> = []
            for (httpPort, httpsPort) in httpsPairs {
                if services.contains(where: { $0.port == httpPort }),
                   services.contains(where: { $0.port == httpsPort }) {
                    skipPorts.insert(httpPort)
                }
            }
            return services.filter { !skipPorts.contains($0.port) }.sorted { $0.port < $1.port }
        }
    }

    static let httpsFirstPorts: Set<Int> = [443, 3460, 8443, 9443]

    enum FetchResult {
        case found(String, URL)
        case redirectedToPort(Int)
        case notFound
    }

    static func fetchTitle(host: String, port: Int) async -> WebService? {
        let schemes = httpsFirstPorts.contains(port) ? ["https", "http"] : ["http", "https"]
        for scheme in schemes {
            guard let url = URL(string: "\(scheme)://\(host):\(port)") else { continue }
            let result = await httpTitle(url: url)
            switch result {
            case .redirectedToPort(_):
                return nil
            case .found(let title, let finalURL):
                return WebService(title: title, port: port, url: finalURL, isHTTPS: scheme == "https")
            case .notFound:
                continue
            }
        }
        return nil
    }

    static func httpTitle(url: URL) async -> FetchResult {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.0
        config.timeoutIntervalForResource = 5.0
        let delegate = RedirectDetectingDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return .notFound }

            if let redirectPort = delegate.redirectedToPort, redirectPort != url.port ?? (url.scheme == "https" ? 443 : 80) {
                return .redirectedToPort(redirectPort)
            }

            if http.statusCode >= 400 { return .notFound }

            guard let html = String(data: data, encoding: .utf8)
                          ?? String(data: data, encoding: .isoLatin1) else { return .notFound }

            guard let range = html.range(of: #"<title[^>]*>([^<]+)</title>"#,
                                          options: [.regularExpression, .caseInsensitive]) else { return .notFound }
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
            raw = raw.replacingOccurrences(of: #"^Home\s*[-–—|:]\s*"#, with: "", options: .regularExpression)
            if raw.isEmpty { return .notFound }
            return .found(raw, url)
        } catch {
            return .notFound
        }
    }
}

class RedirectDetectingDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    var redirectedToPort: Int?

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let redirectURL = request.url {
            let port = redirectURL.port ?? (redirectURL.scheme == "https" ? 443 : 80)
            redirectedToPort = port
        }
        completionHandler(request)
    }
}
