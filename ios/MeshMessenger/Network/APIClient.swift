import Foundation

enum APIError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(Int, body: String)
    case decoding(Error)
    case encoding(Error)
    case unauthorized
    case rateLimited
    case transport(Error)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from server"
        case .httpStatus(let code, let body): return "HTTP \(code): \(body)"
        case .decoding(let e): return "Decode error: \(e.localizedDescription)"
        case .encoding(let e): return "Encode error: \(e.localizedDescription)"
        case .unauthorized: return "Session expired"
        case .rateLimited: return "Too many requests"
        case .transport(let e): return "Network error: \(e.localizedDescription)"
        case .notAuthenticated: return "Not signed in"
        }
    }
}

protocol AccessTokenProvider: Sendable {
    func currentAccessToken() async -> String?
    func refresh() async throws -> String
}

actor APIClient {
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: AccessTokenProvider?

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(baseURL: URL = AppConfig.backendBaseURL, tokenProvider: AccessTokenProvider? = nil) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
        self.tokenProvider = tokenProvider
    }

    func get<Response: Decodable>(_ path: String, query: [URLQueryItem] = [], authenticated: Bool = true) async throws -> Response {
        let request = try await buildRequest(path: path, method: "GET", body: Optional<EmptyBody>.none, query: query, authenticated: authenticated)
        return try await send(request, authenticated: authenticated)
    }

    func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body, authenticated: Bool = true) async throws -> Response {
        let request = try await buildRequest(path: path, method: "POST", body: body, query: [], authenticated: authenticated)
        return try await send(request, authenticated: authenticated)
    }

    func postNoContent<Body: Encodable>(_ path: String, body: Body, authenticated: Bool = true) async throws {
        let request = try await buildRequest(path: path, method: "POST", body: body, query: [], authenticated: authenticated)
        let _: EmptyBody = try await sendNoContent(request, authenticated: authenticated)
    }

    func put<Body: Encodable, Response: Decodable>(_ path: String, body: Body, authenticated: Bool = true) async throws -> Response {
        let request = try await buildRequest(path: path, method: "PUT", body: body, query: [], authenticated: authenticated)
        return try await send(request, authenticated: authenticated)
    }

    func delete(_ path: String, authenticated: Bool = true) async throws {
        let request = try await buildRequest(path: path, method: "DELETE", body: Optional<EmptyBody>.none, query: [], authenticated: authenticated)
        let _: EmptyBody = try await sendNoContent(request, authenticated: authenticated)
    }

    func deleteWithBody<Body: Encodable>(_ path: String, body: Body, authenticated: Bool = true) async throws {
        let request = try await buildRequest(path: path, method: "DELETE", body: body, query: [], authenticated: authenticated)
        let _: EmptyBody = try await sendNoContent(request, authenticated: authenticated)
    }

    // MARK: - private

    private func buildRequest<Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        query: [URLQueryItem],
        authenticated: Bool
    ) async throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body = body, !(body is EmptyBody) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do { request.httpBody = try Self.encoder.encode(body) }
            catch { throw APIError.encoding(error) }
        }

        if authenticated {
            guard let provider = tokenProvider else { throw APIError.notAuthenticated }
            guard let token = await provider.currentAccessToken() else { throw APIError.notAuthenticated }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest, authenticated: Bool, retried: Bool = false) async throws -> Response {
        let (data, response) = try await performRequest(request)
        let http = try ensureHttp(response)

        if http.statusCode == 401 && authenticated && !retried, let provider = tokenProvider {
            let newToken = try await provider.refresh()
            var retry = request
            retry.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            return try await send(retry, authenticated: authenticated, retried: true)
        }

        try ensureSuccess(http, data: data)
        do { return try Self.decoder.decode(Response.self, from: data) }
        catch { throw APIError.decoding(error) }
    }

    private func sendNoContent<Body>(_ request: URLRequest, authenticated: Bool, retried: Bool = false) async throws -> Body where Body: Decodable {
        let (data, response) = try await performRequest(request)
        let http = try ensureHttp(response)

        if http.statusCode == 401 && authenticated && !retried, let provider = tokenProvider {
            let newToken = try await provider.refresh()
            var retry = request
            retry.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            return try await sendNoContent(retry, authenticated: authenticated, retried: true)
        }

        try ensureSuccess(http, data: data)
        return EmptyBody() as! Body
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) }
        catch { throw APIError.transport(error) }
    }

    private func ensureHttp(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return http
    }

    private func ensureSuccess(_ http: HTTPURLResponse, data: Data) throws {
        switch http.statusCode {
        case 200..<300: return
        case 401: throw APIError.unauthorized
        case 429: throw APIError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpStatus(http.statusCode, body: body)
        }
    }
}

struct EmptyBody: Codable {}
