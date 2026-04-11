import Foundation

// MARK: - Artist, Lyrics, Radio, and Song APIs

@MainActor
extension YTMusicClient {
    func getArtist(id: String) async throws -> ArtistDetail {
        self.logger.info("Fetching artist: \(id)")

        let body: [String: Any] = [
            "browseId": id,
        ]

        let data = try await self.request("browse", body: body, ttl: APICache.TTL.artist)

        let topKeys = Array(data.keys)
        self.logger.debug("Artist response top-level keys: \(topKeys)")

        var detail = ArtistParser.parseArtistDetail(data, artistId: id)

        let songsNeedingDuration = detail.songs.filter { $0.duration == nil }
        if !songsNeedingDuration.isEmpty {
            do {
                let durations = try await self.fetchSongDurations(videoIds: songsNeedingDuration.map(\.videoId))
                let enrichedSongs = detail.songs.map { song -> Song in
                    if song.duration == nil, let duration = durations[song.videoId] {
                        return Song(
                            id: song.id,
                            title: song.title,
                            artists: song.artists,
                            album: song.album,
                            duration: duration,
                            thumbnailURL: song.thumbnailURL,
                            videoId: song.videoId,
                            hasVideo: song.hasVideo,
                            musicVideoType: song.musicVideoType,
                            likeStatus: song.likeStatus,
                            isInLibrary: song.isInLibrary,
                            feedbackTokens: song.feedbackTokens
                        )
                    }
                    return song
                }
                detail = ArtistDetail(
                    artist: detail.artist,
                    description: detail.description,
                    songs: enrichedSongs,
                    songsSectionTitle: detail.songsSectionTitle,
                    orderedSections: detail.orderedSections,
                    thumbnailURL: detail.thumbnailURL,
                    channelId: detail.channelId,
                    isSubscribed: detail.isSubscribed,
                    subscriberCount: detail.subscriberCount,
                    subscribedButtonText: detail.subscribedButtonText,
                    unsubscribedButtonText: detail.unsubscribedButtonText,
                    monthlyAudience: detail.monthlyAudience,
                    hasMoreSongs: detail.hasMoreSongs,
                    songsBrowseId: detail.songsBrowseId,
                    songsParams: detail.songsParams,
                    mixPlaylistId: detail.mixPlaylistId,
                    mixVideoId: detail.mixVideoId
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                self.logger.debug("Best-effort duration fetch failed: \(error.localizedDescription)")
            }
        }

        let albumSections = detail.orderedSections.compactMap {
            if case let .albums(albums) = $0.content { albums } else { nil }
        }
        let playlistSections = detail.orderedSections.compactMap {
            if case let .playlists(playlists) = $0.content { playlists } else { nil }
        }
        let artistSections = detail.orderedSections.compactMap {
            if case let .artists(artists) = $0.content { artists } else { nil }
        }
        let artistCount = artistSections.reduce(0) { $0 + $1.count }
        let playlistCount = playlistSections.reduce(0) { $0 + $1.count }
        let albumCount = albumSections.reduce(0) { $0 + $1.count }
        self.logger.info("Parsed artist '\(detail.artist.name)' with \(detail.songs.count) songs, \(albumCount) albums across \(albumSections.count) album sections, \(playlistCount) playlists across \(playlistSections.count) playlist sections and \(artistCount) related artists across \(artistSections.count) artist sections")
        return detail
    }

    func fetchSongDurations(videoIds: [String]) async throws -> [String: TimeInterval] {
        guard !videoIds.isEmpty else { return [:] }

        let body: [String: Any] = [
            "videoIds": videoIds,
        ]

        let data = try await self.request("music/get_queue", body: body, ttl: APICache.TTL.artist)

        var durations: [String: TimeInterval] = [:]
        if let queueDatas = data["queueDatas"] as? [[String: Any]] {
            for queueData in queueDatas {
                guard let content = queueData["content"] as? [String: Any] else { continue }
                let renderer: [String: Any]? = if let direct = content["playlistPanelVideoRenderer"] as? [String: Any] {
                    direct
                } else if let wrapper = content["playlistPanelVideoWrapperRenderer"] as? [String: Any],
                          let primary = wrapper["primaryRenderer"] as? [String: Any],
                          let wrapped = primary["playlistPanelVideoRenderer"] as? [String: Any]
                {
                    wrapped
                } else {
                    nil
                }
                if let renderer,
                   let videoId = renderer["videoId"] as? String,
                   let lengthText = renderer["lengthText"] as? [String: Any],
                   let runs = lengthText["runs"] as? [[String: Any]],
                   let durationText = runs.first?["text"] as? String,
                   let duration = ParsingHelpers.parseDuration(durationText)
                {
                    durations[videoId] = duration
                }
            }
        }

        self.logger.debug("Fetched durations for \(durations.count)/\(videoIds.count) songs")
        return durations
    }

    func getArtistSongs(browseId: String, params: String?) async throws -> [Song] {
        self.logger.info("Fetching artist songs: \(browseId)")

        var body: [String: Any] = [
            "browseId": browseId,
        ]

        if let params {
            body["params"] = params
        }

        let data = try await self.request("browse", body: body, ttl: APICache.TTL.artist)
        let songs = ArtistParser.parseArtistSongs(data)
        self.logger.info("Parsed \(songs.count) artist songs")
        return songs
    }

    func getLyrics(videoId: String) async throws -> Lyrics {
        self.logger.info("Fetching lyrics for: \(videoId)")

        let nextBody: [String: Any] = [
            "videoId": videoId,
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]

        let nextData = try await self.request("next", body: nextBody)

        guard let lyricsBrowseId = LyricsParser.extractLyricsBrowseId(from: nextData) else {
            self.logger.info("No lyrics available for: \(videoId)")
            return .unavailable
        }

        let browseBody: [String: Any] = [
            "browseId": lyricsBrowseId,
        ]

        let browseData = try await self.request("browse", body: browseBody, ttl: APICache.TTL.lyrics)
        let lyrics = LyricsParser.parse(from: browseData)
        self.logger.info("Fetched lyrics for \(videoId): \(lyrics.isAvailable ? "available" : "unavailable")")
        return lyrics
    }

    func getTimedLyrics(videoId: String) async throws -> LyricResult {
        self.logger.info("Fetching timed lyrics for: \(videoId)")

        let nextBody: [String: Any] = [
            "videoId": videoId,
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]

        let nextData = try await self.request("next", body: nextBody)

        if let synced = LyricsParser.extractTimedLyrics(from: nextData) {
            self.logger.info("Found timed lyrics for \(videoId): \(synced.lines.count) lines")
            return .synced(synced)
        }

        if let lyricsBrowseId = LyricsParser.extractLyricsBrowseId(from: nextData) {
            let browseBody: [String: Any] = [
                "browseId": lyricsBrowseId,
            ]
            let browseData = try await self.request("browse", body: browseBody, ttl: APICache.TTL.lyrics)
            let lyrics = LyricsParser.parse(from: browseData)
            if lyrics.isAvailable {
                self.logger.info("Fell back to plain lyrics for \(videoId)")
                return .plain(lyrics)
            }
        }

        self.logger.info("No timed lyrics available for: \(videoId)")
        return .unavailable
    }

    func getRadioQueue(videoId: String) async throws -> [Song] {
        self.logger.info("Fetching radio queue for: \(videoId)")

        let body: [String: Any] = [
            "videoId": videoId,
            "playlistId": "RDAMVM\(videoId)",
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]

        let data = try await self.request("next", body: body)
        let result = RadioQueueParser.parse(from: data)
        self.logger.info("Fetched radio queue with \(result.songs.count) songs")
        return result.songs
    }

    func getMixQueue(playlistId: String, startVideoId: String?) async throws -> RadioQueueResult {
        self.logger.info("Fetching mix queue for playlist: \(playlistId)")

        var body: [String: Any] = [
            "playlistId": playlistId,
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]

        if let videoId = startVideoId {
            body["videoId"] = videoId
        }

        let data = try await self.request("next", body: body)
        let result = RadioQueueParser.parse(from: data)
        self.logger.info("Fetched mix queue with \(result.songs.count) songs, hasContinuation: \(result.continuationToken != nil)")
        return result
    }

    func getMixQueueContinuation(continuationToken: String) async throws -> RadioQueueResult {
        self.logger.info("Fetching mix queue continuation")

        let body: [String: Any] = [
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
        ]

        let data = try await self.requestContinuation(continuationToken, body: body)
        let result = RadioQueueParser.parseContinuation(from: data)
        self.logger.info("Fetched \(result.songs.count) more songs, hasContinuation: \(result.continuationToken != nil)")
        return result
    }

    func getSong(videoId: String) async throws -> Song {
        self.logger.info("Fetching song metadata: \(videoId)")

        let body: [String: Any] = [
            "videoId": videoId,
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]

        let data = try await self.request("next", body: body, ttl: APICache.TTL.songMetadata)
        let song = try SongMetadataParser.parse(data, videoId: videoId)
        self.logger.info("Parsed song '\(song.title)' - inLibrary: \(song.isInLibrary ?? false), hasTokens: \(song.feedbackTokens != nil)")
        return song
    }
}
