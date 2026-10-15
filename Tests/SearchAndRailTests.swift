import XCTest
@testable import RhineLab

private final class SearchFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0 // protected by lock
    nonisolated(unsafe) private static var failFirst = false // protected by lock
    private var work: DispatchWorkItem?
    static func reset(fail: Bool = false) { lock.lock(); count = 0; failFirst = fail; lock.unlock() }
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; let status = Self.failFirst && Self.count == 1 ? 503 : 200; Self.lock.unlock()
        let work = DispatchWorkItem { [self] in
            let data = Data(#"{"code":200,"data":[{"songmid":"1","name":"Fixture","singer":"Artist","albumName":"Album","interval":"3:00"}]}"#.utf8)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.04, execute: work)
    }
    override func stopLoading() { work?.cancel() }
}

@MainActor final class SearchAndRailTests: XCTestCase {
    private func service() -> MusicService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SearchFixtureProtocol.self]
        return MusicService(session: URLSession(configuration: config))
    }
    func testConcurrentAndRepeatedSearchesReuseOneRequest() async throws {
        SearchFixtureProtocol.reset()
        let service = service()
        async let first = service.search("Fixture")
        async let second = service.search(" fixture ")
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b); XCTAssertEqual(a.first?.title, "Fixture")
        _ = try await service.search("FIXTURE")
        XCTAssertEqual(SearchFixtureProtocol.requests, 1)
    }
    func testFailedSearchCanBeRetried() async throws {
        SearchFixtureProtocol.reset(fail: true)
        let service = service()
        do { _ = try await service.search("Fixture"); XCTFail("fixture should fail once") } catch { }
        let songs = try await service.search("Fixture")
        XCTAssertEqual(songs.count, 1); XCTAssertEqual(SearchFixtureProtocol.requests, 2)
    }
    func testRailWindowStaysBoundedAndIncludesSelectedSong() {
        XCTAssertTrue(MusicRail.window(count: 0, selected: 0).isEmpty)
        for count in [1, 8, 30, 1000] {
            for selected in 0..<count {
                let window = MusicRail.window(count: count, selected: selected)
                XCTAssertTrue(window.contains(selected))
                XCTAssertLessThanOrEqual(window.count, 15)
                XCTAssertGreaterThanOrEqual(window.lowerBound, 0)
                XCTAssertLessThanOrEqual(window.upperBound, count)
            }
        }
    }
}
