import Foundation

/// The live-session protocol version (openpad/server.py PROTOCOL).
public let protocolVersion = 5

/// The computer's QR code: http://<address>:<port>/app?k=<key> (or /?k= from
/// older versions).
public struct PairingCode: Equatable, Sendable {
    public var host: String  // address:port
    public var key: String

    public init?(_ text: String) {
        guard let u = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              u.scheme == "http", let host = u.host, !host.isEmpty,
              u.path == "/app" || u.path == "/" || u.path.isEmpty,
              let key = u.queryItems?.first(where: { $0.name == "k" })?.value,
              key.count >= 22, key.count <= 64,
              key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }),
              key.unicodeScalars.allSatisfy({ $0.isASCII })
        else { return nil }
        self.host = u.port.map { "\(host):\($0)" } ?? host
        self.key = key
    }
}

/// Encode a value with JSONEncoder and return it as a JSON object for a message.
public func jsonObject<T: Encodable>(_ value: T) -> Any {
    guard let data = try? JSONEncoder().encode(value),
          let obj = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
    return obj
}

/// Decode a JSON object (from a message) into a type.
public func decodeJSON<T: Decodable>(_ type: T.Type, from object: Any?) -> T? {
    guard let object, JSONSerialization.isValidJSONObject(object) || object is [Any],
          let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}

/// A partial notebook for a structural live edit (the "merge" message).
public func partial(_ nb: Notebook, meta: Bool = false, layout: Bool = false, pages: [String] = [],
                    goneP: [String] = []) -> [String: Any] {
    var out: [String: Any] = ["id": nb.id, "goneP": goneP]
    if meta {
        out["title"] = nb.title
        out["size"] = nb.size
        out["metaT"] = nb.metaT
    }
    if layout { out["layout"] = jsonObject(nb.layout) }
    var pageObjects: [String: Any] = [:]
    for id in pages {
        if let p = nb.pages[id] { pageObjects[id] = jsonObject(p.metaOnly) }
    }
    out["pages"] = pageObjects
    return out
}

/// Merge a partial notebook (a "merge" message or part of one) into nb.
public func mergePartial(_ nb: Notebook, _ part: [String: Any]) -> Notebook {
    guard (part["id"] as? String) == nb.id else { return nb }
    var obj: [String: Any] = part
    // What a partial leaves out must lose on merge.
    if obj["title"] == nil {
        obj["title"] = nb.title
        obj["size"] = nb.size
        obj["metaT"] = 0
    }
    if obj["layout"] == nil { obj["layout"] = ["t": 0, "sections": [Any]()] as [String: Any] }
    guard let other = decodeJSON(Notebook.self, from: obj) else { return nb }
    return merge(nb, other)
}
