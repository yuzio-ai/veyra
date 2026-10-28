import Foundation

/// No server response bodies or credentials are persisted in test results.
enum ProviderConnectionFailure: String, Codable, Error, LocalizedError, Sendable {
    case authentication, network, timeout, rateLimited, server, incompatible, inconclusive
    var errorDescription: String? {
        switch self {
        case .authentication: L10n.text("Authentication failed. Check the saved Key.")
        case .network: L10n.text("Connection failed. Check the address and network.")
        case .timeout: L10n.text("The connection test timed out.")
        case .rateLimited: L10n.text("The provider is limiting requests. Retry later.")
        case .server: L10n.text("The provider could not complete the request.")
        case .incompatible: L10n.text("This endpoint does not support the Responses protocol required by Codex.")
        case .inconclusive: L10n.text("Responses compatibility could not be confirmed. Check the provider documentation.")
        }
    }
}

struct ProviderConnectivityResult: Codable, Equatable, Sendable {
    var scope: ProviderModelScope
    var model: String
    var protocolName: String
    var date: Date
    var failure: ProviderConnectionFailure?
    func matches(_ settings: ProviderSettings) -> Bool {
        scope == ProviderModelScope(settings) && model == settings.model && protocolName == settings.protocolName
    }
}

protocol ProviderConnectivityClient: Sendable {
    func test(provider: ProviderSettings, key: String?) async throws
}

struct URLSessionProviderConnectivityClient: ProviderConnectivityClient {
    var protocolClasses: [AnyClass] = []
    func test(provider: ProviderSettings, key: String?) async throws {
        guard provider.protocolName == "responses" else { throw ProviderConnectionFailure.incompatible }
        guard ProviderSettings.validEndpoint(provider.baseURL), DiscoveredModel.validToken(provider.model),
              let base = URL(string: provider.baseURL) else { throw ModelProfileFailure.invalid }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        let redirects = ProviderModelRedirectGuard()
        let session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: base.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(JSONValue.object([
            "model": .string(provider.model), "input": .string("Reply OK."),
            "max_output_tokens": .number(16), "store": .bool(false), "stream": .bool(false)
        ]))
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw ProviderConnectionFailure.inconclusive }
            switch response.statusCode {
            case 200...299: break
            case 401, 403: throw ProviderConnectionFailure.authentication
            case 429: throw ProviderConnectionFailure.rateLimited
            case 500...599: throw ProviderConnectionFailure.server
            // 404 can mean a missing model, endpoint or proxy route. Do not invent certainty.
            default:
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < 65536 else { throw ProviderConnectionFailure.inconclusive }
                    data.append(byte)
                }
                let code = (try? JSONValue.decode(data))?["error"]["code"].string
                if ["unsupported_protocol", "unsupported_api", "unsupported_endpoint"].contains(code) { throw ProviderConnectionFailure.incompatible }
                throw ProviderConnectionFailure.inconclusive
            }
            guard response.expectedContentLength <= URLSessionProviderModelClient.maximumBytes else { throw ProviderConnectionFailure.inconclusive }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < URLSessionProviderModelClient.maximumBytes else { throw ProviderConnectionFailure.inconclusive }
                data.append(byte)
            }
            guard let value = try? JSONValue.decode(data), value["object"].string == "response",
                  value["status"].string == "completed", value["output"].array != nil,
                  value["error"] == .null else { throw ProviderConnectionFailure.inconclusive }
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let failure = error as? ProviderConnectionFailure { throw failure }
            if redirects.rejected { throw ProviderConnectionFailure.inconclusive }
            throw (error as? URLError)?.code == .timedOut ? ProviderConnectionFailure.timeout : .network
        }
    }
}
