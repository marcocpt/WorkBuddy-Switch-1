import Foundation

// MARK: - HTTP 客户端抽取（可注入以便离线单测）

protocol CreditStatsHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// WorkBuddy billing 请求只允许发往官方主机（与 Trae 路径同等的安全合同）。
enum WorkBuddyOfficialHostPolicy {
    private static let allowedHosts: Set<String> = [
        "www.codebuddy.cn",
        "codebuddy.cn"
    ]

    static func isAllowed(_ url: URL) -> Bool {
        guard
            url.scheme?.lowercased() == "https",
            url.user == nil,
            url.password == nil,
            url.port == nil || url.port == 443,
            url.query == nil,
            url.fragment == nil,
            let host = url.host?.lowercased(),
            allowedHosts.contains(host)
        else {
            return false
        }
        return true
    }

    static func validateRequest(_ url: URL) throws {
        guard isAllowed(url) else {
            throw WorkBuddyCreditError.unsafeHost
        }
    }
}

final class CreditStatsRedirectPolicyDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard
            let url = request.url,
            WorkBuddyOfficialHostPolicy.isAllowed(url)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

struct URLSessionCreditStatsHTTPClient: CreditStatsHTTPClient {
    let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            self.session = URLSession(
                configuration: configuration,
                delegate: CreditStatsRedirectPolicyDelegate(),
                delegateQueue: nil
            )
        }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw WorkBuddyCreditError.unavailable
        }
        try WorkBuddyOfficialHostPolicy.validateRequest(url)
        let (data, response) = try await session.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            let responseURL = httpResponse.url
        else {
            throw WorkBuddyCreditError.unavailable
        }
        try WorkBuddyOfficialHostPolicy.validateRequest(responseURL)
        return (data, httpResponse)
    }
}
