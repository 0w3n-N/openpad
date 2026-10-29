import Foundation
import OpenPadCore

struct ConnectError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct HTTPError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// The computer running OpenPad, reached over the local network (plain HTTP,
/// like the Safari copy; App Transport Security allows local addresses).
/// Every request carries the key.
final class ServerLink: @unchecked Sendable {
    private(set) var base: URL
    let key: String
    let name: String
    private(set) var alts: [URL]
    var onBaseChange: ((ServerLink) -> Void)?

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 600
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    init(base: URL, key: String, name: String, alts: [URL]) {
        self.base = base
        self.key = key
        self.name = name
        self.alts = alts.filter { $0 != base }
    }

    convenience init?(saved: SavedLink) {
        guard let base = URL(string: saved.base) else { return nil }
        self.init(base: base, key: saved.key, name: saved.name, alts: saved.alts.compactMap(URL.init(string:)))
    }

    var saved: SavedLink {
        SavedLink(base: base.absoluteString, key: key, name: name, alts: alts.map(\.absoluteString))
    }

    var displayName: String { name.isEmpty ? (base.host ?? "your computer") : name }

    // MARK: connecting

    /// Connect with the key from the computer's QR code (or from a PIN).
    static func connect(host: String, key: String) async throws -> ServerLink {
        guard let base = URL(string: "http://\(host)") else { throw ConnectError(message: "That address isn't valid.") }
        var req = URLRequest(url: base.appendingPathComponent("api/pairing"))
        req.setValue(key, forHTTPHeaderField: "X-OpenPad-Key")
        req.timeoutInterval = 10
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw ConnectError(message: "Couldn't reach \(host). Check that OpenPad is switched on there and that both are on the same Wi-Fi. "
                + "If iPadOS asked to find devices on your local network, allow it (Settings › Privacy & Security › Local Network › OpenPad).")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 { throw ConnectError(message: "That code is out of date. Show the QR code on the computer again and rescan.") }
        guard status == 200, let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectError(message: "The computer answered with an error (\(status)). Is it running OpenPad 0.5.1 or newer?")
        }
        // Other addresses of the same computer (e.g. omarchy.local), tried if its IP changes.
        let alts = ((info["addresses"] as? [String]) ?? []).compactMap { URL(string: "http://\($0)") }
        return ServerLink(base: base, key: key, name: (info["name"] as? String) ?? "", alts: alts)
    }

    /// Trade the 6-digit PIN shown on the computer for the key.
    static func pair(address: String, pin: String) async throws -> ServerLink {
        var host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        host = host.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if !host.contains(":") { host += ":8770" }
        guard let url = URL(string: "http://\(host)/api/pair") else { throw ConnectError(message: "That address isn't valid.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["pin": pin.trimmingCharacters(in: .whitespaces)])
        req.timeoutInterval = 10
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw ConnectError(message: "Couldn't reach \(host). Check the address and that both are on the same Wi-Fi.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = obj["k"] as? String else {
            throw ConnectError(message: status == 403 ? "Wrong or expired PIN. Check the PIN on the computer and try again."
                                                      : "Connecting failed (\(status)).")
        }
        return try await connect(host: host, key: key)
    }

    // MARK: requests

    private func request(_ path: String, base: URL, method: String, body: Data?, headers: [String: String]) -> URLRequest {
        var req = URLRequest(url: URL(string: path, relativeTo: base)!.absoluteURL)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(key, forHTTPHeaderField: "X-OpenPad-Key")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    /// One API call. If the computer is unreachable at its usual address, its
    /// other addresses are tried and the one that works is kept.
    func call(_ path: String, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]) async throws -> Data {
        var lastError: Error = URLError(.cannotConnectToHost)
        for (i, candidate) in ([base] + alts).enumerated() {
            do {
                let (data, response) = try await session.data(for: request(path, base: candidate, method: method, body: body, headers: headers))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if i > 0 {
                    alts = [base] + alts.filter { $0 != candidate }
                    base = candidate
                    onBaseChange?(self)
                }
                guard (200..<300).contains(status) else {
                    let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    throw HTTPError(status: status, message: msg ?? "\(method) \(path) failed (\(status))")
                }
                return data
            } catch let e as HTTPError {
                throw e
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func json(_ path: String, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]) async throws -> [String: Any] {
        let data = try await call(path, method: method, body: body, headers: headers)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    var webSocketURL: URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.scheme = "ws"
        c.path = "/ws"
        c.queryItems = [URLQueryItem(name: "role", value: "pad"), URLQueryItem(name: "v", value: String(protocolVersion)),
                        URLQueryItem(name: "k", value: key)]
        return c.url!
    }

    func qrURL(_ which: String) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = "/api/qr.svg"
        c.queryItems = [URLQueryItem(name: "k", value: key), URLQueryItem(name: "for", value: which)]
        return c.url!
    }
}
