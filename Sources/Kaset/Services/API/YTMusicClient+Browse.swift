import Foundation

// MARK: - Browse and Discovery APIs

@MainActor
extension YTMusicClient {
    // MARK: - Generic Pagination Methods

    /// Fetches paginated content for the given content type.
    /// Stores the continuation token for subsequent calls to `getContinuation`.
    func fetchPaginatedContent(type: PaginatedContentType, ttl: TimeInterval? = APICache.TTL.home) async throws -> HomeResponse {
        self.logger.info("Fetching \(type.displayName) page")

        let body: [String: Any] = [
            "browseId": type.rawValue,
        ]

        let data = try await self.request("browse", body: body, ttl: ttl)
        let response = HomeResponseParser.parse(data)

        let token = HomeResponseParser.extractContinuationToken(from: data)
        self.continuationTokens[type] = token

        let hasMore = token != nil
        self.logger.info("\(type.displayName.capitalized) page loaded: \(response.sections.count) initial sections, hasMore: \(hasMore)")
        return response
    }

    /// Fetches the next batch of sections for the given content type via continuation.
    /// Returns nil if no more sections are available.
    func fetchContinuation(type: PaginatedContentType) async throws -> [HomeSection]? {
        guard let token = self.continuationTokens[type] else {
            self.logger.debug("No \(type.displayName) continuation token available")
            return nil
        }

        self.logger.info("Fetching \(type.displayName) continuation")

        do {
            let continuationData = try await self.requestContinuation(token)
            let additionalSections = HomeResponseParser.parseContinuation(continuationData)
            self.continuationTokens[type] = HomeResponseParser.extractContinuationTokenFromContinuation(continuationData)
            let hasMore = self.continuationTokens[type] != nil

            self.logger.info("\(type.displayName.capitalized) continuation loaded: \(additionalSections.count) sections, hasMore: \(hasMore)")
            return additionalSections
        } catch {
            self.logger.warning("Failed to fetch \(type.displayName) continuation: \(error.localizedDescription)")
            self.continuationTokens[type] = nil
            throw error
        }
    }

    /// Checks whether more sections are available for the given content type.
    func hasMoreSections(for type: PaginatedContentType) -> Bool {
        self.continuationTokens[type] != nil
    }

    // MARK: - Public Browse APIs

    func getHome() async throws -> HomeResponse {
        try await self.fetchPaginatedContent(type: .home)
    }

    func getHomeContinuation() async throws -> [HomeSection]? {
        try await self.fetchContinuation(type: .home)
    }

    var hasMoreHomeSections: Bool {
        self.hasMoreSections(for: .home)
    }

    func getExplore() async throws -> HomeResponse {
        try await self.fetchPaginatedContent(type: .explore)
    }

    func getExploreContinuation() async throws -> [HomeSection]? {
        try await self.fetchContinuation(type: .explore)
    }

    var hasMoreExploreSections: Bool {
        self.hasMoreSections(for: .explore)
    }

    func getCharts() async throws -> HomeResponse {
        try await self.fetchPaginatedContent(type: .charts)
    }

    func getChartsContinuation() async throws -> [HomeSection]? {
        try await self.fetchContinuation(type: .charts)
    }

    var hasMoreChartsSections: Bool {
        self.hasMoreSections(for: .charts)
    }

    func getMoodsAndGenres() async throws -> HomeResponse {
        try await self.fetchPaginatedContent(type: .moodsAndGenres)
    }

    func getMoodsAndGenresContinuation() async throws -> [HomeSection]? {
        try await self.fetchContinuation(type: .moodsAndGenres)
    }

    var hasMoreMoodsAndGenresSections: Bool {
        self.hasMoreSections(for: .moodsAndGenres)
    }

    func getNewReleases() async throws -> HomeResponse {
        try await self.fetchPaginatedContent(type: .newReleases)
    }

    func getNewReleasesContinuation() async throws -> [HomeSection]? {
        try await self.fetchContinuation(type: .newReleases)
    }

    var hasMoreNewReleasesSections: Bool {
        self.hasMoreSections(for: .newReleases)
    }

    /// No cache — history changes with every song played.
    func getHistory() async throws -> HomeResponse {
        try await self.fetchPaginatedContent(type: .history, ttl: nil)
    }

    func getHistoryContinuation() async throws -> [HomeSection]? {
        try await self.fetchContinuation(type: .history)
    }

    var hasMoreHistorySections: Bool {
        self.hasMoreSections(for: .history)
    }

    func getPodcasts() async throws -> [PodcastSection] {
        self.logger.info("Fetching podcasts page")

        let body: [String: Any] = [
            "browseId": PaginatedContentType.podcasts.rawValue,
        ]

        let data = try await self.request("browse", body: body, ttl: APICache.TTL.home)
        let sections = PodcastParser.parseDiscovery(data)

        let token = HomeResponseParser.extractContinuationToken(from: data)
        self.continuationTokens[.podcasts] = token

        let hasMore = token != nil
        self.logger.info("Podcasts page loaded: \(sections.count) initial sections, hasMore: \(hasMore)")
        return sections
    }

    func getPodcastsContinuation() async throws -> [PodcastSection]? {
        guard let token = self.continuationTokens[.podcasts] else {
            self.logger.debug("No podcasts continuation token available")
            return nil
        }

        self.logger.info("Fetching podcasts continuation")

        do {
            let continuationData = try await self.requestContinuation(token)
            let additionalSections = PodcastParser.parseContinuation(continuationData)
            self.continuationTokens[.podcasts] = HomeResponseParser.extractContinuationTokenFromContinuation(continuationData)
            let hasMore = self.continuationTokens[.podcasts] != nil

            self.logger.info("Podcasts continuation loaded: \(additionalSections.count) sections, hasMore: \(hasMore)")
            return additionalSections
        } catch {
            self.logger.warning("Failed to fetch podcasts continuation: \(error.localizedDescription)")
            self.continuationTokens[.podcasts] = nil
            throw error
        }
    }

    var hasMorePodcastsSections: Bool {
        self.hasMoreSections(for: .podcasts)
    }

    func getPodcastShow(browseId: String) async throws -> PodcastShowDetail {
        self.logger.info("Fetching podcast show: \(browseId)")

        let body: [String: Any] = [
            "browseId": browseId,
        ]

        let data = try await self.request("browse", body: body, ttl: APICache.TTL.playlist)
        let showDetail = PodcastParser.parseShowDetail(data, showId: browseId)

        self.logger.info("Parsed podcast show '\(showDetail.show.title)' with \(showDetail.episodes.count) episodes")
        return showDetail
    }

    func getPodcastEpisodesContinuation(token: String) async throws -> PodcastEpisodesContinuation {
        self.logger.info("Fetching more podcast episodes via continuation")

        let data = try await self.requestContinuation(token, ttl: APICache.TTL.playlist)
        let continuation = PodcastParser.parseEpisodesContinuation(data)

        self.logger.info("Parsed \(continuation.episodes.count) more episodes")
        return continuation
    }

    func getMoodCategory(browseId: String, params: String?) async throws -> HomeResponse {
        self.logger.info("Fetching mood category: \(browseId)")

        var body: [String: Any] = [
            "browseId": browseId,
        ]

        if let params {
            body["params"] = params
        }

        let data = try await self.request("browse", body: body, ttl: APICache.TTL.home)
        let response = HomeResponseParser.parse(data)
        self.logger.info("Mood category loaded: \(response.sections.count) sections")
        return response
    }
}
