//
//  HTTPClient.swift
//  Tshunhue
//
//  Provides bounded HTTPS downloads with conditional-request metadata.
//

import Foundation

/// HTTP validators and expiration metadata persisted alongside a response body.
struct HTTPMetadata: Codable, Hashable, Sendable {
    /// The server's entity tag for conditional requests.
    var etag: String?
    /// The server's last-modified validator.
    var lastModified: String?
    /// The response's calculated freshness deadline.
    var expires: Date?
}

/// A validated HTTP response and its cache metadata.
struct HTTPResult: Sendable {
    /// Response bytes, or `nil` for a not-modified response.
    let data: Data?
    /// Validators and freshness metadata from the response.
    let metadata: HTTPMetadata
    /// The underlying HTTP response after redirect handling.
    let response: HTTPURLResponse
}

/// The download interface used by catalog and image repositories.
protocol HTTPFetching: Sendable {
    /// Fetches an HTTPS resource with optional validators and a response-size limit.
    func get(_ url: URL, validators: HTTPMetadata?, byteLimit: Int) async throws -> HTTPResult
}

/// Convenience requests that do not yet have conditional validators.
extension HTTPFetching {
    /// Fetches an HTTPS resource without conditional headers.
    func get(_ url: URL, byteLimit: Int) async throws -> HTTPResult {
        try await get(url, validators: nil, byteLimit: byteLimit)
    }
}

/// Restricts redirects to HTTPS and enforces the catalog redirect limit.
final class SecureRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Protects redirect bookkeeping accessed by URL session delegate queues.
    private let lock = NSLock()
    /// Redirect count keyed by URL session task identifier.
    private var redirectCounts: [Int: Int] = [:]

    /// Accepts a redirect only when it stays on HTTPS and remains under the limit.
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

    /// Releases per-task redirect bookkeeping after a request completes.
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

/// An ephemeral URL session client that accepts only bounded HTTPS responses.
struct HTTPClient: HTTPFetching, Sendable {
    /// The ephemeral session used for all downloads.
    private let session: URLSession

    /// Creates an ephemeral session with conservative request and resource timeouts.
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: SecureRedirectDelegate(), delegateQueue: nil)
    }

    /// Performs a conditional HTTPS GET and validates status and response size.
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

    /// Derives an expiration date from standard HTTP cache headers.
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

/// Parses RFC 1123 HTTP date values using a stable POSIX locale.
private enum HTTPDateFormatter {
    /// The shared RFC 1123 formatter.
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()

    /// Parses a date from an HTTP header value.
    static func date(from string: String) -> Date? { formatter.date(from: string) }
}

/// User-presentable HTTP policy and response failures.
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
