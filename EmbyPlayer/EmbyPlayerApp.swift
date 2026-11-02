import SwiftUI
import AVKit
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Models

struct EmbyItem: Identifiable, Decodable {
    var Id: String
    var Name: String?
    var `Type`: String?
    var SeriesName: String?
    var SeriesId: String?
    var SeasonName: String?
    var IndexNumber: Int?
    var ParentIndexNumber: Int?
    var Overview: String?
    var RunTimeTicks: Int64?
    var ProductionYear: Int?
    var Genres: [String]?
    var CommunityRating: Double?
    var DateCreated: String?
    var id: String { Id }
    var metaLine: String {
        var parts: [String] = []
        if let y = ProductionYear { parts.append("\(y)") }
        if let g = Genres?.first { parts.append(g) }
        if let r = CommunityRating { parts.append(String(format: "%.1f", r)) }
        return parts.joined(separator: " · ")
    }
    var displayName: String {
        if let s = SeriesName, !s.isEmpty {
            if let season = ParentIndexNumber, let ep = IndexNumber {
                return "\(s) S\(season)E\(ep)"
            }
            return s
        }
        return Name ?? "未命名"
    }
    var subtitle: String? {
        if let o = Overview, !o.isEmpty { return o }
        if let t = `Type` { return t }
        return nil
    }
}

struct EmbyItemsResponse: Decodable {
    var Items: [EmbyItem]
    var TotalRecordCount: Int?
}

// Plozz 开源写法：先问服务器 PlaybackInfo，由服务器决定直出还是转码，
// 再用服务器返回的 TranscodingUrl / 直出地址播，不再自己硬拼 master.m3u8。
struct PlaybackInfoResponse: Decodable {
    var PlaySessionId: String?
    var MediaSources: [MediaSourceInfo]?
}

struct MediaSourceInfo: Decodable {
    var Id: String?
    var Container: String?
    var ETag: String?
    var TranscodingUrl: String?
}

struct EmbyUser: Decodable {
    var Id: String
    var Name: String?
}

struct AuthResponse: Decodable {
    var AccessToken: String?
    var User: EmbyUser?
}

struct IPTVChannel: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var group: String
}

struct HistoryItem: Identifiable, Codable {
    var id: String
    var title: String
    var url: String
    var source: String
    var position: Double
    var updated: Date
    var duration: Double?
    var progress: Double {
        guard let d = duration, d > 0 else { return 0 }
        return min(max(position / d, 0), 1)
    }
}

struct PlayItem: Identifiable {
    var id: String
    var title: String
    var url: String
    var source: String
    var searchTitle: String
    var duration: Double
}

struct DanmakuItem: Identifiable {
    var id = UUID()
    var time: Double
    var text: String
}

struct EmbyServer: Identifiable, Codable {
    var id = UUID()
    var name: String
    var url: String
    var username: String
    var token: String
    var userId: String
}

struct Profile: Identifiable, Codable {
    var id = UUID()
    var name: String
}

struct FollowedSeries: Identifiable, Codable {
    var id = UUID()
    var title: String
    var lastCount: Int
    var lastChecked: Date
}

struct SubtitleCue: Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var embyItems: [EmbyItem] = []
    @Published var channels: [IPTVChannel] = []
    @Published var history: [HistoryItem] = []
    @Published var errorMessage = ""
    @Published var isLoading = false
    @Published var playing: PlayItem?
    @Published var player: AVPlayer?
    @Published var tab: Tab = .home
    @Published var closeBrowse = false
    @Published var danmaku: [DanmakuItem] = []
    @Published var danmakuOn = true
    @Published var servers: [EmbyServer] = []
    @Published var profiles: [Profile] = [Profile(name: "我")]
    @Published var followed: [FollowedSeries] = []
    @Published var followNotice = ""
    @Published var subtitles: [SubtitleCue] = []

    // 注意：Store 里不能用 @AppStorage，播放页通过 @EnvironmentObject 读它会编不过。
    // 所以这里全部改成 @Published + UserDefaults 手动存取，效果一样。
    @Published var server = UserDefaults.standard.string(forKey: "embyServer") ?? "" {
        didSet { UserDefaults.standard.set(server, forKey: "embyServer") }
    }
    @Published var danmuServer = UserDefaults.standard.string(forKey: "danmuServer") ?? "" {
        didSet { UserDefaults.standard.set(danmuServer, forKey: "danmuServer") }
    }
    @Published var activeProfileId = UserDefaults.standard.string(forKey: "activeProfileId") ?? "" {
        didSet { UserDefaults.standard.set(activeProfileId, forKey: "activeProfileId") }
    }
    @Published var subtitleSize = (UserDefaults.standard.object(forKey: "subtitleSize") as? Double) ?? 18.0 {
        didSet { UserDefaults.standard.set(subtitleSize, forKey: "subtitleSize") }
    }
    @Published var aiBaseURL = UserDefaults.standard.string(forKey: "aiBaseURL") ?? "" {
        didSet { UserDefaults.standard.set(aiBaseURL, forKey: "aiBaseURL") }
    }
    @Published var aiKey = UserDefaults.standard.string(forKey: "aiKey") ?? "" {
        didSet { UserDefaults.standard.set(aiKey, forKey: "aiKey") }
    }
    @Published var aiModel = UserDefaults.standard.string(forKey: "aiModel") ?? "" {
        didSet { UserDefaults.standard.set(aiModel, forKey: "aiModel") }
    }

    var activeProfileName: String {
        profiles.first { $0.id.uuidString == activeProfileId }?.name ?? profiles.first?.name ?? "我"
    }

    init() {
        loadServers()
        loadProfiles()
        loadFollowed()
        if activeProfileId.isEmpty, let first = profiles.first {
            activeProfileId = first.id.uuidString
        }
        // 老版本单服务器迁移进多服务器列表。
        if servers.isEmpty && !token.isEmpty && !userId.isEmpty {
            servers.append(EmbyServer(name: "Emby 服务器", url: server, username: username, token: token, userId: userId))
            saveServers()
        }
    }

    func loadServers() {
        guard let data = UserDefaults.standard.data(forKey: "embyServers"),
              let d = try? JSONDecoder().decode([EmbyServer].self, from: data) else { return }
        servers = d
    }
    func saveServers() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: "embyServers")
        }
    }
    func loadProfiles() {
        guard let data = UserDefaults.standard.data(forKey: "embyProfiles"),
              let d = try? JSONDecoder().decode([Profile].self, from: data), !d.isEmpty else { return }
        profiles = d
    }
    func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "embyProfiles")
        }
    }
    func loadFollowed() {
        guard let data = UserDefaults.standard.data(forKey: "embyFollowed"),
              let d = try? JSONDecoder().decode([FollowedSeries].self, from: data) else { return }
        followed = d
    }
    func saveFollowed() {
        if let data = try? JSONEncoder().encode(followed) {
            UserDefaults.standard.set(data, forKey: "embyFollowed")
        }
    }
    func switchServer(_ s: EmbyServer) {
        server = s.url; username = s.username; token = s.token; userId = s.userId
        Task { await loadEmbyItems() }
    }
    func switchProfile(_ p: Profile) {
        saveHistory()
        activeProfileId = p.id.uuidString
        loadHistory()
    }
    func toggleFollow(title: String) {
        if let i = followed.firstIndex(where: { $0.title == title }) {
            followed.remove(at: i)
        } else {
            let count = embyItems.filter { $0.SeriesName == title || $0.Name == title }.count
            followed.append(FollowedSeries(title: title, lastCount: count, lastChecked: Date()))
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        saveFollowed()
    }
    func isFollowing(_ title: String) -> Bool {
        followed.contains { $0.title == title }
    }
    func checkFollows() {
        for i in followed.indices {
            let title = followed[i].title
            let count = embyItems.filter { $0.SeriesName == title || $0.Name == title }.count
            if count > followed[i].lastCount {
                let added = count - followed[i].lastCount
                followNotice = "《\(title)》更新了 \(added) 集，快去看。"
                let content = UNMutableNotificationContent()
                content.title = "追剧更新"
                content.body = "《\(title)》更新了 \(added) 集"
                let req = UNNotificationRequest(identifier: "follow-\(title)", content: content, trigger: nil)
                UNUserNotificationCenter.current().add(req)
                followed[i].lastCount = count
            }
            followed[i].lastChecked = Date()
        }
        saveFollowed()
    }
    @Published var username = UserDefaults.standard.string(forKey: "embyUser") ?? "" {
        didSet { UserDefaults.standard.set(username, forKey: "embyUser") }
    }
    @Published var token = UserDefaults.standard.string(forKey: "embyToken") ?? "" {
        didSet { UserDefaults.standard.set(token, forKey: "embyToken") }
    }
    @Published var userId = UserDefaults.standard.string(forKey: "embyUserId") ?? "" {
        didSet { UserDefaults.standard.set(userId, forKey: "embyUserId") }
    }
    @Published var iptvURL = UserDefaults.standard.string(forKey: "iptvURL") ?? "" {
        didSet { UserDefaults.standard.set(iptvURL, forKey: "iptvURL") }
    }
    @Published var netURL = UserDefaults.standard.string(forKey: "netURL") ?? "" {
        didSet { UserDefaults.standard.set(netURL, forKey: "netURL") }
    }

    var loggedIn: Bool { !token.isEmpty && !userId.isEmpty }
    var cleanServer: String { server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

    private func authHeader(includeToken: Bool) -> String {
        var h = "MediaBrowser Client=\"EmbyPlayer\", Device=\"iPhone\", DeviceId=\"embyplayer-iphone-1\", Version=\"1.0\""
        if includeToken && !token.isEmpty { h += ", Token=\"\(token)\"" }
        return h
    }

    func login(server: String, user: String, password: String) async {
        let base = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/Users/AuthenticateByName") else {
            errorMessage = "服务器地址不对，检查一下是不是 http:// 或 https:// 开头"
            return
        }
        isLoading = true
        errorMessage = ""
        defer { isLoading = false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authHeader(includeToken: false), forHTTPHeaderField: "X-Emby-Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["Username": user, "Pw": password])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let auth = try JSONDecoder().decode(AuthResponse.self, from: data)
            guard let tok = auth.AccessToken, let uid = auth.User?.Id else {
                errorMessage = "登录失败：账号或密码不对，或者服务器没返回 token"
                return
            }
            self.server = base
            self.username = user
            self.token = tok
            self.userId = uid
            if let i = servers.firstIndex(where: { $0.url == base && $0.username == user }) {
                servers[i].token = tok; servers[i].userId = uid
            } else {
                servers.append(EmbyServer(name: user + "的服", url: base, username: user, token: tok, userId: uid))
            }
            saveServers()
            await loadEmbyItems()
        } catch {
            errorMessage = "登录失败：\(error.localizedDescription)"
        }
    }

    func logout() {
        token = ""
        userId = ""
        embyItems = []
    }

    func loadEmbyItems() async {
        guard loggedIn else { return }
        let q = "Recursive=true&IncludeItemTypes=Movie,Episode&SortBy=SortName&SortOrder=Ascending&Fields=Overview,RunTimeTicks,SeriesName,SeriesId,ParentIndexNumber,IndexNumber,ProductionYear,Genres,CommunityRating,DateCreated&Limit=300"
        guard let url = URL(string: cleanServer + "/Users/\(userId)/Items?\(q)") else { return }
        var req = URLRequest(url: url)
        req.setValue(authHeader(includeToken: true), forHTTPHeaderField: "X-Emby-Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let resp = try JSONDecoder().decode(EmbyItemsResponse.self, from: data)
            embyItems = resp.Items
            checkFollows()
        } catch {
            errorMessage = "拉片库失败：\(error.localizedDescription)"
        }
    }

    func searchEmby(_ query: String) async {
        guard loggedIn, !query.isEmpty else { return }
        let esc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let q = "Recursive=true&IncludeItemTypes=Movie,Episode,Series&SearchTerm=\(esc)&Fields=Overview,SeriesName&Limit=100"
        guard let url = URL(string: cleanServer + "/Users/\(userId)/Items?\(q)") else { return }
        var req = URLRequest(url: url)
        req.setValue(authHeader(includeToken: true), forHTTPHeaderField: "X-Emby-Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let resp = try JSONDecoder().decode(EmbyItemsResponse.self, from: data)
            embyItems = resp.Items
        } catch {
            errorMessage = "搜索失败：\(error.localizedDescription)"
        }
    }

    func posterURL(for item: EmbyItem) -> URL? {
        guard loggedIn else { return nil }
        return URL(string: cleanServer + "/Items/\(item.Id)/Images/Primary?maxWidth=400&api_key=\(token)")
    }

    func backdropURL(for item: EmbyItem) -> URL? {
        guard loggedIn else { return nil }
        return URL(string: cleanServer + "/Items/\(item.Id)/Images/Backdrop/0?maxWidth=1200&api_key=\(token)")
    }

    func streamURL(for item: EmbyItem) -> URL? {
        // 4K 直通：走 Emby 的 HLS 原画，不在 App 里降画质。
        // 能不能播 4K，最终看片源本身是不是 4K、以及网络带宽够不够。
        URL(string: cleanServer + "/Videos/\(item.Id)/master.m3u8?api_key=\(token)")
    }

    func loadIPTV() async {
        let raw = iptvURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw) else {
            errorMessage = "IPTV 地址不对"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let text = String(data: data, encoding: .utf8) ?? ""
            channels = parseM3U(text)
            if channels.isEmpty { errorMessage = "IPTV 列表拉到了，但一个台都没解析出来，检查一下是不是 M3U 格式" }
        } catch {
            errorMessage = "IPTV 拉取失败：\(error.localizedDescription)"
        }
    }

    func parseM3U(_ text: String) -> [IPTVChannel] {
        var out: [IPTVChannel] = []
        var pendingName = ""
        var pendingGroup = "未分组"
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:") {
                pendingGroup = "未分组"
                if let r = line.range(of: "group-title=\"") {
                    let rest = line[r.upperBound...]
                    if let end = rest.firstIndex(of: "\"") {
                        pendingGroup = String(rest[..<end])
                    }
                }
                if let comma = line.lastIndex(of: ",") {
                    pendingName = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    pendingName = "未命名频道"
                }
            } else if line.hasPrefix("http") {
                if !pendingName.isEmpty {
                    out.append(IPTVChannel(name: pendingName, url: line, group: pendingGroup))
                    pendingName = ""
                }
            }
        }
        return out
    }

    func play(url: String, title: String, source: String, searchTitle: String? = nil, duration: Double = 0) {
        guard let u = URL(string: url) else {
            errorMessage = "这个播放地址打不开"
            return
        }
        let p = AVPlayer(url: u)
        player = p
        playing = PlayItem(id: UUID().uuidString, title: title, url: url, source: source, searchTitle: searchTitle ?? title, duration: duration)
        danmaku = []
        subtitles = []
        p.play()
        Task { await loadDanmaku(for: playing?.searchTitle ?? title) }
    }

    func playEmby(_ item: EmbyItem) {
        Task { await playEmbyAsync(item) }
    }

    // Plozz 式播放：POST PlaybackInfo 让服务器选源。
    // Emby 把空限制当成严格限制，所以 MaxStreamingBitrate 给 Int64 最大值（Plozz 同款处理）。
    // 拿到 TranscodingUrl 就走转码/重封装地址；没有就走直出 stream；问服务器失败才回退旧地址。
    func playEmbyAsync(_ item: EmbyItem) async {
        let kw = (item.SeriesName?.isEmpty == false ? item.SeriesName! : (item.Name ?? item.displayName))
        let dur = item.RunTimeTicks.map { Double($0) / 10_000_000 } ?? 0
        var finalURL: String?
        do {
            guard let url = URL(string: cleanServer + "/Items/\(item.Id)/PlaybackInfo?UserId=\(userId)") else { throw URLError(.badURL) }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(authHeader(includeToken: true), forHTTPHeaderField: "X-Emby-Authorization")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "UserId": userId,
                "MaxStreamingBitrate": 9223372036854775807,
                "EnableDirectPlay": true,
                "EnableDirectStream": true,
                "EnableTranscoding": true
            ])
            let (data, _) = try await URLSession.shared.data(for: req)
            let info = try JSONDecoder().decode(PlaybackInfoResponse.self, from: data)
            if let src = info.MediaSources?.first {
                if let t = src.TranscodingUrl, !t.isEmpty {
                    // 服务器给的可能是相对地址，拼上服务器域名；没带 api_key 就补一个。
                    var full = t.hasPrefix("http") ? t : cleanServer + (t.hasPrefix("/") ? t : "/" + t)
                    if !full.lowercased().contains("api_key=") {
                        full += (full.contains("?") ? "&" : "?") + "api_key=\(token)"
                    }
                    finalURL = full
                } else {
                    let container = src.Container ?? "mp4"
                    let sid = src.Id ?? item.Id
                    finalURL = cleanServer + "/Videos/\(item.Id)/stream.\(container)?static=true&mediaSourceId=\(sid)&api_key=\(token)"
                }
            }
        } catch {
            finalURL = nil
        }
        if finalURL == nil, let u = streamURL(for: item) {
            finalURL = u.absoluteString
        }
        if let f = finalURL {
            play(url: f, title: item.displayName, source: "Emby", searchTitle: kw, duration: dur)
        } else {
            errorMessage = "这部拿不到播放地址，服务器没返回可用源"
        }
    }

    // 弹幕：接 danmu_api 兼容弹弹play的服务器（自己部署或公开实例）。
    // 没填服务器地址时不造假弹幕，播放页会提示去设置里填。
    func loadDanmaku(for title: String) async {
        let base = danmuServer.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return }
        let kw = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        guard let searchURL = URL(string: base + "/api/v2/search/anime?keyword=\(kw)") else { return }
        do {
            let (sdata, _) = try await URLSession.shared.data(from: searchURL)
            guard let animeId = firstAnimeId(from: sdata) else { return }
            guard let cURL = URL(string: base + "/api/v2/comment/\(animeId)?format=json") else { return }
            let (cdata, _) = try await URLSession.shared.data(from: cURL)
            let items = parseDanmakuJSON(cdata)
            danmaku = Array(items.sorted { $0.time < $1.time }.prefix(800))
        } catch {
            // 弹幕拉不到不影响正片播放，只是不显示弹幕。
        }
    }

    private func firstAnimeId(from data: Data) -> Int? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let animes = obj["animes"] as? [[String: Any]], let first = animes.first {
            if let v = first["animeId"] as? Int { return v }
            if let v = first["animeId"] as? String { return Int(v) }
        }
        if let v = obj["animeId"] as? Int { return v }
        return nil
    }

    private func parseDanmakuJSON(_ data: Data) -> [DanmakuItem] {
        var out: [DanmakuItem] = []
        func scan(_ value: Any) {
            if let arr = value as? [Any] {
                for v in arr { scan(v) }
            } else if let dict = value as? [String: Any] {
                if let p = dict["p"] as? String, let m = dict["m"] as? String {
                    let parts = p.split(separator: ",")
                    if let t = Double(parts.first ?? "") {
                        out.append(DanmakuItem(time: t, text: m))
                    }
                } else if let t = (dict["time"] as? Double) ?? (dict["t"] as? Double),
                          let txt = (dict["text"] as? String) ?? (dict["content"] as? String) ?? (dict["m"] as? String) {
                    out.append(DanmakuItem(time: t, text: txt))
                } else {
                    for v in dict.values { scan(v) }
                }
            }
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) { scan(obj) }
        return out
    }

    func parseSRT(_ text: String) -> [SubtitleCue] {
        func seconds(_ s: String) -> Double {
            let parts = s.split(separator: ":")
            guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]) else { return 0 }
            let secParts = parts[2].split(separator: ",")
            let sec = Double(secParts.first ?? "") ?? 0
            let ms = secParts.count > 1 ? (Double(secParts[1]) ?? 0) / 1000 : 0
            return h * 3600 + m * 60 + sec + ms
        }
        var out: [SubtitleCue] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard lines.count >= 2 else { continue }
            let timeLine = lines.first { $0.contains("-->") } ?? ""
            let range = timeLine.components(separatedBy: "-->")
            guard range.count == 2 else { continue }
            let txtLines = lines.filter { !$0.contains("-->") && Int($0.trimmingCharacters(in: .whitespaces)) == nil }
            let txt = txtLines.joined(separator: "\n")
            if !txt.isEmpty {
                out.append(SubtitleCue(start: seconds(range[0].trimmingCharacters(in: .whitespaces)), end: seconds(range[1].trimmingCharacters(in: .whitespaces)), text: txt))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    // AI 字幕翻译：把已导入的外挂字幕逐条翻成中文，做成双语。
    // 需要用户自己填 OpenAI 兼容接口地址 + Key + 模型名；不填就只显示原字幕，不冒充 AI 生成。
    func translateSubtitles() async {
        let base = aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, !aiKey.isEmpty, !subtitles.isEmpty else {
            errorMessage = "先导入字幕，再在设置里填 AI 接口地址、Key 和模型名"
            return
        }
        guard let url = URL(string: base + "/chat/completions") else { return }
        var translated = subtitles
        let model = aiModel.isEmpty ? "gpt-4o-mini" : aiModel
        var idx = 0
        while idx < subtitles.count {
            let batch = Array(subtitles[idx..<min(idx + 20, subtitles.count)])
            let joined = batch.enumerated().map { "\($0.offset): \($0.element.text.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(aiKey)", forHTTPHeaderField: "Authorization")
            let body: [String: Any] = [
                "model": model,
                "temperature": 0.2,
                "messages": [
                    ["role": "system", "content": "你是字幕翻译。把每条字幕翻译成简体中文，只输出相同行数、相同编号的译文，不要加解释。"],
                    ["role": "user", "content": joined]
                ]
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = obj["choices"] as? [[String: Any]],
                   let msg = choices.first?["message"] as? [String: Any],
                   let content = msg["content"] as? String {
                    let lines = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    for (j, line) in lines.enumerated() where idx + j < translated.count {
                        let clean = line.replacingOccurrences(of: "^\\d+[:：]\\s*", with: "", options: .regularExpression)
                        if !clean.isEmpty && clean != batch[j].text {
                            translated[idx + j].text = batch[j].text + "\n" + clean
                        }
                    }
                }
            } catch {
                errorMessage = "AI 翻译失败：\(error.localizedDescription)"
                return
            }
            idx += 20
        }
        subtitles = translated
    }

    func stopPlaying() {
        if let p = player, let cur = playing {
            let pos = p.currentTime().seconds
            if pos.isFinite && pos > 5 {
                upsertHistory(title: cur.title, url: cur.url, source: cur.source, position: pos, duration: cur.duration > 0 ? cur.duration : nil)
            }
        }
        player?.pause()
        player = nil
        playing = nil
    }

    func upsertHistory(title: String, url: String, source: String, position: Double, duration: Double? = nil) {
        if let i = history.firstIndex(where: { $0.url == url }) {
            history[i].position = position
            history[i].updated = Date()
            if let d = duration { history[i].duration = d }
        } else {
            history.append(HistoryItem(id: UUID().uuidString, title: title, url: url, source: source, position: position, updated: Date(), duration: duration))
        }
        history.sort { $0.updated > $1.updated }
        saveHistory()
    }

    private var historyKey: String {
        let pid = activeProfileId.isEmpty ? (profiles.first?.id.uuidString ?? "default") : activeProfileId
        return "embyHistory_\(pid)"
    }
    func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let d = try? JSONDecoder().decode([HistoryItem].self, from: data) else {
            history = []
            return
        }
        history = d
    }

    func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    func clearHistory() {
        history = []
        saveHistory()
    }
}

// MARK: - App

@main
struct EmbyPlayerApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .onAppear { store.loadHistory() }
        }
    }
}

enum Tab: String, CaseIterable {
    case home, history, library, settings
    var title: String {
        switch self {
        case .home: return "发现"
        case .history: return "我的"
        case .library: return "资源库"
        case .settings: return "设置"
        }
    }
    var icon: String {
        switch self {
        case .home: return "sparkles"
        case .history: return "person.fill"
        case .library: return "internaldrive.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var showDocPicker = false
    @State private var showSearch = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch store.tab {
                case .home: HomeView()
                case .library: LibraryView(showDocPicker: $showDocPicker)
                case .history: HistoryView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 84)
            .background(Color(red: 0.96, green: 0.95, blue: 0.99))

            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { store.tab = t }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: t.icon)
                                .font(.system(size: 20, weight: .semibold))
                            Text(t.title).font(.system(size: 11))
                        }
                        .foregroundStyle(store.tab == t ? .black : .gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(store.tab == t ? Color.black.opacity(0.06) : Color.clear)
                        .clipShape(Capsule())
                    }
                }
                Button { showSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background(Color.white)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                }
                .padding(.trailing, 4)
            }
            .padding(8)
            .background(Color.white.opacity(0.92))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .sheet(isPresented: $showSearch) { SearchView() }
        .sheet(isPresented: $showDocPicker) {
            DocumentPicker { url in
                store.play(url: url.absoluteString, title: url.lastPathComponent, source: "本地文件")
            }
        }
        .fullScreenCover(item: $store.playing) { _ in
            PlayerView()
        }
    }
}

// MARK: - Home (Rex-style Discover)

struct SectionHeader: View {
    var title: String
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(.black)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.gray)
            }
        }
        .padding(.horizontal)
    }
}

struct PosterCard: View {
    @EnvironmentObject var store: Store
    var item: EmbyItem
    var width: CGFloat = 110
    var height: CGFloat = 165
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.white)
                if let u = store.posterURL(for: item) {
                    AsyncImage(url: u) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        VStack { Image(systemName: "photo").foregroundStyle(.gray); Text(item.displayName).font(.caption).foregroundStyle(.gray).lineLimit(2).multilineTextAlignment(.center).padding(6) }
                    }
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
            Text(item.displayName).font(.system(size: 13)).lineLimit(1).foregroundStyle(.black)
            if let y = item.ProductionYear {
                Text(String(y)).font(.system(size: 12)).foregroundStyle(.gray)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var detailItem: EmbyItem?
    @State private var browseTitle = ""
    @State private var browseItems: [EmbyItem] = []
    @State private var showBrowse = false

    var movies: [EmbyItem] { store.embyItems.filter { $0.Type == "Movie" } }
    var seriesReps: [EmbyItem] {
        var seen: [String] = []
        var out: [EmbyItem] = []
        for item in store.embyItems where item.SeriesName != nil {
            let key = item.SeriesName!
            if !seen.contains(key) { seen.append(key); out.append(item) }
        }
        return out
    }
    var recent: [EmbyItem] {
        store.embyItems.sorted { ($0.DateCreated ?? "") > ($1.DateCreated ?? "") }
    }
    var heroItems: [EmbyItem] { Array(movies.prefix(5)) }

    func openBrowse(title: String, items: [EmbyItem]) {
        browseTitle = title; browseItems = items; showBrowse = true
    }
    func timeText(_ seconds: Double) -> String {
        let m = Int(seconds) / 60; let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Hero 轮播：大海报 + 渐变 + 标题简介，跟 Rex 首页顶部一样。
                    if !heroItems.isEmpty {
                        TabView {
                            ForEach(heroItems) { item in
                                Button { detailItem = item } label: {
                                    ZStack(alignment: .bottomLeading) {
                                        if let u = store.backdropURL(for: item) {
                                            AsyncImage(url: u) { img in img.resizable().scaledToFill() } placeholder: {
                                                if let p = store.posterURL(for: item) {
                                                    AsyncImage(url: p) { img in img.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                                                } else { Color.gray.opacity(0.2) }
                                            }
                                        } else if let p = store.posterURL(for: item) {
                                            AsyncImage(url: p) { img in img.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                                        } else {
                                            Color.gray.opacity(0.2)
                                        }
                                        LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(item.displayName).font(.system(size: 26, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                                            if !item.metaLine.isEmpty {
                                                Text(item.metaLine).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                                            }
                                            if let ov = item.Overview, !ov.isEmpty {
                                                Text(ov).font(.footnote).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                                            }
                                            HStack {
                                                Label("播放", systemImage: "play.fill")
                                                    .font(.headline).foregroundStyle(.black)
                                                    .padding(.horizontal, 18).padding(.vertical, 8)
                                                    .background(Color.white).clipShape(Capsule())
                                            }
                                            .padding(.top, 4)
                                        }
                                        .padding()
                                        .padding(.bottom, 20)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(height: 420)
                        .tabViewStyle(.page)
                        .clipShape(RoundedRectangle(cornerRadius: 0))
                    } else if !store.loggedIn {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("还没连 Emby").font(.title2.bold())
                            Text("去“设置”里填服务器地址和账号，登录后这里就是海报墙。").foregroundStyle(.secondary)
                        }
                        .padding()
                    }

                    if !store.followNotice.isEmpty {
                        Text(store.followNotice).font(.footnote).foregroundStyle(.blue).padding(.horizontal)
                    }

                    // 继续观看：横滑大卡 + 看到几分几秒 + 进度条。
                    if !store.history.isEmpty {
                        SectionHeader(title: "继续观看") { }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(store.history.prefix(10)) { h in
                                    Button {
                                        store.play(url: h.url, title: h.title, source: h.source)
                                        if let p = store.player {
                                            p.seek(to: CMTime(seconds: h.position, preferredTimescale: 600))
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ZStack(alignment: .bottomLeading) {
                                                RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.15))
                                                    .frame(width: 280, height: 158)
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text("看到 \(timeText(h.position))").font(.footnote).foregroundStyle(.white).shadow(radius: 2)
                                                    if h.progress > 0 {
                                                        GeometryReader { geo in
                                                            ZStack(alignment: .leading) {
                                                                Capsule().fill(Color.white.opacity(0.4)).frame(height: 4)
                                                                Capsule().fill(Color.white).frame(width: geo.size.width * h.progress, height: 4)
                                                            }
                                                        }
                                                        .frame(height: 4)
                                                    }
                                                }
                                                .padding(10)
                                            }
                                            Text(h.title).font(.system(size: 14)).lineLimit(1).foregroundStyle(.black)
                                            Text("\(h.source) · \(timeText(h.position))").font(.footnote).foregroundStyle(.gray)
                                        }
                                        .frame(width: 280, alignment: .leading)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    if !movies.isEmpty {
                        SectionHeader(title: "电影") { openBrowse(title: "电影", items: movies) }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(movies) { item in
                                    Button { detailItem = item } label: { PosterCard(item: item) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    if !seriesReps.isEmpty {
                        SectionHeader(title: "剧集") { openBrowse(title: "剧集", items: seriesReps) }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(seriesReps) { item in
                                    Button { detailItem = item } label: { PosterCard(item: item) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    if !recent.isEmpty {
                        SectionHeader(title: "最近更新") { openBrowse(title: "最近更新", items: Array(recent.prefix(30))) }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(Array(recent.prefix(20))) { item in
                                    Button { detailItem = item } label: { PosterCard(item: item) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .background(Color(red: 0.96, green: 0.95, blue: 0.99))
            .navigationBarHidden(true)
            .task {
                if store.loggedIn && store.embyItems.isEmpty { await store.loadEmbyItems() }
            }
            .sheet(item: $detailItem) { item in
                ItemDetailView(item: item)
            }
            .sheet(isPresented: $showBrowse) {
                NavigationStack {
                    ScrollView {
                        EmbyGrid(items: browseItems).padding()
                    }
                    .navigationTitle(browseTitle)
                    .toolbar { Button("关闭") { showBrowse = false } }
                }
            }
            .onChange(of: store.closeBrowse) { v in
                if v { showBrowse = false }
            }
        }
    }
}

// MARK: - Item detail

struct ItemDetailView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var item: EmbyItem
    var seriesName: String { item.SeriesName ?? item.Name ?? item.displayName }
    // 弹窗里直接起播放会被上层弹窗挡住：先关详情、关掉可能的上层片库弹窗，
    // 等弹窗落下后再起播，播放器才能正常弹出来。
    func playAndClose(_ it: EmbyItem) {
        store.closeBrowse = true
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            store.closeBrowse = false
            store.playEmby(it)
        }
    }
    var episodes: [EmbyItem] {
        store.embyItems.filter { $0.SeriesName == seriesName }
            .sorted {
                if $0.ParentIndexNumber != $1.ParentIndexNumber { return ($0.ParentIndexNumber ?? 0) < ($1.ParentIndexNumber ?? 0) }
                return ($0.IndexNumber ?? 0) < ($1.IndexNumber ?? 0)
            }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack(alignment: .bottomLeading) {
                        if let u = store.backdropURL(for: item) {
                            AsyncImage(url: u) { img in img.resizable().scaledToFill() } placeholder: {
                                if let p = store.posterURL(for: item) {
                                    AsyncImage(url: p) { img in img.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                                } else { Color.gray.opacity(0.2) }
                            }
                        } else if let p = store.posterURL(for: item) {
                            AsyncImage(url: p) { img in img.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                        } else {
                            Color.gray.opacity(0.2)
                        }
                    }
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.displayName).font(.title2.bold())
                        if !item.metaLine.isEmpty { Text(item.metaLine).foregroundStyle(.secondary) }
                        if let ov = item.Overview, !ov.isEmpty { Text(ov) }
                        Button {
                            playAndClose(item)
                        } label: {
                            Label("播放", systemImage: "play.fill")
                                .font(.headline).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.black).clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        if episodes.count > 1 {
                            Text("选集（\(episodes.count) 集）").font(.headline).padding(.top, 8)
                            ForEach(episodes) { ep in
                                Button {
                                    playAndClose(ep)
                                } label: {
                                    HStack {
                                        Text(ep.displayName).foregroundStyle(.black)
                                        Spacer()
                                        Image(systemName: "play.circle")
                                    }
                                    .padding(.vertical, 8)
                                }
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .toolbar { Button("关闭") { dismiss() } }
        }
    }
}

// MARK: - Library (Rex-style server cards)

struct LibraryView: View {
    @EnvironmentObject var store: Store
    @Binding var showDocPicker: Bool
    @State private var showEmby = false
    @State private var showIPTV = false
    @State private var showNet = false
    @State private var editing = false

    var movieCount: Int { store.embyItems.filter { $0.Type == "Movie" }.count }
    var seriesCount: Int {
        var seen: [String] = []
        for item in store.embyItems where item.SeriesName != nil {
            if !seen.contains(item.SeriesName!) { seen.append(item.SeriesName!) }
        }
        return seen.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("资源库").font(.system(size: 34, weight: .bold))
                        Spacer()
                        Button(editing ? "完成" : "编辑") { editing.toggle() }
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Color.white).clipShape(Capsule())
                            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
                    }

                    Text("媒体服务器").font(.system(size: 15)).foregroundStyle(.gray)
                    if store.servers.isEmpty {
                        Text("还没有服务器，去“设置”里登录 Emby，登录后这里会出现服务器卡片。")
                            .foregroundStyle(.secondary).font(.subheadline)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
                            ForEach(store.servers) { s in
                                let active = (s.url == store.server && s.username == store.username)
                                Button {
                                    if editing {
                                        if let i = store.servers.firstIndex(where: { $0.id == s.id }) {
                                            store.servers.remove(at: i); store.saveServers()
                                        }
                                    } else {
                                        // 点服务器卡 = 进这个服务器里面：切服务器并回到发现页。
                                        store.switchServer(s)
                                        store.tab = .home
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Image(systemName: editing ? "xmark.circle.fill" : "play.rectangle.fill")
                                                .font(.title2).foregroundStyle(editing ? .red : .green)
                                            Spacer()
                                            Circle().fill(active ? Color.green : Color.gray.opacity(0.3)).frame(width: 8, height: 8)
                                        }
                                        Spacer()
                                        Text(s.name.isEmpty ? s.url : s.name).font(.headline).foregroundStyle(.black).lineLimit(1)
                                        Text("主线路").font(.footnote).foregroundStyle(.gray)
                                        if active && store.loggedIn {
                                            Text("电影:\(movieCount)  剧集:\(seriesCount)").font(.footnote).foregroundStyle(.gray)
                                        } else {
                                            Text(active ? "已登录" : "点一下切换").font(.footnote).foregroundStyle(.gray)
                                        }
                                    }
                                    .padding()
                                    .frame(height: 150)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 20))
                                    .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
                                }
                            }
                        }
                    }

                    Text("其他").font(.system(size: 15)).foregroundStyle(.gray)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
                        LibraryCard(title: "IPTV", icon: "tv.fill", foot: store.channels.isEmpty ? "未导入列表" : "\(store.channels.count) 个台") {
                            showIPTV = true
                        }
                        LibraryCard(title: "相册视频", icon: "photo.on.rectangle", foot: "本地文件 · 选文件播放") {
                            showDocPicker = true
                        }
                        LibraryCard(title: "网络链接", icon: "link", foot: "粘贴直链播放") {
                            showNet = true
                        }
                    }

                    if !store.errorMessage.isEmpty {
                        Text(store.errorMessage).foregroundStyle(.red).font(.footnote)
                    }
                    Text("4K 说明：本 App 走原画直通，不转码、不降画质。能不能播 4K 看两点：片源本身是不是 4K，以及你的网络带宽够不够。iPhone 本身要支持 HEVC / Dolby Vision 解码。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(Color(red: 0.96, green: 0.95, blue: 0.99))
            .navigationBarHidden(true)
            .sheet(isPresented: $showEmby) { EmbyBrowseView() }
            .sheet(isPresented: $showIPTV) { IPTVView() }
            .sheet(isPresented: $showNet) { NetLinkView() }
            .task {
                if store.loggedIn && store.embyItems.isEmpty { await store.loadEmbyItems() }
                if !store.iptvURL.isEmpty && store.channels.isEmpty { await store.loadIPTV() }
            }
        }
    }
}

struct LibraryCard: View {
    var title: String
    var icon: String
    var foot: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.headline).foregroundStyle(.black)
                    Spacer()
                    Image(systemName: icon).font(.title2).foregroundStyle(.blue)
                }
                Spacer()
                Text(foot).font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
            .frame(height: 130)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        }
    }
}

// MARK: - Emby browse

struct EmbyBrowseView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                if !store.loggedIn {
                    Text("还没登录 Emby，先去设置里登录。").foregroundStyle(.secondary).padding()
                } else if store.embyItems.isEmpty {
                    Text("片库是空的，或者正在拉取，稍等一下再进。").foregroundStyle(.secondary).padding()
                } else {
                    EmbyGrid(items: store.embyItems)
                        .padding()
                }
            }
            .navigationTitle("Emby 片库")
            .toolbar { Button("关闭") { dismiss() } }
            .task { await store.loadEmbyItems() }
        }
    }
}

struct EmbyGrid: View {
    @EnvironmentObject var store: Store
    var items: [EmbyItem]
    @State private var detailItem: EmbyItem?
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(items) { item in
                Button { detailItem = item } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14).fill(Color.white)
                            if let u = store.posterURL(for: item) {
                                AsyncImage(url: u) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    VStack { Image(systemName: "photo").foregroundStyle(.gray); Text(item.displayName).font(.caption).foregroundStyle(.gray).lineLimit(2).multilineTextAlignment(.center).padding(4) }
                                }
                            }
                        }
                        .frame(height: 165)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
                        Text(item.displayName).font(.footnote).lineLimit(1).foregroundStyle(.black)
                        if let y = item.ProductionYear {
                            Text(String(y)).font(.caption).foregroundStyle(.gray)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    let title = item.SeriesName ?? item.Name ?? item.displayName
                    Button(store.isFollowing(title) ? "取消追剧" : "追这部剧") {
                        store.toggleFollow(title: title)
                    }
                }
            }
        }
        .sheet(item: $detailItem) { item in
            ItemDetailView(item: item)
        }
    }
}

// MARK: - IPTV

struct IPTVView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    var filtered: [IPTVChannel] {
        if query.isEmpty { return store.channels }
        return store.channels.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.group.localizedCaseInsensitiveContains(query) }
    }
    var groups: [String] {
        var seen: [String] = []
        for c in filtered where !seen.contains(c.group) { seen.append(c.group) }
        return seen
    }
    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.self) { g in
                    Section(g) {
                        ForEach(filtered.filter { $0.group == g }) { ch in
                            Button {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    store.play(url: ch.url, title: ch.name, source: "IPTV")
                                }
                            } label: {
                                HStack {
                                    Text(ch.name)
                                    Spacer()
                                    Image(systemName: "play.circle")
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "搜台名")
            .navigationTitle("IPTV")
            .toolbar { Button("关闭") { dismiss() } }
            .task { if !store.iptvURL.isEmpty { await store.loadIPTV() } }
        }
    }
}

// MARK: - Network link

struct NetLinkView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("粘贴视频直链，如 https://.../xxx.m3u8", text: $store.netURL)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Button("播放") {
                    let u = store.netURL
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        store.play(url: u, title: "网络链接", source: "网络链接")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.netURL.isEmpty)
                Text("只播你自己有的直链，App 本身不提供任何片源。")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("网络链接")
            .toolbar { Button("关闭") { dismiss() } }
        }
    }
}

// MARK: - History / Calendar / Stats

struct HistoryView: View {
    @EnvironmentObject var store: Store
    @State private var segment = 0
    @State private var month = Date()
    @State private var selectedDay: Date?

    private var totalMinutes: Int {
        Int(store.history.reduce(0) { $0 + $1.position } / 60)
    }
    private var totalDays: Int {
        Set(store.history.map { Calendar.current.startOfDay(for: $0.updated) }).count
    }
    private var daysInMonth: [Date] {
        let cal = Calendar.current
        guard let range = cal.range(of: .day, in: .month, for: month),
              let first = cal.date(from: cal.dateComponents([.year, .month], from: month)) else { return [] }
        return range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: first) }
    }
    private func hasHistory(_ day: Date) -> Bool {
        store.history.contains { Calendar.current.isDate($0.updated, inSameDayAs: day) }
    }
    private func historyOn(_ day: Date) -> [HistoryItem] {
        store.history.filter { Calendar.current.isDate($0.updated, inSameDayAs: day) }
    }

    var body: some View {
        NavigationStack {
            VStack {
                Picker("", selection: $segment) {
                    Text("记录").tag(0)
                    Text("日历").tag(1)
                    Text("统计").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                if segment == 0 {
                    List {
                        ForEach(store.history) { h in
                            Button {
                                store.play(url: h.url, title: h.title, source: h.source)
                                if let p = store.player {
                                    p.seek(to: CMTime(seconds: h.position, preferredTimescale: 600))
                                }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(h.title)
                                    Text("\(h.source) · 已看到 \(Int(h.position / 60)) 分钟")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { idx in
                            store.history.remove(atOffsets: idx)
                            store.saveHistory()
                        }
                    }
                } else if segment == 1 {
                    ScrollView {
                        VStack(spacing: 12) {
                            HStack {
                                Button("<") { month = Calendar.current.date(byAdding: .month, value: -1, to: month) ?? month }
                                Spacer()
                                Text(month, format: .dateTime.year().month()).font(.headline)
                                Spacer()
                                Button(">") { month = Calendar.current.date(byAdding: .month, value: 1, to: month) ?? month }
                            }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7)) {
                                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                                ForEach(daysInMonth, id: \.self) { day in
                                    Button {
                                        selectedDay = day
                                    } label: {
                                        Text("\(Calendar.current.component(.day, from: day))")
                                            .frame(maxWidth: .infinity, minHeight: 36)
                                            .background(hasHistory(day) ? Color.blue.opacity(0.25) : Color.clear)
                                            .clipShape(Circle())
                                    }
                                }
                            }
                            if let day = selectedDay {
                                VStack(alignment: .leading) {
                                    Text(day, format: .dateTime.year().month().day()).font(.headline)
                                    ForEach(historyOn(day)) { h in
                                        Text("· \(h.title)（\(h.source)）").font(.footnote)
                                    }
                                    if historyOn(day).isEmpty { Text("这天没看。").font(.footnote).foregroundStyle(.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding()
                    }
                } else {
                    List {
                        Text("看过 \(store.history.count) 部")
                        Text("累计已看 \(totalMinutes) 分钟")
                        Text("看过 \(totalDays) 天")
                        Text("统计不限 7 天，全部记录都算在内。").font(.footnote).foregroundStyle(.secondary)
                        ForEach(Dictionary(grouping: store.history, by: { $0.source }).sorted(by: { $0.key < $1.key }), id: \.key) { src, list in
                            Text("\(src)：\(list.count) 部")
                        }
                    }
                }
            }
            .navigationTitle("记录")
            .toolbar {
                if !store.history.isEmpty && segment == 0 {
                    Button("清空") { store.clearHistory() }
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var server = ""
    @State private var user = ""
    @State private var password = ""
    @State private var iptv = ""
    @State private var danmu = ""
    @State private var newProfile = ""
    @State private var aiBase = ""
    @State private var aiKey = ""
    @State private var aiModel = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Emby 服务器") {
                    TextField("服务器地址，如 https://xxx:8096", text: $server)
                        .autocapitalization(.none).disableAutocorrection(true)
                    TextField("用户名", text: $user)
                        .autocapitalization(.none).disableAutocorrection(true)
                    SecureField("密码", text: $password)
                    Button(busy ? "登录中…" : (store.loggedIn ? "重新登录" : "登录")) {
                        busy = true
                        Task {
                            await store.login(server: server, user: user, password: password)
                            password = ""
                            busy = false
                        }
                    }
                    .disabled(server.isEmpty || user.isEmpty)
                    if store.loggedIn {
                        Text("已登录：\(store.username)")
                        Button("退出登录", role: .destructive) { store.logout() }
                    }
                }
                Section("资源库（可加多个，不限数量）") {
                    ForEach(store.servers) { s in
                        Button {
                            store.switchServer(s)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(s.name)
                                    Text(s.url).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.server == s.url && store.username == s.username {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    .onDelete { idx in
                        store.servers.remove(atOffsets: idx)
                        store.saveServers()
                    }
                    Text("登录表单里新登一个服，就会自动加进这里，点一下就能切服，高画质不限每天几部。")
                        .font(.footnote)
                }
                Section("家庭成员观影环境（不限数量）") {
                    ForEach(store.profiles) { p in
                        Button {
                            store.switchProfile(p)
                        } label: {
                            HStack {
                                Text(p.name)
                                Spacer()
                                if store.activeProfileId == p.id.uuidString {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    .onDelete { idx in
                        if store.profiles.count > 1 {
                            store.profiles.remove(atOffsets: idx)
                            store.saveProfiles()
                            if let first = store.profiles.first { store.switchProfile(first) }
                        }
                    }
                    HStack {
                        TextField("新成员名字", text: $newProfile)
                        Button("添加") {
                            if !newProfile.isEmpty {
                                let p = Profile(name: newProfile)
                                store.profiles.append(p)
                                store.saveProfiles()
                                newProfile = ""
                            }
                        }
                    }
                    Text("每个成员有自己的观看记录和继续观看，互不干扰。")
                        .font(.footnote)
                }
                Section("追剧通知") {
                    if store.followed.isEmpty {
                        Text("还没追任何剧，在片库里长按一部点“追这部剧”。").font(.footnote)
                    }
                    ForEach(store.followed) { f in
                        Text("\(f.title) · 已记 \(f.lastCount) 集")
                    }
                    if !store.followNotice.isEmpty {
                        Text(store.followNotice).font(.footnote).foregroundStyle(.blue)
                    }
                }
                Section("IPTV") {
                    TextField("M3U 列表地址", text: $iptv)
                        .autocapitalization(.none).disableAutocorrection(true)
                    Button("保存并拉取") {
                        store.iptvURL = iptv
                        Task { await store.loadIPTV() }
                    }
                    Text(store.channels.isEmpty ? "还没导入" : "已导入 \(store.channels.count) 个台")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("弹幕 / 字幕 / 音轨") {
                    TextField("弹幕服务器地址，如 http://你的服务器:端口/令牌", text: $danmu)
                        .autocapitalization(.none).disableAutocorrection(true)
                    Button("保存弹幕服务器") { store.danmuServer = danmu }
                    Toggle("播放时显示弹幕", isOn: Binding(get: { store.danmakuOn }, set: { store.danmakuOn = $0 }))
                    Text("弹幕接 danmu_api（兼容弹弹play）服务器：填你自己部署的地址，不填就没有弹幕，App 不会造假弹幕。字幕和音轨在播放页点“字幕 / 音轨”切，取决于片源本身带不带多条轨道。")
                        .font(.footnote)
                }
                Section("AI 字幕翻译") {
                    TextField("AI 接口地址（OpenAI 兼容，如 https://api.openai.com/v1）", text: $aiBase)
                        .autocapitalization(.none).disableAutocorrection(true)
                    SecureField("AI Key", text: $aiKey)
                    TextField("模型名，如 gpt-4o-mini", text: $aiModel)
                        .autocapitalization(.none).disableAutocorrection(true)
                    Button("保存 AI 设置") {
                        store.aiBaseURL = aiBase; store.aiKey = aiKey; store.aiModel = aiModel
                    }
                    Button("翻译当前已导入字幕成双语") {
                        Task { await store.translateSubtitles() }
                    }
                    .disabled(store.subtitles.isEmpty)
                    Slider(value: Binding(get: { store.subtitleSize }, set: { store.subtitleSize = $0 }), in: 12...28, step: 1) {
                        Text("字幕大小")
                    }
                    Text("字幕大小：\(Int(store.subtitleSize))")
                    Text("说明：本版 AI 字幕是“翻译已导入字幕”，不是凭空语音识别生成。纯语音转字幕需要服务器端 ASR 服务，手机直接对着流媒体做实时识别做不到可靠效果，那部分我不给你画饼。")
                        .font(.footnote)
                }
                Section("播放") {
                    Text("原画直通：不转码。4K 需要片源是 4K、网络带宽够、iPhone 支持对应编码。")
                        .font(.footnote)
                    Text("本 App 不提供片源，只播你自己的 Emby 服、IPTV 列表和直链。")
                        .font(.footnote)
                }
                if !store.errorMessage.isEmpty {
                    Section { Text(store.errorMessage).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("设置")
            .onAppear {
                server = store.server
                user = store.username
                iptv = store.iptvURL
                danmu = store.danmuServer
                aiBase = store.aiBaseURL
                aiKey = store.aiKey
                aiModel = store.aiModel
            }
        }
    }
}

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    var iptvHits: [IPTVChannel] {
        query.isEmpty ? [] : store.channels.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section("Emby") {
                    if store.embyItems.isEmpty {
                        Text("没结果，先登录 Emby 或换个词。").foregroundStyle(.secondary)
                    }
                    ForEach(store.embyItems) { item in
                        Button(item.displayName) {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { store.playEmby(item) }
                        }
                    }
                }
                Section("IPTV") {
                    ForEach(iptvHits) { ch in
                        Button(ch.name) {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { store.play(url: ch.url, title: ch.name, source: "IPTV") }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "搜片名、台名")
            .onChange(of: query) { q in
                Task { await store.searchEmby(q) }
            }
            .navigationTitle("搜索")
            .toolbar { Button("关闭") { dismiss() } }
        }
    }
}

// MARK: - Player (danmaku + subtitle / audio tracks)

struct PlayerView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var showTracks = false
    @State private var trackKind: TrackKind = .subtitle
    @State private var showSubtitlePicker = false

    enum TrackKind { case subtitle, audio }

    var body: some View {
        ZStack {
            if let p = store.player {
                VideoPlayer(player: p)
                    .ignoresSafeArea()
                    .onAppear { p.play() }
                if store.danmakuOn && !store.danmaku.isEmpty {
                    DanmakuLayer(player: p, items: store.danmaku)
                        .allowsHitTesting(false)
                }
                if !store.subtitles.isEmpty {
                    SubtitleLayer(player: p, cues: store.subtitles, size: store.subtitleSize)
                        .allowsHitTesting(false)
                }
            } else {
                Text("播放器没拿到地址").padding()
            }
            VStack {
                HStack {
                    if let t = store.playing?.title {
                        Text(t).font(.headline).foregroundStyle(.white)
                            .shadow(radius: 4).lineLimit(1)
                    }
                    Spacer()
                    Button {
                        store.stopPlaying()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white).shadow(radius: 4)
                    }
                }
                .padding()
                Spacer()
                HStack(spacing: 12) {
                    Button(store.danmakuOn ? "弹幕：开" : "弹幕：关") {
                        store.danmakuOn.toggle()
                    }
                    Button("字幕") { trackKind = .subtitle; showTracks = true }
                    Button("导入字幕") { showSubtitlePicker = true }
                    Button("音轨") { trackKind = .audio; showTracks = true }
                    if store.danmuServer.isEmpty {
                        Text("弹幕需在设置里填弹幕服务器地址").font(.footnote).foregroundStyle(.white)
                    } else if store.danmaku.isEmpty {
                        Text("这部没拉到弹幕").font(.footnote).foregroundStyle(.white)
                    }
                    Spacer()
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .padding()
            }
        }
        .sheet(isPresented: $showTracks) {
            TrackSheet(kind: trackKind, player: store.player)
        }
        .sheet(isPresented: $showSubtitlePicker) {
            DocumentPicker(types: [.plainText]) { url in
                if let data = try? Data(contentsOf: url),
                   let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                    store.subtitles = store.parseSRT(text)
                    if store.subtitles.isEmpty { store.errorMessage = "这个字幕文件没解析出内容，确认是不是 SRT 格式" }
                }
            }
        }
        .onDisappear {
            if store.playing != nil { store.stopPlaying() }
        }
    }
}

struct DanmakuLayer: View {
    var player: AVPlayer
    var items: [DanmakuItem]
    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { _ in
                let now = player.currentTime().seconds
                ZStack(alignment: .topLeading) {
                    ForEach(items.filter { $0.time <= now && now - $0.time < 8 }) { d in
                        let progress = (now - d.time) / 8.0
                        let lane = abs(d.id.hashValue) % 5
                        Text(d.text)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black, radius: 2, x: 1, y: 1)
                            .offset(x: geo.size.width * (1 - progress) - 60, y: CGFloat(60 + lane * 30))
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct SubtitleLayer: View {
    var player: AVPlayer
    var cues: [SubtitleCue]
    var size: Double
    var body: some View {
        TimelineView(.animation) { _ in
            let now = player.currentTime().seconds
            VStack {
                Spacer()
                if let cue = cues.first(where: { now >= $0.start && now <= $0.end }) {
                    Text(cue.text)
                        .font(.system(size: size, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2, x: 1, y: 1)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 90)
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct TrackSheet: View {
    var kind: PlayerView.TrackKind
    var player: AVPlayer?
    @Environment(\.dismiss) var dismiss

    private var group: AVMediaSelectionGroup? {
        guard let item = player?.currentItem else { return nil }
        let ch: AVMediaCharacteristic = (kind == .subtitle) ? .legible : .audible
        return item.asset.mediaSelectionGroup(forMediaCharacteristic: ch)
    }
    private var options: [AVMediaSelectionOption] {
        group?.options ?? []
    }
    private var selected: AVMediaSelectionOption? {
        guard let item = player?.currentItem, let g = group else { return nil }
        return item.selectedMediaOption(in: g)
    }

    var body: some View {
        NavigationStack {
            List {
                if options.isEmpty {
                    Text("这部片在播放器里没读到可选轨道：字幕/音轨要片源本身带内嵌或外挂轨道，HLS 直播流也可能只有一条音轨。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button("关闭") {
                        if let g = group { player?.currentItem?.select(nil, in: g) }
                        dismiss()
                    }
                    ForEach(options, id: \.displayName) { opt in
                        Button {
                            if let g = group { player?.currentItem?.select(opt, in: g) }
                            dismiss()
                        } label: {
                            HStack {
                                Text(opt.displayName)
                                Spacer()
                                if selected?.displayName == opt.displayName {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(kind == .subtitle ? "字幕" : "音轨")
            .toolbar { Button("关闭") { dismiss() } }
        }
    }
}

// MARK: - Document picker (local file video)

struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.movie, .video]
    var onPick: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { onPick(u) }
        }
    }
}
