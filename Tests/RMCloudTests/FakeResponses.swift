// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The answers a fake transport hands back.
//
// `HTTPURLResponse.init` is failable and never fails on anything these suites
// hand it, so the unwrap is here, in one place with a sentence attached, rather
// than at each of the eleven call sites with none: a forced unwrap in a test ends
// the whole run with a signal, and the case that failed is then the one thing the
// output does not name.
//
// A copy of one the application this package came out of keeps for its own
// suites. Test doubles are the one thing worth duplicating across a repository
// boundary: the alternative is a package that cannot be tested without the
// application it was extracted from.

extension HTTPURLResponse {
    /// The answer a fake transport hands back for `url`.
    static func fake(
        _ status: Int = 200,
        for url: URL,
        headers: [String: String] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> HTTPURLResponse {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            preconditionFailure("no response for \(status) at \(url)", file: file, line: line)
        }
        return response
    }

    /// The answer to a request, addressed to whatever the request asked for.
    ///
    /// A request without a URL never reaches a transport — `URLSession` will not
    /// send one — so it is a broken double rather than a case to answer.
    static func fake(
        _ status: Int = 200,
        for request: URLRequest,
        headers: [String: String] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> HTTPURLResponse {
        guard let url = request.url else {
            preconditionFailure("a request with no URL reached a fake transport", file: file, line: line)
        }
        return fake(status, for: url, headers: headers, file: file, line: line)
    }
}
