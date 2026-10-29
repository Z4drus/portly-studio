import Foundation

/// What Talvo answered when it refused or failed.
struct TalvoRequestError: Error, LocalizedError, Hashable {
    enum Kind: Hashable {
        /// The token is missing, unknown, revoked or expired.
        case unauthenticated
        /// The token lacks the scope, or the person may not see this.
        case forbidden
        case notFound
        case rateLimited
        case invalidServer
        case network(String)
        case server(status: Int, code: String?, message: String)
    }

    var kind: Kind

    var errorDescription: String? {
        switch kind {
        case .unauthenticated: return "Talvo refused the token: it is unknown, revoked or expired."
        case .forbidden: return "This token is not allowed to do that."
        case .notFound: return "Talvo has no such item."
        case .rateLimited: return "Talvo asked to slow down; try again in a moment."
        case .invalidServer: return "The Talvo address must be an https URL."
        case .network(let message): return message
        case .server(let status, _, let message): return message.isEmpty ? "Talvo answered \(status)." : message
        }
    }
}

/// One event of the `/events` stream.
enum TalvoStreamEvent: Equatable {
    /// The journal moved to this sequence number.
    case seq(Int)
    /// A heartbeat: the stream is alive.
    case ping
    /// The token was revoked: the server is about to close the stream.
    case revoked
    /// A fourth stream opened with this token and this one was dropped for
    /// it; reconnecting at once would just push another one out.
    case replaced
}

/// Talks to Talvo's `/api/portly` with a device token. Stateless: every call
/// is one request, the center above keeps the data.
struct TalvoClient {
    let baseURL: URL
    let token: String

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "Portly Studio"]
        return URLSession(configuration: configuration)
    }()

    /// A separate session for the event stream: no request timeout, since a
    /// quiet stream only shows a heartbeat every 25 seconds.
    private static let streamSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = .infinity
        configuration.httpAdditionalHeaders = ["User-Agent": "Portly Studio"]
        return URLSession(configuration: configuration)
    }()

    /// The server address a person typed, made usable: scheme added, path and
    /// trailing slash dropped. Nil when it cannot be a Talvo server.
    static func normalizedBaseURL(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "https://" + value }
        guard var components = URLComponents(string: value), let host = components.host, !host.isEmpty else { return nil }
        // The token travels in a header: only https, or the loopback while
        // developing against a local Talvo.
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard components.scheme == "https" || (components.scheme == "http" && isLoopback) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    // MARK: Reads

    func me() async throws -> TalvoIdentity {
        try await get("me")
    }

    func bootstrap() async throws -> TalvoBootstrap {
        try await get("bootstrap")
    }

    func sync(since seq: Int) async throws -> TalvoSyncDelta {
        try await get("sync", query: [URLQueryItem(name: "since", value: String(seq))])
    }

    func project(_ ref: String) async throws -> TalvoProjectDetail {
        struct Envelope: Decodable { var project: TalvoProjectDetail }
        let envelope: Envelope = try await get("projects/\(encode(ref))")
        return envelope.project
    }

    func issue(_ ref: String) async throws -> TalvoIssueDetail {
        struct Envelope: Decodable { var issue: TalvoIssueDetail }
        let envelope: Envelope = try await get("issues/\(encode(ref))")
        return envelope.issue
    }

    func document(_ ref: String) async throws -> TalvoDocumentDetail {
        struct Envelope: Decodable { var document: TalvoDocumentDetail }
        let envelope: Envelope = try await get("documents/\(encode(ref))")
        return envelope.document
    }

    // MARK: Writes (need the `write` scope)

    func addComment(issue ref: String, body: String) async throws -> TalvoComment {
        struct Envelope: Decodable { var comment: TalvoComment }
        let envelope: Envelope = try await send("POST", "issues/\(encode(ref))/comments", body: ["body": body])
        return envelope.comment
    }

    /// Only `status`, `assignee` and `priority` are accepted by the server.
    func updateIssue(_ ref: String, fields: [String: Any]) async throws -> TalvoIssue {
        struct Envelope: Decodable { var issue: TalvoIssue }
        let envelope: Envelope = try await send("PATCH", "issues/\(encode(ref))", body: fields)
        return envelope.issue
    }

    // MARK: Event stream

    /// The `/events` stream as a sequence of events. Ends when the server
    /// closes it or the task is cancelled; the caller reconnects.
    func events() -> AsyncThrowingStream<TalvoStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = self.request(for: "events")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    // Compression would let the proxy hold messages back.
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    let (bytes, response) = try await Self.streamSession.bytes(for: request)
                    try Self.check(response, data: nil)
                    var eventName = "message"
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if let parsed = Self.parseStreamLine(line, eventName: &eventName) {
                            continuation.yield(parsed)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reads one line of Server-Sent Events. Returns an event when the line
    /// carries data; remembers the pending `event:` name in between.
    static func parseStreamLine(_ line: String, eventName: inout String) -> TalvoStreamEvent? {
        if line.hasPrefix("event:") {
            eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            return nil
        }
        guard line.hasPrefix("data:") else {
            if line.isEmpty { eventName = "message" }
            return nil
        }
        let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        defer { eventName = "message" }
        switch eventName {
        case "ping": return .ping
        case "seq": return Int(data).map { .seq($0) }
        case "revoked": return .revoked
        case "replaced": return .replaced
        default: return nil
        }
    }

    // MARK: Plumbing

    private func encode(_ ref: String) -> String {
        ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref
    }

    private func request(for path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = "/api/portly/" + path
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url ?? baseURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let request = request(for: path, query: query)
        return try await perform(request)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any]) async throws -> T {
        var request = request(for: path)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request)
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw Self.mapped(error)
        }
        try Self.check(response, data: data)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw TalvoRequestError(kind: .server(status: 200, code: "DECODE", message: "Talvo answered something Portly does not understand (\(error.localizedDescription))."))
        }
    }

    static let decoder = JSONDecoder()

    private static func check(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        var message = ""
        var code: String?
        if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            message = object["error"] as? String ?? ""
            code = object["code"] as? String
        }
        switch http.statusCode {
        case 401: throw TalvoRequestError(kind: .unauthenticated)
        case 403: throw TalvoRequestError(kind: .forbidden)
        case 404: throw TalvoRequestError(kind: .notFound)
        case 429: throw TalvoRequestError(kind: .rateLimited)
        default: throw TalvoRequestError(kind: .server(status: http.statusCode, code: code, message: message))
        }
    }

    private static func mapped(_ error: Error) -> Error {
        if error is TalvoRequestError || error is CancellationError { return error }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return CancellationError() }
        return TalvoRequestError(kind: .network(nsError.localizedDescription))
    }
}
