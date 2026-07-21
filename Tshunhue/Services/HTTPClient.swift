import Foundation

struct HTTPMetadata: Codable, Hashable, Sendable {
    var etag: String?
    var lastModified: String?
    var expires: Date?
}

struct HTTPResult: Sendable {
    let data: Data?
    let metadata: HTTPMetadata
    let response: HTTPURLResponse
}

protocol HTTPFetching: Sendable {
    func get(_ url: URL, validators: HTTPMetadata?, byteLimit: Int) async throws -> HTTPResult
}

extension HTTPFetching {
    func get(_ url: URL, byteLimit: Int) async throws -> HTTPResult {
        try await get(url, validators: nil, byteLimit: byteLimit)
    }
}

final class SecureRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirectCounts: [Int: Int] = [:]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        let count = (redirectCounts[task.taskIdentifier] ?? 0) + 1
        redirectCounts[task.taskIdentifier] = count
        lock.unlock()

        guard count <= CatalogLimits.redirects,
              request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        lock.lock()
        redirectCounts.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
    }
}

struct HTTPClient: HTTPFetching, Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: SecureRedirectDelegate(), delegateQueue: nil)
    }

    func get(_ url: URL, validators: HTTPMetadata? = nil, byteLimit: Int) async throws -> HTTPResult {
        guard url.scheme?.lowercased() == "https" else { throw HTTPClientError.insecureURL }
        var request = URLRequest(url: url)
        request.setValue("application/json, image/*;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
        if let etag = validators?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified = validators?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw HTTPClientError.invalidResponse }
        guard response.url?.scheme?.lowercased() == "https" else { throw HTTPClientError.insecureURL }
        guard response.statusCode == 304 || (200..<300).contains(response.statusCode) else {
            throw HTTPClientError.status(response.statusCode)
        }
        guard data.count <= byteLimit else { throw HTTPClientError.tooLarge }
        let metadata = HTTPMetadata(
            etag: response.value(forHTTPHeaderField: "ETag"),
            lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
            expires: Self.expirationDate(for: response)
        )
        return HTTPResult(data: response.statusCode == 304 ? nil : data, metadata: metadata, response: response)
    }

    private static func expirationDate(for response: HTTPURLResponse) -> Date? {
        if let cacheControl = response.value(forHTTPHeaderField: "Cache-Control") {
            for directive in cacheControl.split(separator: ",") {
                let pair = directive.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                if pair.first?.lowercased() == "max-age", pair.count == 2, let seconds = TimeInterval(pair[1]) {
                    return Date().addingTimeInterval(seconds)
                }
            }
        }
        if let expires = response.value(forHTTPHeaderField: "Expires") {
            return HTTPDateFormatter.date(from: expires)
        }
        return nil
    }
}

private enum HTTPDateFormatter {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()

    static func date(from string: String) -> Date? { formatter.date(from: string) }
}

enum HTTPClientError: LocalizedError {
    case insecureURL
    case invalidResponse
    case status(Int)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .insecureURL: "Only HTTPS downloads are allowed."
        case .invalidResponse: "The server returned an invalid response."
        case .status(let code): "The server returned HTTP \(code)."
        case .tooLarge: "The download exceeded its allowed size."
        }
    }
}
