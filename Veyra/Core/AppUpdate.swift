import Foundation

struct AppVersion: Comparable, Sendable {
    let components: [Int]

    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        components = numbers
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

struct AppRelease: Codable, Equatable, Sendable {
    let version: String
    let pageURL: URL

    init(version: String, pageURL: URL) throws {
        guard AppVersion(version) != nil,
              let url = URLComponents(url: pageURL, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.host == "github.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/yuzio-ai/veyra/releases/tag/"),
              !url.path.dropFirst("/yuzio-ai/veyra/releases/tag/".count).isEmpty,
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !url.path.contains("\\") else { throw UpdateFailure.invalidData }
        self.version = version.hasPrefix("v") ? String(version.dropFirst()) : version
        self.pageURL = pageURL
    }

    private enum CodingKeys: String, CodingKey { case version, pageURL }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: values.decode(String.self, forKey: .version),
                      pageURL: values.decode(URL.self, forKey: .pageURL))
    }
}

enum UpdateFailure: Error, Equatable, Sendable {
    case network, noRelease, invalidData
    case rateLimited(until: Date)

    var diagnosticCategory: String {
        switch self {
        case .network: "network"
        case .noRelease: "no_release"
        case .invalidData: "invalid_data"
        case .rateLimited: "rate_limited"
        }
    }

    var message: String {
        switch self {
        case .network: L10n.text("Unable to check for updates. Check your connection and try again.")
        case .noRelease: L10n.text("No published release is available yet.")
        case .invalidData: L10n.text("Unable to recognize the release information or app version.")
        case .rateLimited: L10n.text("GitHub is limiting update checks. Try again after the cooldown.")
        }
    }
}

enum GitHubReleaseClient {
    static let endpoint = URL(string: "https://api.github.com/repos/yuzio-ai/veyra/releases/latest")!

    static var request: URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Veyra-Update-Checker", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func fetch() async throws -> AppRelease {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw UpdateFailure.invalidData }
            return try parse(data: data, response: response, now: Date())
        } catch let failure as UpdateFailure {
            throw failure
        } catch {
            throw UpdateFailure.network
        }
    }

    static func parse(data: Data, response: HTTPURLResponse, now: Date) throws -> AppRelease {
        let retry = response.value(forHTTPHeaderField: "Retry-After")
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.message ?? ""
        if response.statusCode == 429 || (response.statusCode == 403 &&
            (remaining == "0" || retry != nil || message.localizedCaseInsensitiveContains("rate limit"))) {
            var deadline = now.addingTimeInterval(60)
            if let retry {
                if let seconds = Double(retry), seconds.isFinite, seconds >= 0 {
                    deadline = max(deadline, now.addingTimeInterval(seconds))
                } else {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    if let date = formatter.date(from: retry) { deadline = max(deadline, date) }
                }
            }
            if let value = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
               let seconds = Double(value), seconds.isFinite {
                deadline = max(deadline, Date(timeIntervalSince1970: seconds))
            }
            throw UpdateFailure.rateLimited(until: deadline)
        }
        guard response.statusCode != 404 else { throw UpdateFailure.noRelease }
        guard response.statusCode == 200 else { throw UpdateFailure.network }
        do {
            let release = try JSONDecoder().decode(ReleaseResponse.self, from: data)
            guard !release.draft, !release.prerelease else { throw UpdateFailure.noRelease }
            return try AppRelease(version: release.tag_name, pageURL: release.html_url)
        } catch let failure as UpdateFailure {
            throw failure
        } catch {
            throw UpdateFailure.invalidData
        }
    }

    private struct ReleaseResponse: Decodable {
        let tag_name: String
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
    }

    private struct ErrorResponse: Decodable { let message: String }
}
