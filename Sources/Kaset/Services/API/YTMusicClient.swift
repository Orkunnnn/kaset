import Foundation
import Observation
import os

// MARK: - PaginatedContentType

/// Identifies content types that support pagination via continuation tokens.
/// Used internally by YTMusicClient to manage pagination state generically.
enum PaginatedContentType: String, Hashable {
    case home = "FEmusic_home"
    case explore = "FEmusic_explore"
    case charts = "FEmusic_charts"
    case moodsAndGenres = "FEmusic_moods_and_genres"
    case newReleases = "FEmusic_new_releases"
    case podcasts = "FEmusic_podcasts"
    case history = "FEmusic_history"

    /// Display name for logging.
    var displayName: String {
        switch self {
        case .home: "home"
        case .explore: "explore"
        case .charts: "charts"
        case .moodsAndGenres: "moods and genres"
        case .newReleases: "new releases"
        case .podcasts: "podcasts"
        case .history: "history"
        }
    }
}

// MARK: - YTMusicClient

/// Client for making authenticated requests to YouTube Music's internal API.
@MainActor
final class YTMusicClient: YTMusicClientProtocol {
    let authService: AuthService
    let webKitManager: WebKitManager
    let session: URLSession
    let logger = DiagnosticsLogger.api

    /// Provider for the current brand account ID.
    /// Set this after initialization to enable brand account API requests.
    /// Returns nil for primary account, brand ID string for brand accounts.
    var brandIdProvider: (() -> String?)?

    /// YouTube Music API base URL.
    static let baseURL = "https://music.youtube.com/youtubei/v1"

    /// API key used in requests (extracted from YouTube Music web client).
    static let apiKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"

    /// Client version for WEB_REMIX.
    static let clientVersion = "1.20231204.01.00"

    /// Centralized storage for continuation tokens keyed by content type.
    var continuationTokens: [PaginatedContentType: String] = [:]

    /// Continuation token for filtered search pagination.
    var searchContinuationToken: String?

    /// Continuation token for liked songs pagination.
    var likedSongsContinuationToken: String?

    /// Continuation token for playlist tracks pagination.
    var playlistContinuationToken: String?

    init(authService: AuthService, webKitManager: WebKitManager = .shared) {
        self.authService = authService
        self.webKitManager = webKitManager

        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Accept-Encoding": "gzip, deflate, br",
        ]
        // Increase connection pool for parallel requests (HTTP/2 multiplexing is automatic)
        configuration.httpMaximumConnectionsPerHost = 6
        // Use shared URL cache for transport-level caching
        configuration.urlCache = URLCache.shared
        configuration.requestCachePolicy = .useProtocolCachePolicy
        // Reduce timeout for faster failure detection
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }
}
