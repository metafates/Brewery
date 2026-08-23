//
//  UITestStubURLProtocol.swift
//  Brewery
//
//  Created by vzbarashchenko on 23.08.2026.
//

import Foundation

/// The harness's network boundary: answers every request on a stubbed session from files under
/// `<root>/http/`, keyed by the request path with `/` folded to `_` (`/api/formula.json` →
/// `api_formula.json`). Optional siblings: `<key>.status` overrides the 200, and `<key>.etag`
/// earns a real 304 when the request's `If-None-Match` matches — so the catalog's conditional
/// branch is exercised end to end rather than stubbed away. An unfixtured path 404s naming the
/// key it wanted; for icons that is the desired deterministic path (non-2xx → negative marker →
/// glyph fallback). Installed per-session on the harness's ephemeral configurations, never via
/// `URLProtocol.registerClass`, which would capture `URLSession.shared` for the whole process.
///
/// `nonisolated`: URLProtocol callbacks arrive on URLSession loading threads, so under the
/// project's MainActor default isolation the whole type opts out.
final nonisolated class UITestStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Non-private so a unit test can pin the key grammar against the five catalog URLs.
    static func fixtureKey(for url: URL) -> String {
        url.path(percentEncoded: false).split(separator: "/").joined(separator: "_")
    }

    override func startLoading() {
        guard let url = request.url, let directory = UITestMode.httpFixturesDirectory else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let key = Self.fixtureKey(for: url)
        guard let body = try? Data(contentsOf: directory.appending(path: key,
                                                                   directoryHint: .notDirectory)) else {
            respond(to: url, status: 404, body: Data("UI-test stub: no fixture named \(key)".utf8))
            return
        }
        let etag = sibling(key + ".etag", in: directory)
        if let etag, request.value(forHTTPHeaderField: "If-None-Match") == etag {
            respond(to: url, status: 304, body: Data(), etag: etag)
            return
        }
        let status = sibling(key + ".status", in: directory).flatMap { Int($0) } ?? 200
        respond(to: url, status: status, body: body, etag: etag)
    }

    override func stopLoading() {}

    private func respond(to url: URL, status: Int, body: Data, etag: String? = nil) {
        var headers: [String: String] = [:]
        if let etag { headers["ETag"] = etag }
        guard let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func sibling(_ name: String, in directory: URL) -> String? {
        (try? String(contentsOf: directory.appending(path: name, directoryHint: .notDirectory),
                     encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
