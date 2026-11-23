// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A pen trajectory in reMarkable scene units.
public struct HandwritingStroke: Sendable {
    public let x: [Double]
    public let y: [Double]

    public init(x: [Double], y: [Double]) {
        self.x = x
        self.y = y
    }
}

/// Word bounds are expressed in the millimetres returned by MyScript JIIX.
public struct HandwritingBox: Decodable, Sendable {
    public let x, y, width, height: Double
}

public struct HandwritingWord: Decodable, Sendable {
    public let label: String
    public let bounds: HandwritingBox?

    enum CodingKeys: String, CodingKey {
        case label
        case bounds = "bounding-box"
    }
}

public struct HandwritingResult: Sendable {
    public let text: String
    public let words: [HandwritingWord]
}

private struct Element: Decodable {
    let type: String
    let label: String?
    let words: [HandwritingWord]?
    let elements: [Element]?
}

struct HandwritingLimits: Sendable {
    let strokes: Int
    let points: Int
    let languageBytes: Int

    static let standard = Self(strokes: 10_000, points: 100_000, languageBytes: 64)
}

enum HandwritingCodec {
    static func body(
        _ strokes: [HandwritingStroke], language: String, limits: HandwritingLimits = .standard
    ) throws -> Data {
        guard strokes.count <= limits.strokes, language.utf8.count <= limits.languageBytes else {
            throw HandwritingError.requestTooLarge
        }
        var remainingPoints = limits.points
        for stroke in strokes {
            guard stroke.x.count == stroke.y.count else { throw HandwritingError.invalidStroke }
            guard stroke.x.count <= remainingPoints else { throw HandwritingError.requestTooLarge }
            remainingPoints -= stroke.x.count
        }

        var ink = [[String: [Double]]]()
        for stroke in strokes {
            guard !stroke.x.isEmpty else { continue }
            let x = stroke.x.map { $0 * 10 }
            let y = stroke.y.map { $0 * 10 }
            guard x.allSatisfy(\.isFinite), y.allSatisfy(\.isFinite) else { throw HandwritingError.invalidStroke }
            ink.append(["x": x, "y": y])
        }
        guard !ink.isEmpty else { return Data() }
        let tag = language.replacingOccurrences(of: "-", with: "_")
        let config: [String: Any] = [
            "lang": tag.isEmpty ? "en_US" : tag,
            "export": ["jiix": ["strokes": false, "text": ["chars": false, "words": true]]],
            "raw-content": ["recognition": ["text": true, "shape": false]]
        ]
        return try JSONSerialization.data(withJSONObject: [
            "xDPI": 2280, "yDPI": 2280, "width": 14040, "height": 18720,
            "contentType": "Raw Content", "configuration": config, "strokeGroups": [["strokes": ink]]
        ])
    }

    static func result(_ data: Data) throws -> HandwritingResult {
        let root = try JSONDecoder().decode(Element.self, from: data)
        guard root.type == "Text" || (root.type == "Raw Content" && root.elements != nil) else { throw HandwritingError.invalidResponse }
        var labels: [String] = [], words: [HandwritingWord] = []
        func visit(_ item: Element) throws {
            if item.type == "Text" {
                guard let label = item.label else { throw HandwritingError.invalidResponse }
                labels.append(label)
                words += item.words ?? []
            } else {
                for child in item.elements ?? [] { try visit(child) }
            }
        }
        try visit(root)
        return HandwritingResult(text: labels.joined(separator: "\n"), words: words)
    }
}

@frozen public enum HandwritingError: Error {
    case invalidStroke, invalidResponse, requestTooLarge
}

extension CloudClient {
    /// Convert one page or selection using the account session. No document ID is sent.
    public func recognizeHandwriting(_ strokes: [HandwritingStroke], language: String = "en_US") async throws -> HandwritingResult {
        try await recognizeHandwriting(strokes, language: language, limits: .standard)
    }

    func recognizeHandwriting(
        _ strokes: [HandwritingStroke], language: String, limits: HandwritingLimits
    ) async throws -> HandwritingResult {
        let data = try HandwritingCodec.body(strokes, language: language, limits: limits)
        guard !data.isEmpty else { return HandwritingResult(text: "", words: []) }
        let answer: Data = try await withReauth { token in
            let url = await hosts().syncHost.appending(path: "convert/v1/handwriting")
            var request = authorizedRequest(for: url, name: nil, token: token)
            request.httpMethod = "POST"
            request.httpBody = data
            request.timeoutInterval = 70
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/vnd.myscript.jiix", forHTTPHeaderField: "Accept")
            let transport = transport
            return try await attempt(url) { [request] in
                let (answer, response) = try await transport.send(request)
                try transport.validate(response, body: answer)
                return answer
            }
        }
        return try HandwritingCodec.result(answer)
    }
}
