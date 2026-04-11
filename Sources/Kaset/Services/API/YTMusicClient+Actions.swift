import Foundation

// MARK: - Account and Mutation APIs

@MainActor
extension YTMusicClient {
    func fetchAccountsList() async throws -> AccountsListResponse {
        self.logger.info("Fetching accounts list")

        let data = try await self.request("account/accounts_list", body: [:])
        let response = AccountsListParser.parse(data)

        self.logger.info("Accounts list loaded: \(response.accounts.count) accounts")
        return response
    }

    func rateSong(videoId: String, rating: LikeStatus) async throws {
        self.logger.info("Rating song \(videoId) with \(rating.rawValue)")

        let body: [String: Any] = [
            "target": ["videoId": videoId],
        ]

        let endpoint = switch rating {
        case .like:
            "like/like"
        case .dislike:
            "like/dislike"
        case .indifferent:
            "like/removelike"
        }

        _ = try await self.request(endpoint, body: body)
        self.logger.info("Successfully rated song \(videoId)")
        APICache.shared.invalidateMutationCaches()
    }

    func editSongLibraryStatus(feedbackTokens: [String]) async throws {
        guard !feedbackTokens.isEmpty else {
            self.logger.warning("No feedback tokens provided for library edit")
            return
        }

        self.logger.info("Editing song library status with \(feedbackTokens.count) tokens")

        let body: [String: Any] = [
            "feedbackTokens": feedbackTokens,
        ]

        _ = try await self.request("feedback", body: body)
        self.logger.info("Successfully edited library status")
        APICache.shared.invalidateMutationCaches()
    }

    func subscribeToPlaylist(playlistId: String) async throws {
        self.logger.info("Adding playlist to library: \(playlistId)")

        let cleanId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        let body: [String: Any] = [
            "target": ["playlistId": cleanId],
        ]

        _ = try await self.request("like/like", body: body)
        self.logger.info("Successfully added playlist \(playlistId) to library")
        APICache.shared.invalidate(matching: "browse:")
    }

    func unsubscribeFromPlaylist(playlistId: String) async throws {
        self.logger.info("Removing playlist from library: \(playlistId)")

        let cleanId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        let body: [String: Any] = [
            "target": ["playlistId": cleanId],
        ]

        _ = try await self.request("like/removelike", body: body)
        self.logger.info("Successfully removed playlist \(playlistId) from library")
        APICache.shared.invalidate(matching: "browse:")
    }

    func convertPodcastShowIdToPlaylistId(_ showId: String) throws -> String {
        guard showId.hasPrefix("MPSPP") else {
            self.logger.warning("ShowId does not have MPSPP prefix, using as-is: \(showId)")
            return showId
        }

        let suffix = String(showId.dropFirst(5))

        guard !suffix.isEmpty else {
            self.logger.error("Invalid podcast show ID (missing suffix after MPSPP): \(showId)")
            throw YTMusicError.invalidInput("Invalid podcast show ID: \(showId)")
        }

        guard suffix.hasPrefix("L") else {
            self.logger.error("Invalid podcast show ID (suffix must start with 'L'): \(showId)")
            throw YTMusicError.invalidInput("Invalid podcast show ID format: \(showId)")
        }

        return "P" + suffix
    }

    func subscribeToPodcast(showId: String) async throws {
        self.logger.info("Subscribing to podcast: \(showId)")

        let playlistId = try self.convertPodcastShowIdToPlaylistId(showId)
        let body: [String: Any] = [
            "target": ["playlistId": playlistId],
        ]

        _ = try await self.request("like/like", body: body)
        self.logger.info("Successfully subscribed to podcast \(showId)")
        APICache.shared.invalidate(matching: "browse:")
    }

    func unsubscribeFromPodcast(showId: String) async throws {
        self.logger.info("Unsubscribing from podcast: \(showId)")

        let playlistId = try self.convertPodcastShowIdToPlaylistId(showId)
        let body: [String: Any] = [
            "target": ["playlistId": playlistId],
        ]

        self.logger.debug("Calling like/removelike with playlistId=\(playlistId)")
        _ = try await self.request("like/removelike", body: body)
        self.logger.info("Successfully unsubscribed from podcast \(showId)")
        APICache.shared.invalidate(matching: "browse:")
    }

    func subscribeToArtist(channelId: String) async throws {
        self.logger.info("Subscribing to artist: \(channelId)")

        let body: [String: Any] = [
            "channelIds": [channelId],
        ]

        _ = try await self.request("subscription/subscribe", body: body)
        self.logger.info("Successfully subscribed to artist \(channelId)")
        APICache.shared.invalidate(matching: "browse:")
    }

    func unsubscribeFromArtist(channelId: String) async throws {
        self.logger.info("Unsubscribing from artist: \(channelId)")

        let body: [String: Any] = [
            "channelIds": [channelId],
        ]

        _ = try await self.request("subscription/unsubscribe", body: body)
        self.logger.info("Successfully unsubscribed from artist \(channelId)")
        APICache.shared.invalidate(matching: "browse:")
    }
}
