import CryptoKit
import Foundation

// MARK: - Request Helpers

@MainActor
extension YTMusicClient {
    /// Makes a continuation request for browse endpoints.
    func requestContinuation(_ token: String, ttl: TimeInterval? = APICache.TTL.home) async throws -> [String: Any] {
        let body: [String: Any] = [
            "continuation": token,
        ]
        return try await self.request("browse", body: body, ttl: ttl)
    }

    /// Makes a continuation request for next/queue endpoints.
    func requestContinuation(_ token: String, body additionalBody: [String: Any]) async throws -> [String: Any] {
        var body = additionalBody
        body["continuation"] = token
        return try await self.request("next", body: body)
    }

    /// Builds authentication headers for API requests.
    private func buildAuthHeaders() async throws -> [String: String] {
        let allCookies = await self.webKitManager.getAllCookies()
        let youtubeCookies = await self.webKitManager.getCookies(for: "youtube.com")
        self.logger.debug("Building auth headers - total cookies: \(allCookies.count), youtube.com cookies: \(youtubeCookies.count)")

        guard let cookieHeader = await self.webKitManager.cookieHeader(for: "youtube.com") else {
            self.logger.error("No cookies found for youtube.com domain")
            throw YTMusicError.notAuthenticated
        }

        guard let sapisid = await self.webKitManager.getSAPISID() else {
            self.logger.error("SAPISID cookie not found or expired")
            throw YTMusicError.authExpired
        }

        let origin = WebKitManager.origin
        let timestamp = Int(Date().timeIntervalSince1970)
        let hashInput = "\(timestamp) \(sapisid) \(origin)"
        let hash = Insecure.SHA1.hash(data: Data(hashInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let sapisidhash = "\(timestamp)_\(hash)"

        return [
            "Cookie": cookieHeader,
            "Authorization": "SAPISIDHASH \(sapisidhash)",
            "Origin": origin,
            "Referer": origin,
            "Content-Type": "application/json",
            "X-Goog-AuthUser": "0",
            "X-Origin": origin,
        ]
    }

    /// Builds the standard context payload.
    /// Includes `onBehalfOfUser` when a brand account is selected.
    private func buildContext() -> [String: Any] {
        var userDict: [String: Any] = [
            "lockedSafetyMode": false,
        ]

        if let brandId = self.brandIdProvider?() {
            userDict["onBehalfOfUser"] = brandId
            self.logger.debug("Using brand account: \(brandId)")
        } else {
            self.logger.debug("Using primary account (no brand ID)")
        }

        return [
            "client": [
                "clientName": "WEB_REMIX",
                "clientVersion": Self.clientVersion,
                "hl": SettingsManager.shared.contentLanguage.apiLanguageCode,
                "gl": "US",
                "experimentIds": [],
                "experimentsToken": "",
                "browserName": "Safari",
                "browserVersion": "17.0",
                "osName": "Macintosh",
                "osVersion": "10_15_7",
                "platform": "DESKTOP",
                "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                "utcOffsetMinutes": -TimeZone.current.secondsFromGMT() / 60,
            ],
            "user": userDict,
        ]
    }

    /// Makes an authenticated request to the API with optional caching and retry.
    func request(_ endpoint: String, body: [String: Any], ttl: TimeInterval? = nil) async throws -> [String: Any] {
        var fullBody = body
        fullBody["context"] = self.buildContext()

        let brandId = self.brandIdProvider?() ?? ""
        let cacheKey = APICache.stableCacheKey(endpoint: endpoint, body: fullBody, brandId: brandId)
        self.logger.debug(
            "Request \(endpoint): brandId=\(brandId.isEmpty ? "primary" : brandId), cacheKey=\(cacheKey)"
        )

        if ttl != nil, let cached = APICache.shared.get(key: cacheKey) {
            self.logger.debug(
                "Cache hit for \(endpoint) (brandId=\(brandId.isEmpty ? "primary" : brandId))"
            )
            return cached
        }

        let json = try await RetryPolicy.default.execute { [self] in
            try await self.performRequest(endpoint, fullBody: fullBody)
        }

        if let ttl {
            APICache.shared.set(key: cacheKey, data: json, ttl: ttl)
        }

        return json
    }

    /// Performs the actual network request.
    private func performRequest(_ endpoint: String, fullBody: [String: Any]) async throws -> [String: Any] {
        let urlString = "\(Self.baseURL)/\(endpoint)?key=\(Self.apiKey)&prettyPrint=false"
        guard let url = URL(string: urlString) else {
            throw YTMusicError.unknown(message: "Invalid URL: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let headers = try await self.buildAuthHeaders()
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

        if let context = fullBody["context"] as? [String: Any],
           let user = context["user"] as? [String: Any]
        {
            let onBehalfOfUser = user["onBehalfOfUser"] as? String
            self.logger.debug(
                "Making request to \(endpoint) (onBehalfOfUser=\(onBehalfOfUser ?? "primary"))"
            )
        } else {
            self.logger.debug("Making request to \(endpoint) (missing context)")
        }

        let result = try await Self.performNetworkRequest(request: request, session: self.session)

        switch result {
        case let .success(data):
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw YTMusicError.parseError(message: "Response is not a JSON object")
            }
            return json
        case let .authError(statusCode):
            self.logger.error("Auth error: HTTP \(statusCode)")
            self.authService.sessionExpired()
            throw YTMusicError.authExpired
        case let .httpError(statusCode):
            self.logger.error("API error: HTTP \(statusCode)")
            throw YTMusicError.apiError(
                message: "HTTP \(statusCode)",
                code: statusCode
            )
        case let .networkError(error):
            throw YTMusicError.networkError(underlying: error)
        }
    }
}

private extension YTMusicClient {
    enum NetworkResult {
        case success(Data)
        case authError(statusCode: Int)
        case httpError(statusCode: Int)
        case networkError(Error)
    }

    // swiftformat:disable:next modifierOrder
    nonisolated static func performNetworkRequest(
        request: URLRequest,
        session: URLSession
    ) async throws -> NetworkResult {
        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .networkError(URLError(.badServerResponse))
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return .authError(statusCode: httpResponse.statusCode)
            }

            guard (200 ... 299).contains(httpResponse.statusCode) else {
                return .httpError(statusCode: httpResponse.statusCode)
            }

            return .success(data)
        } catch {
            return .networkError(error)
        }
    }
}
