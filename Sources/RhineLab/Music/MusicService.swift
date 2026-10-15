import Foundation

/// Explicit JSON adapters; downloaded source scripts are read as configuration, never executed.
actor MusicService: MusicProviding, MusicLyricsProviding {
    private let session: URLSession
    private var hywKey: String?
    private var lyricsCache: [String: MusicLyrics] = [:]
    private var lyricsOrder: [String] = []
    private var searchCache: [String: (expires: Date, tracks: [MusicTrack])] = [:]
    private var searchOrder: [String] = []
    private var pendingSearches: [String: Task<[MusicTrack], Error>] = [:]
    private let deviceID = "lx-online-" + UUID().uuidString.prefix(10)

    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        self.session = session ?? URLSession(configuration: config)
    }

    private func endpoint(_ base: String, _ params: [String: String]) throws -> URL {
        guard var parts = URLComponents(string: base) else { throw MusicFailure.message("音乐服务地址无效") }
        parts.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { throw MusicFailure.message("音乐服务地址无效") }
        return url
    }

    private func data(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (bytes, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw MusicFailure.message("音乐服务未返回响应") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw MusicFailure.message("\(url.host ?? "音乐服务") 暂时拒绝访问，请换一个音源") }
            if http.statusCode == 429 { throw MusicFailure.message("请求太快了，请稍后重试") }
            throw MusicFailure.message("音乐服务暂不可用（\(http.statusCode)）")
        }
        guard bytes.count < 2_000_000 else { throw MusicFailure.message("音乐服务返回的数据过大") }
        return bytes
    }

    private func json(_ url: URL, headers: [String: String] = [:]) async throws -> [String: Any] {
        let bytes = try await data(url, headers: headers)
        guard let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw MusicFailure.message("音乐服务返回了错误页面，请稍后重试")
        }
        guard (value["code"] as? Int) == 200 else {
            throw MusicFailure.message(value["msg"] as? String ?? value["message"] as? String ?? "音源暂时没有可用的播放地址")
        }
        return value
    }

    func search(_ keyword: String) async throws -> [MusicTrack] {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        let key = keyword.lowercased()
        if let hit = searchCache[key], hit.expires > Date() { return hit.tracks }
        if let task = pendingSearches[key] {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        }
        let task = Task { try await self.fetchSearch(keyword) }
        pendingSearches[key] = task
        defer { pendingSearches[key] = nil }
        let result = try await task.value
        searchCache[key] = (Date().addingTimeInterval(300), result)
        searchOrder.removeAll { $0 == key }; searchOrder.append(key)
        while searchOrder.count > 20 { searchCache.removeValue(forKey: searchOrder.removeFirst()) }
        try Task.checkCancellation()
        return result
    }

    private func fetchSearch(_ keyword: String) async throws -> [MusicTrack] {
        let url = try endpoint("https://yy.zddyr.top/web/api/search.php", ["source": "wy", "keyword": keyword, "page": "1", "count": "30"])
        let response = try await json(url)
        guard let items = response["data"] as? [[String: Any]] else { throw MusicFailure.message("没有取得歌曲列表") }
        var seen = Set<String>()
        return items.compactMap { item in
            let songID = item["songmid"] as? String ?? (item["songmid"] as? NSNumber)?.stringValue ?? ""
            guard !songID.isEmpty, seen.insert(songID).inserted else { return nil }
            let interval = (item["interval"] as? String ?? "0:00").split(separator: ":").compactMap { Double($0) }
            let seconds = interval.count == 2 ? interval[0] * 60 + interval[1] : 0
            return MusicTrack(songID: songID, title: item["name"] as? String ?? "未命名曲目", artist: item["singer"] as? String ?? "未知歌手",
                              album: item["albumName"] as? String ?? "", duration: seconds, artwork: Self.webURL(item["cover"] as? String))
        }
    }

    private static func webURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    func lyrics(_ track: MusicTrack) async throws -> MusicLyrics {
        if let cached = lyricsCache[track.id] { return cached }
        let result: MusicLyrics
        if track.platform == "msr" {
            let url = URL(string: "https://monster-siren.hypergryph.com/api/song/\(track.songID)")!
            let response = try JSONSerialization.jsonObject(with: await data(url)) as? [String: Any]
            guard (response?["code"] as? Int) == 0, let metadata = response?["data"] as? [String: Any] else {
                throw MusicFailure.message("歌词服务暂不可用")
            }
            if let lyricURL = Self.webURL(metadata["lyricUrl"] as? String), lyricURL.scheme == "https" {
                result = MusicLyrics(String(decoding: try await data(lyricURL), as: UTF8.self))
            } else { result = MusicLyrics("") }
        } else if track.platform == "wy" {
            let url = try endpoint("https://music.163.com/api/song/lyric", ["id": track.songID, "lv": "-1", "kv": "-1", "tv": "-1"])
            let response = try await json(url)
            result = MusicLyrics((response["lrc"] as? [String: Any])?["lyric"] as? String ?? "",
                                 translation: (response["tlyric"] as? [String: Any])?["lyric"] as? String ?? "")
        } else { result = MusicLyrics("") }
        try Task.checkCancellation()
        lyricsCache[track.id] = result; lyricsOrder.removeAll { $0 == track.id }; lyricsOrder.append(track.id)
        while lyricsOrder.count > 12 { lyricsCache.removeValue(forKey: lyricsOrder.removeFirst()) }
        return result
    }

    func resolve(_ track: MusicTrack, source: MusicSource) async throws -> URL {
        if track.platform == "msr" {
            let endpoint = URL(string: "https://monster-siren.hypergryph.com/api/song/\(track.songID)")!
            let response = try JSONSerialization.jsonObject(with: await data(endpoint)) as? [String: Any]
            guard let metadata = response?["data"] as? [String: Any],
                  let url = Self.webURL(metadata["sourceUrl"] as? String), url.scheme == "https" else {
                throw MusicFailure.message("塞壬唱片暂时没有返回播放地址")
            }
            return url
        }
        guard track.platform == "wy" else { throw MusicFailure.message("这个试听版本暂时只接入网易云曲目") }
        let response: [String: Any]
        if source == .xinghai {
            let payload: [String: Any] = ["device_id": deviceID, "ip": "0.0.0.0", "timestamp": Int(Date().timeIntervalSince1970), "random": UUID().uuidString.prefix(10).description]
            let token = try JSONSerialization.data(withJSONObject: payload).base64EncodedString()
            let url = try endpoint("https://yy.zddyr.top/lx/api/", ["source": "wy", "songmid": track.songID, "name": track.title, "singer": track.artist,
                                                                 "albumName": track.album, "interval": track.time, "quality": "128k", "_t": String(Int(Date().timeIntervalSince1970))])
            response = try await json(url, headers: ["X-Token": token, "X-Client": "XingHaiMusicSource/v3.2.15 (macOS)", "User-Agent": "lx-music", "Cache-Control": "no-cache"])
        } else {
            let key = try await publicHYWKey()
            let url = try endpoint("https://103.79.184.97/api/music/url", ["platform": "wy", "source": "wy", "songId": track.songID, "songmid": track.songID,
                                                                            "name": track.title, "singer": track.artist, "albumName": track.album, "interval": track.time,
                                                                            "quality": "128k", "key": key])
            response = try await json(url, headers: ["X-Card-Key": key, "User-Agent": "lx-music-desktop/2.0.0"])
        }
        let nested = response["data"] as? [String: Any]
        guard let url = Self.webURL(response["url"] as? String ?? response["data"] as? String ?? nested?["url"] as? String) else {
            throw MusicFailure.message("\(source.label) 没有返回可播放的音频地址")
        }
        // HTTP CDN URLs work in command-line probes but are rejected by bundled AVPlayer.
        guard var secure = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw MusicFailure.message("音源地址无效") }
        secure.scheme = "https"
        guard let secureURL = secure.url else { throw MusicFailure.message("音源地址无效") }
        var probe = URLRequest(url: secureURL)
        probe.httpMethod = "HEAD"
        probe.timeoutInterval = 8
        probe.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, mediaResponse) = try await session.data(for: probe)
        try Task.checkCancellation()
        if let http = mediaResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode), http.statusCode != 405 {
            throw MusicFailure.message("\(source.label) 返回的播放地址已失效")
        }
        return secureURL
    }

    /// Read the provider's public release configuration without embedding a third-party key in our source.
    private func publicHYWKey() async throws -> String {
        if let hywKey { return hywKey }
        let url = try endpoint("https://103.79.184.97/api/releases", ["script": "HYWmusic_公益版", "scriptType": "free", "releaseType": "lx"])
        let release = try await json(url)
        guard let path = (release["data"] as? [String: Any])?["url"] as? String,
              let download = URL(string: path, relativeTo: URL(string: "https://103.79.184.97")!)?.absoluteURL,
              download.host == "103.79.184.97", download.scheme == "https" else { throw MusicFailure.message("HYW 公益配置暂不可用") }
        let script = String(decoding: try await data(download), as: UTF8.self)
        let pattern = #"const\s+CARD_KEY\s*=\s*['"]([^'"\r\n]{1,160})['"]"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
              let range = Range(match.range(at: 1), in: script) else { throw MusicFailure.message("HYW 公益配置已变更，请使用星海") }
        let key = String(script[range])
        guard key.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) else { throw MusicFailure.message("HYW 公益配置格式无效") }
        hywKey = key
        return key
    }
}
