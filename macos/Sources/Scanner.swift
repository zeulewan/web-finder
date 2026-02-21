import Foundation
import Network

// MARK: - Models

struct WebService: Identifiable {
    let id = UUID()
    let title: String     // HTML <title> or fallback
    let port: Int
    let url: URL
    let isHTTPS: Bool
}

struct Device: Identifiable {
    let id = UUID()
    let name: String
    let ip: String
    let isLocal: Bool
    let os: String?       // "linux", "darwin", "windows" from Tailscale
    let online: Bool
    var services: [WebService]

    var sfIcon: String {
        if isLocal { return "laptopcomputer" }
        switch os?.lowercased() {
        case "linux":   return "server.rack"
        case "darwin":  return "laptopcomputer"
        default:        return "desktopcomputer"
        }
    }
}

// MARK: - Scanner

enum Scanner {
    /// Broad set of ports covering dev servers, NAS, home automation, media, etc.
    static let ports: [Int] = [
        80, 443,
        1880,             // Node-RED
        3000, 3001, 3100, 3460,
        4000, 4001, 4173,
        5000, 5001, 5050, 5173,  // Synology, pgAdmin, Vite
        6006, 6052,       // TensorBoard, ESPHome
        7860,             // Gradio
        8000, 8001, 8002, 8003, 8004, 8005,
        8006,             // Proxmox
        8080, 8081, 8082,
        8096,             // Jellyfin
        8123,             // Home Assistant
        8443,
        8888,             // Jupyter
        9000, 9001, 9090, 9093,
        9443,
        11434,            // Ollama
        19999,            // Netdata
        32400,            // Plex
    ]

    static let knownServices: [Int: String] = [
        21:    "FTP",
        22:    "SSH",
        25:    "SMTP",
        53:    "DNS",
        1880:  "Node-RED",
        5353:  "mDNS",
        6006:  "TensorBoard",
        6052:  "ESPHome",
        8006:  "Proxmox",
        8096:  "Jellyfin",
        8123:  "Home Assistant",
        9090:  "Prometheus",
        9093:  "Alertmanager",
        11434: "Ollama",
        19999: "Netdata",
        32400: "Plex",
    ]

    // Services only found on macOS
    static let macOnlyServices: [Int: String] = [
        5000: "AirPlay",
    ]

    static let tailscalePaths = [
        "/usr/local/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

    // MARK: - Top-level scan

    static func scanAll(showAll: Bool = false) async -> [Device] {
        // Run local, gateway, and Tailscale scans in parallel
        async let local   = scanLocalDevice(showAll: showAll)
        async let gateway = scanGateway(showAll: showAll)
        async let remote  = scanTailscaleDevices(showAll: showAll)

        var all = [await local] + (await remote)
        if let gw = await gateway { all.append(gw) }
        // Sort: local first, then has-services before empty, then online before offline, then alphabetical
        all.sort {
            if $0.isLocal != $1.isLocal { return $0.isLocal }
            let lhs = $0.services.isEmpty ? 1 : 0
            let rhs = $1.services.isEmpty ? 1 : 0
            if lhs != rhs { return lhs < rhs }
            if $0.online != $1.online { return $0.online }
            return $0.name < $1.name
        }
        return all
    }

    // MARK: - Local

    static func scanLocalDevice(showAll: Bool = false) async -> Device {
        let hostname = ProcessInfo.processInfo.hostName
            .components(separatedBy: ".").first ?? "This Mac"

        // Run TCP scan and process discovery in parallel
        async let openPorts  = tcpScanPorts(host: "127.0.0.1")
        async let psProjects = scanLocalProcesses()

        let ports    = await openPorts
        let projects = await psProjects

        let services = await fetchServices(host: "127.0.0.1", ports: ports, hints: projects, os: "darwin", showAll: showAll)
        return Device(name: hostname, ip: "127.0.0.1", isLocal: true, os: "darwin",
                      online: true, services: services)
    }

    /// Use pgrep to find zensical processes - returns port -> project name hints
    static func scanLocalProcesses() async -> [Int: String] {
        // pgrep -fl is fast and targeted; no TCC delay unlike ps aux
        guard let out = await shell("pgrep -fl zensical 2>/dev/null") else { return [:] }
        var hints: [Int: String] = [:]
        for line in out.components(separatedBy: "\n") {
            guard line.contains("serve"), !line.contains("grep") else { continue }

            var port = 8000
            if let range = line.range(of: #"--dev-addr\s+[\d.]+:(\d+)"#, options: .regularExpression) {
                let s = String(line[range])
                if let p = s.components(separatedBy: ":").last.flatMap(Int.init) { port = p }
            } else if let range = line.range(of: #"(?:--port|-p)\s+(\d+)"#, options: .regularExpression) {
                let s = String(line[range])
                if let p = s.components(separatedBy: CharacterSet.whitespaces).last.flatMap(Int.init) { port = p }
            }

            // /GIT/projectname/.venv/bin/zensical -> "projectname"
            let regex = try? NSRegularExpression(pattern: #"/([^/\s]+)/\.venv/bin/zensical"#)
            let nsLine = line as NSString
            if let m = regex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound {
                hints[port] = nsLine.substring(with: m.range(at: 1))
            }
        }
        return hints
    }

    // MARK: - Gateway

    static func scanGateway(showAll: Bool = false) async -> Device? {
        guard let out = await shell("route -n get default 2>/dev/null"),
              let line = out.components(separatedBy: "\n").first(where: { $0.contains("gateway:") }),
              let ip = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces),
              !ip.isEmpty else { return nil }

        let gatewayPorts = [80, 443, 8080, 8443]
        let openPorts = await tcpScanPorts(host: ip, ports: gatewayPorts)
        guard !openPorts.isEmpty else { return nil }

        let services = await fetchServices(host: ip, ports: openPorts, hints: [:], showAll: true)
        guard !services.isEmpty else { return nil }

        return Device(name: "Gateway", ip: ip, isLocal: false, os: nil,
                      online: true, services: services)
    }

    // MARK: - Tailscale

    static func scanTailscaleDevices(showAll: Bool = false) async -> [Device] {
        guard let statusJSON = await tailscaleStatus(),
              let data = statusJSON.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peersData = obj["Peer"] as? [String: Any] else {
            return []
        }

        struct PeerInfo { let name: String; let ip: String; let online: Bool; let os: String? }

        let peers: [PeerInfo] = peersData.compactMap { _, v in
            guard let peer = v as? [String: Any],
                  let ips  = peer["TailscaleIPs"] as? [String],
                  let ip   = ips.first else { return nil }

            // Prefer HostName, but fall back to DNSName if HostName is "localhost" or empty
            let hostName = peer["HostName"] as? String ?? ""
            let dnsFirst = (peer["DNSName"] as? String)?.components(separatedBy: ".").first ?? ""
            let name: String
            if hostName.isEmpty || hostName.lowercased() == "localhost" {
                name = dnsFirst.isEmpty ? ip : dnsFirst
            } else {
                name = hostName.components(separatedBy: ".").first ?? hostName
            }

            return PeerInfo(name: name, ip: ip,
                            online: peer["Online"] as? Bool ?? false,
                            os: peer["OS"] as? String)
        }

        return await withTaskGroup(of: Device.self) { group in
            for peer in peers {
                group.addTask {
                    guard peer.online else {
                        return Device(name: peer.name, ip: peer.ip, isLocal: false,
                                      os: peer.os, online: false, services: [])
                    }
                    let openPorts = await tcpScanPorts(host: peer.ip)
                    let services  = await fetchServices(host: peer.ip, ports: openPorts, hints: [:], os: peer.os, showAll: showAll)
                    return Device(name: peer.name, ip: peer.ip, isLocal: false,
                                  os: peer.os, online: true, services: services)
                }
            }
            var results: [Device] = []
            for await d in group { results.append(d) }
            return results
        }
    }

    // MARK: - Port scanning

    static func tcpScanPorts(host: String, ports portsToScan: [Int]? = nil) async -> [Int] {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for port in portsToScan ?? ports {
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
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { conn.cancel(); finish(false) }
        }
    }

    // MARK: - HTTP title fetching

    static func fetchServices(host: String, ports: [Int], hints: [Int: String], os: String? = nil, showAll: Bool = false) async -> [WebService] {
        let isDarwin = os?.lowercased() == "darwin"
        let lookup = isDarwin ? knownServices.merging(macOnlyServices) { _, new in new } : knownServices
        return await withTaskGroup(of: WebService?.self) { group in
            for port in ports {
                group.addTask {
                    // If we have a known name from pgrep, use it directly
                    if let projectName = hints[port] {
                        let url = URL(string: "http://\(host):\(port)")!
                        return WebService(title: projectName, port: port, url: url, isHTTPS: false)
                    }
                    if let svc = await fetchTitle(host: host, port: port) { return svc }
                    // No HTML title - only show with showAll
                    guard showAll else { return nil }
                    let name = lookup[port] ?? "Port \(port)"
                    let url = URL(string: "http://\(host):\(port)")!
                    return WebService(title: name, port: port, url: url, isHTTPS: false)
                }
            }
            var services: [WebService] = []
            for await s in group { if let s { services.append(s) } }
            return services.sorted { $0.port < $1.port }
        }
    }

    static let httpsFirstPorts: Set<Int> = [443, 8443, 9443]

    static func fetchTitle(host: String, port: Int) async -> WebService? {
        let schemes = httpsFirstPorts.contains(port) ? ["https", "http"] : ["http", "https"]
        for scheme in schemes {
            guard let url = URL(string: "\(scheme)://\(host):\(port)") else { continue }
            if let (title, finalURL) = await httpTitle(url: url) {
                return WebService(title: title, port: port, url: finalURL, isHTTPS: scheme == "https")
            }
        }
        return nil
    }

    static func httpTitle(url: URL) async -> (String, URL)? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.0
        config.timeoutIntervalForResource = 1.5
        let session = URLSession(configuration: config,
                                 delegate: TrustAllCertsDelegate(),
                                 delegateQueue: nil)
        do {
            let (data, response) = try await session.data(from: url)
            // Skip error responses
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return nil }
            let finalURL = (response as? HTTPURLResponse).flatMap { _ in url } ?? url

            guard let html = String(data: data, encoding: .utf8)
                          ?? String(data: data, encoding: .isoLatin1) else { return nil }

            // Extract <title>...</title>
            let title: String
            if let range = html.range(of: #"<title[^>]*>([^<]+)</title>"#,
                                      options: [.regularExpression, .caseInsensitive]) {
                var raw = String(html[range])
                    .replacingOccurrences(of: #"<title[^>]*>"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "</title>", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Decode common HTML entities
                raw = raw
                    .replacingOccurrences(of: "&amp;",  with: "&")
                    .replacingOccurrences(of: "&lt;",   with: "<")
                    .replacingOccurrences(of: "&gt;",   with: ">")
                    .replacingOccurrences(of: "&#39;",  with: "'")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&#160;", with: " ")
                if raw.isEmpty { return nil }
                title = raw
            } else {
                return nil
            }
            return (title, finalURL)
        } catch {
            return nil
        }
    }

    // MARK: - Tailscale + Shell helpers

    static func tailscaleStatus() async -> String? {
        for path in tailscalePaths {
            if let out = await shell("\"\(path)\" status --json 2>/dev/null") {
                return out
            }
        }
        return nil
    }

    static func shell(_ command: String, timeout: TimeInterval = 8.0) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let lock = NSLock()
            var done = false
            let finish: (String?) -> Void = { result in
                lock.lock(); let go = !done; done = true; lock.unlock()
                if go { continuation.resume(returning: result) }
            }

            let p = Process(); let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", command]
            p.standardOutput = pipe
            p.standardError  = Pipe()

            // Kill the process after timeout to prevent hanging
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
                finish(nil)
            }

            DispatchQueue.global(qos: .utility).async {
                do {
                    try p.run()
                    p.waitUntilExit()
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    finish(out?.isEmpty == false ? out : nil)
                } catch {
                    finish(nil)
                }
            }
        }
    }
}

// Accept self-signed certs (needed for home devices like Synology, routers, etc.)
class TrustAllCertsDelegate: NSObject, URLSessionDelegate {
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
