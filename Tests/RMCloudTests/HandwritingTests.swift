import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import RMCloud

@Test func syntheticCloudRecognition() throws {
    let answer = Data("""
        {"type":"Raw Content","elements":[{"type":"Text","label":"hello","words":[
          {"label":"hello","bounding-box":{"x":11.2543859,"y":13.8166666,"width":15.7444086,"height":8.8513155}}
        ]}]}
        """.utf8)
    let result = try HandwritingCodec.result(answer)
    #expect(result.text == "hello")
    #expect(result.words.first?.bounds?.width == 15.7444086)
    let drawing = Data(#"{"type":"Raw Content","elements":[{"type":"Raw Content","kind":"non-text"}]}"#.utf8)
    #expect(try HandwritingCodec.result(drawing).text.isEmpty)
    #expect(throws: (any Error).self) { try HandwritingCodec.result(Data("{}".utf8)) }
    #expect(throws: HandwritingError.self) { try HandwritingCodec.body([.init(x: [1], y: [])], language: "en-US") }
    let body = try HandwritingCodec.body([.init(x: [2], y: [3])], language: "en-US")
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let groups = try #require(json["strokeGroups"] as? [[String: [[String: [Double]]]]])
    #expect(groups.first?["strokes"]?.first?["x"] == [20])
}

@Test func handwritingUsesTheSessionAndSkipsBlankPages() async throws {
    let store = InMemorySecrets()
    let token = syntheticToken(claims: #"{"exp":4102444800}"#)
    try store.save(token, as: .userToken)
    try store.save("test device", as: .deviceToken)
    let transport = ScriptedTransport([.init(body: #"{"type":"Raw Content","elements":[]}"#)])
    let client = CloudClient(transport: transport, tokens: TokenProvider(transport: transport, secrets: store))
    #expect(try await client.recognizeHandwriting([]).text.isEmpty)
    #expect(transport.requests.isEmpty)
    let result = try await client.recognizeHandwriting([.init(x: [1], y: [2])])
    #expect(result.text.isEmpty)
    let request = try #require(transport.requests.first)
    #expect(request.url?.path == "/convert/v1/handwriting")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token)
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.myscript.jiix")
}

private func handwritingClient(_ transport: ScriptedTransport, sleeper: RecordingSleeper = RecordingSleeper()) throws -> CloudClient {
    let store = InMemorySecrets()
    try store.save(syntheticToken(claims: #"{"exp":4102444800}"#), as: .userToken)
    return CloudClient(transport: transport, tokens: TokenProvider(transport: transport, secrets: store), sleeper: sleeper)
}

@Test func handwritingRequestLimits() async throws {
    let success = ScriptedTransport.Reply(body: #"{"type":"Text","label":"ok"}"#)
    let transport = ScriptedTransport(Array(repeating: success, count: 4))
    let client = try handwritingClient(transport)
    let limits = HandwritingLimits(strokes: 2, points: 3, languageBytes: 2)
    let one = HandwritingStroke(x: [1], y: [1])
    let two = HandwritingStroke(x: [1, 2], y: [1, 2])
    for (strokes, language) in [([one, one, one], "en"), ([two, two], "en"), ([one], "éa")] {
        await #expect(throws: HandwritingError.requestTooLarge) {
            try await client.recognizeHandwriting(strokes, language: language, limits: limits)
        }
        #expect(transport.requests.isEmpty)
    }
    let result = try await client.recognizeHandwriting([one, two], language: "en", limits: limits)
    #expect(result.text == "ok")
    #expect(transport.requests.count == 1)
}

@Test func handwritingHonorsRetryAfter() async throws {
    let transport = ScriptedTransport([
        .init(status: 429, headers: ["Retry-After": "7"]),
        .init(body: #"{"type":"Text","label":"retried"}"#)
    ])
    let sleeper = RecordingSleeper()
    let client = try handwritingClient(transport, sleeper: sleeper)
    let result = try await client.recognizeHandwriting([.init(x: [1], y: [2])])
    #expect(result.text == "retried")
    #expect(sleeper.delays == [.seconds(7)])
    #expect(transport.requests.count == 2)
}

@Test func handwritingValidatesRootType() throws {
    #expect(throws: HandwritingError.invalidResponse) {
        try HandwritingCodec.result(Data(#"{"type":"Error","elements":[]}"#.utf8))
    }
    let result = try HandwritingCodec.result(Data(#"{"type":"Raw Content","elements":[]}"#.utf8))
    #expect(result.text.isEmpty)
    #expect(result.words.isEmpty)
}
