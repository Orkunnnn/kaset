import Foundation

// MARK: - Library and Playlist APIs

@MainActor
extension YTMusicClient {
    func getLibraryPlaylists() async throws -> [Playlist] {
        self.logger.info("Fetching library playlists")

        let body: [String: Any] = [
            "browseId": "FEmusic_liked_playlists",
        ]

        let data = try await self.request("browse", body: body, ttl: APICache.TTL.library)
        let playlists = PlaylistParser.parseLibraryPlaylists(data)
        self.logger.info("Parsed \(playlists.count) library playlists")
        return playlists
    }

    func getLibraryContent() async throws -> PlaylistParser.LibraryContent {
        self.logger.info("Fetching library content")

        let landingData = try await self.request(
            "browse",
            body: ["browseId": "FEmusic_library_landing"],
            ttl: APICache.TTL.library
        )

        let landingContent = PlaylistParser.parseLibraryContent(landingData)
        let (artists, artistsSource) = try await self.fetchLibraryArtists(fallback: landingContent.artists)
        let content = PlaylistParser.LibraryContent(
            playlists: landingContent.playlists,
            artists: artists,
            podcastShows: landingContent.podcastShows,
            artistsSource: artistsSource
        )

        self.logger.info(
            "Parsed \(content.playlists.count) library playlists, \(content.artists.count) artists, and \(content.podcastShows.count) podcasts"
        )
        return content
    }

    func fetchLibraryArtists(
        fallback fallbackArtists: [Artist]
    ) async throws -> ([Artist], PlaylistParser.LibraryArtistsSource) {
        do {
            let artistsData = try await self.request(
                "browse",
                body: [
                    "browseId": "FEmusic_library_corpus_artists",
                    "params": "ggMCCAU=",
                ],
                ttl: APICache.TTL.library
            )
            let artists = PlaylistParser.parseLibraryArtists(artistsData)

            if !artists.isEmpty {
                return (artists, .dedicated)
            }

            self.logger.warning("Library corpus artists endpoint returned no artists, falling back to landing preview")
        } catch {
            self.logger.warning("Library corpus artists endpoint failed, falling back to landing preview: \(error.localizedDescription)")
        }

        return (fallbackArtists, .landingFallback)
    }

    var hasMoreLikedSongs: Bool {
        self.likedSongsContinuationToken != nil
    }

    func getLikedSongs() async throws -> LikedSongsResponse {
        self.logger.info("Fetching liked songs via VLLM playlist")

        let body: [String: Any] = [
            "browseId": "VLLM",
        ]

        let data = try await self.request("browse", body: body, ttl: APICache.TTL.library)
        let playlistResponse = PlaylistParser.parsePlaylistWithContinuation(data, playlistId: "LM")

        self.likedSongsContinuationToken = playlistResponse.continuationToken
        let hasMore = playlistResponse.hasMore

        let response = LikedSongsResponse(
            songs: playlistResponse.detail.tracks,
            continuationToken: playlistResponse.continuationToken
        )

        self.logger.info("Parsed \(response.songs.count) liked songs, hasMore: \(hasMore)")
        return response
    }

    func getLikedSongsContinuation() async throws -> LikedSongsResponse? {
        guard let token = self.likedSongsContinuationToken else {
            self.logger.debug("No liked songs continuation token available")
            return nil
        }

        self.logger.info("Fetching liked songs continuation")

        do {
            let continuationData = try await self.requestContinuation(token)
            let playlistResponse = PlaylistParser.parsePlaylistContinuation(continuationData)
            self.likedSongsContinuationToken = playlistResponse.continuationToken
            let hasMore = playlistResponse.hasMore

            let response = LikedSongsResponse(
                songs: playlistResponse.tracks,
                continuationToken: playlistResponse.continuationToken
            )

            self.logger.info("Liked songs continuation loaded: \(response.songs.count) songs, hasMore: \(hasMore)")
            return response
        } catch {
            self.logger.warning("Failed to fetch liked songs continuation: \(error.localizedDescription)")
            self.likedSongsContinuationToken = nil
            throw error
        }
    }

    var hasMorePlaylistTracks: Bool {
        self.playlistContinuationToken != nil
    }

    func getPlaylist(id: String) async throws -> PlaylistTracksResponse {
        self.logger.info("Fetching playlist: \(id)")

        let browseId: String = if id.hasPrefix("VL") || id.hasPrefix("RD") || id.hasPrefix("OLAK") || id.hasPrefix("MPRE") || id.hasPrefix("UC") {
            id
        } else if id.hasPrefix("PL") {
            "VL\(id)"
        } else {
            "VL\(id)"
        }

        let body: [String: Any] = [
            "browseId": browseId,
        ]

        let data = try await self.request("browse", body: body, ttl: APICache.TTL.playlist)
        let response = PlaylistParser.parsePlaylistWithContinuation(data, playlistId: id)

        self.playlistContinuationToken = response.continuationToken
        let hasMore = response.hasMore

        self.logger.info("Parsed playlist '\(response.detail.title)' with \(response.detail.tracks.count) tracks, hasMore: \(hasMore)")
        return response
    }

    func getPlaylistAllTracks(playlistId: String) async throws -> [Song] {
        let rawPlaylistId: String = if playlistId.hasPrefix("VL") {
            String(playlistId.dropFirst(2))
        } else {
            playlistId
        }

        self.logger.info("Fetching all playlist tracks via queue: \(rawPlaylistId)")

        let body: [String: Any] = [
            "playlistId": rawPlaylistId,
        ]

        let data = try await self.request("music/get_queue", body: body, ttl: nil)
        let tracks = PlaylistParser.parseQueueTracks(data)
        self.logger.info("Fetched \(tracks.count) tracks from queue endpoint")

        return tracks
    }

    func getPlaylistContinuation() async throws -> PlaylistContinuationResponse? {
        guard let token = self.playlistContinuationToken else {
            self.logger.debug("No playlist continuation token available")
            return nil
        }

        self.logger.info("Fetching playlist continuation")

        do {
            let continuationData = try await self.requestContinuation(token)
            let response = PlaylistParser.parsePlaylistContinuation(continuationData)
            self.playlistContinuationToken = response.continuationToken
            let hasMore = response.hasMore

            self.logger.info("Playlist continuation loaded: \(response.tracks.count) tracks, hasMore: \(hasMore)")
            return response
        } catch {
            self.logger.warning("Failed to fetch playlist continuation: \(error.localizedDescription)")
            self.playlistContinuationToken = nil
            throw error
        }
    }
}
