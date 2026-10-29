import Foundation

/// The live-session WebSocket to the computer, reconnecting on its own.
/// Messages are JSON objects; binary messages are live desktop-window frames.
@MainActor
final class LiveSession {
    var onMessage: (([String: Any]) -> Void)?
    var onFrame: ((Data) -> Void)?
    var onStatus: ((Bool) -> Void)?
    private(set) var connected = false

    private let url: () -> URL
    private var task: URLSessionWebSocketTask?
    private var closed = false
    private var retry: Double = 0.25
    private let session = URLSession(configuration: .default)

    init(url: @escaping () -> URL) {
        self.url = url
    }

    func start() {
        closed = false
        open()
    }

    func stop() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setConnected(false)
    }

    private func open() {
        guard !closed else { return }
        let t = session.webSocketTask(with: url())
        t.maximumMessageSize = 64 * 1024 * 1024  // a whole notebook arrives in one message
        task = t
        t.resume()
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                switch result {
                case .success(let message):
                    if !self.connected {
                        self.retry = 0.25
                        self.setConnected(true)
                    }
                    switch message {
                    case .string(let text):
                        if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                            self.onMessage?(obj)
                        }
                    case .data(let data):
                        self.onFrame?(data)
                    @unknown default:
                        break
                    }
                    self.receive(t)
                case .failure:
                    self.dropped(t)
                }
            }
        }
    }

    private func dropped(_ t: URLSessionWebSocketTask) {
        guard task === t else { return }
        task = nil
        setConnected(false)
        guard !closed else { return }
        let wait = retry
        retry = min(retry * 2, 8)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            self?.open()
        }
    }

    private func setConnected(_ value: Bool) {
        guard connected != value else { return }
        connected = value
        onStatus?(value)
    }

    func send(_ obj: [String: Any]) {
        guard connected, let task, JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }
}
