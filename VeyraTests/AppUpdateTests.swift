import Foundation
import XCTest

final class AppUpdateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func response(_ status: Int = 200, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: GitHubReleaseClient.endpoint, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    private func data(tag: String = "v1.2.0", url: String = "https://github.com/yuzio-ai/veyra/releases/tag/v1.2.0",
                      draft: Bool = false, prerelease: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tag_name": tag, "html_url": url, "draft": draft, "prerelease": prerelease])
    }

    func testNumericVersionComparisonAndSupportedFormat() throws {
        XCTAssertEqual(AppVersion("v1.2.0"), AppVersion("1.2.0"))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.9.0")), try XCTUnwrap(AppVersion("1.10.0")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.99.99")), try XCTUnwrap(AppVersion("2.0.0")))
        for text in ["", "1", "1.2", "1.2.3.4", "1..3", "1.2.-1", "1.2.3-beta", " 1.2.3", "1.2.3+2", "V1.2.3", "１.2.3", "999999999999999999999999.2.3"] {
            XCTAssertNil(AppVersion(text), text)
        }
    }

    func testStableReleaseAndCacheRoundTrip() throws {
        let release = try GitHubReleaseClient.parse(data: data(), response: response(), now: now)
        XCTAssertEqual(release.version, "1.2.0")
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/yuzio-ai/veyra/releases/tag/v1.2.0")
        XCTAssertEqual(try JSONDecoder().decode(AppRelease.self, from: JSONEncoder().encode(release)), release)
    }

    func testRejectsDraftPrereleaseAndMalformedResponses() throws {
        for payload in [try data(draft: true), try data(prerelease: true)] {
            XCTAssertThrowsError(try GitHubReleaseClient.parse(data: payload, response: response(), now: now)) {
                XCTAssertEqual($0 as? UpdateFailure, .noRelease)
            }
        }
        for payload in [Data("not json".utf8), Data("{}".utf8), try data(tag: "next")] {
            XCTAssertThrowsError(try GitHubReleaseClient.parse(data: payload, response: response(), now: now)) {
                XCTAssertEqual($0 as? UpdateFailure, .invalidData)
            }
        }
    }

    func testRejectsUntrustedReleaseLinksIncludingCachedLinks() throws {
        for url in [
            "http://github.com/yuzio-ai/veyra/releases/tag/v1.2.0",
            "https://github.com.evil.example/yuzio-ai/veyra/releases/tag/v1.2.0",
            "https://github.com/other/repo/releases/tag/v1.2.0",
            "https://github.com/yuzio-ai/veyra/releases/latest",
            "https://github.com/yuzio-ai/veyra/releases/tag/",
            "https://user@github.com/yuzio-ai/veyra/releases/tag/v1.2.0",
            "https://github.com:443/yuzio-ai/veyra/releases/tag/v1.2.0",
            "https://github.com/yuzio-ai/veyra/releases/tag/../../other",
            "https://github.com/yuzio-ai/veyra/releases/tag/%2E%2E/other",
            "https://github.com/yuzio-ai/veyra/releases/tag/v1.2.0?redirect=elsewhere"
        ] {
            XCTAssertThrowsError(try GitHubReleaseClient.parse(data: data(url: url), response: response(), now: now), url)
            let cache = try JSONSerialization.data(withJSONObject: ["version": "1.2.0", "pageURL": url])
            XCTAssertThrowsError(try JSONDecoder().decode(AppRelease.self, from: cache), url)
        }
    }

    func testHTTPFailuresAndRateLimitDeadlines() throws {
        for (status, failure) in [(404, UpdateFailure.noRelease), (500, .network), (403, .network)] {
            XCTAssertThrowsError(try GitHubReleaseClient.parse(data: Data(), response: response(status), now: now)) {
                XCTAssertEqual($0 as? UpdateFailure, failure)
            }
        }
        let cases: [(Int, [String: String], TimeInterval)] = [
            (429, [:], 60),
            (403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(now.timeIntervalSince1970 + 3_600)], 3_600),
            (403, ["Retry-After": "120"], 120),
            (429, ["Retry-After": "120", "X-RateLimit-Reset": String(now.timeIntervalSince1970 + 600)], 600),
            (429, ["Retry-After": "invalid", "X-RateLimit-Reset": "NaN"], 60),
            (429, ["Retry-After": "-1", "X-RateLimit-Reset": "0"], 60)
        ]
        for (status, headers, delay) in cases {
            XCTAssertThrowsError(try GitHubReleaseClient.parse(data: Data(), response: response(status, headers: headers), now: now)) {
                XCTAssertEqual($0 as? UpdateFailure, .rateLimited(until: self.now.addingTimeInterval(delay)))
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let until = now.addingTimeInterval(300)
        XCTAssertThrowsError(try GitHubReleaseClient.parse(data: Data(), response: response(429, headers: ["Retry-After": formatter.string(from: until)]), now: now)) {
            XCTAssertEqual($0 as? UpdateFailure, .rateLimited(until: until))
        }
        XCTAssertThrowsError(try GitHubReleaseClient.parse(data: Data(#"{"message":"You have exceeded a secondary rate limit."}"#.utf8), response: response(403), now: now)) {
            XCTAssertEqual($0 as? UpdateFailure, .rateLimited(until: self.now.addingTimeInterval(60)))
        }
    }

    func testRequestUsesPublicEndpointAndTimeoutWithoutCredentials() {
        let request = GitHubReleaseClient.request
        XCTAssertEqual(request.url, GitHubReleaseClient.endpoint)
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    }
}
