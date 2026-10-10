import Foundation
import OSLog

let sonosLog = Logger(subsystem: "com.robin.notch", category: "sonos")

/// A visible Sonos room: one speaker, or the primary of a stereo pair / home-theatre set.
struct SonosRoom: Identifiable, Equatable {
    var id: String { uuid }
    var uuid: String
    var ip: String
    var name: String
}

/// One Sonos group: the rooms playing in sync. Only the coordinator carries transport state;
/// the others report `x-rincon:<coordinator>` and no metadata, so it is the one to poll and command.
struct SonosGroup: Identifiable, Equatable {
    var id: String { coordinatorUUID }
    var coordinatorUUID: String
    var coordinatorIP: String
    var name: String
    var members: [SonosRoom]

    var label: String { members.count > 1 ? "\(name) + \(members.count - 1)" : name }
}

/// Reads and controls Sonos speakers over their local UPnP API, so music started from the Sonos
/// app shows up. Spotify's own API never sees those sessions: the speaker streams the service
/// directly. One SSDP probe finds any speaker; its zone-group topology then lists every group.
@MainActor
final class SonosController: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { scan() }
        }
    }
    @Published private(set) var groups: [SonosGroup] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanMessage: String?

    private static let enabledKey = "sonosEnabled"
    private static let knownSpeakerKey = "sonosKnownSpeaker"

    /// Any reachable speaker's IP, good for fetching topology without another SSDP round.
    private var knownSpeaker: String? {
        didSet { UserDefaults.standard.set(knownSpeaker, forKey: Self.knownSpeakerKey) }
    }
    private var topologyRefreshedAt = Date.distantPast
    private var scanTask: Task<Void, Never>?
    /// The group currently shown in the notch; transport commands and grouping changes go here.
    @Published private(set) var activeGroup: SonosGroup?

    /// Every visible room on the network, for the speakers menu.
    var rooms: [SonosRoom] {
        groups.flatMap(\.members).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Rooms in the shown group as the latest topology has them (`activeGroup` itself is a
    /// snapshot from the last poll and lags a just-made grouping change).
    var activeMembers: [SonosRoom] {
        groups.first { $0.id == activeGroup?.id }?.members ?? activeGroup?.members ?? []
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config)
    }()

    init() {
        // Off until switched on in Settings: the first scan triggers macOS's Local Network prompt,
        // which users without Sonos shouldn't see.
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        knownSpeaker = UserDefaults.standard.string(forKey: Self.knownSpeakerKey)
        if isEnabled { scan() }
    }

    // MARK: Discovery

    /// SSDP for one speaker, then that speaker's zone-group state for all of them. The speaker
    /// that answered last time is tried as well: SSDP needs multicast, which the local-network
    /// permission prompt blocks until it is answered and some Wi-Fi setups drop entirely.
    func scan() {
        guard scanTask == nil else { return }
        isScanning = true
        scanMessage = nil
        scanTask = Task { [weak self] in
            defer { self?.scanTask = nil }
            guard let self else { return }
            var candidates = await Task.detached(priority: .utility) { Self.ssdpDiscover() }.value
            if let knownSpeaker, !candidates.contains(knownSpeaker) { candidates.append(knownSpeaker) }
            var reached = false
            for ip in candidates {
                if await refreshTopology(from: ip) {
                    knownSpeaker = ip
                    reached = true
                    break
                }
            }
            if !reached {
                groups = []
                scanMessage = "No Sonos speakers answered. Check that this Mac is on the same network and that Notch is allowed to find local devices in System Settings › Privacy & Security › Local Network."
            } else if groups.isEmpty {
                scanMessage = "A speaker answered but reported no groups."
            }
            isScanning = false
        }
    }

    @discardableResult
    private func refreshTopology(from ip: String) async -> Bool {
        do {
            let xml = try await soap(ip: ip, service: "ZoneGroupTopology", path: "/ZoneGroupTopology/Control", action: "GetZoneGroupState")
            guard let state = Self.text("ZoneGroupState", in: xml).map(Self.unescape) else {
                throw SonosError.message("No zone group state in reply.")
            }
            let parsed = Self.parseGroups(state)
            if parsed != groups {
                groups = parsed
                sonosLog.notice("topology: \(parsed.map(\.label).joined(separator: ", "), privacy: .public)")
            }
            topologyRefreshedAt = Date()
            return true
        } catch {
            sonosLog.error("topology from \(ip, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Grouping changes whenever someone drags rooms together in the Sonos app, so the topology
    /// is re-read periodically from a known speaker. SSDP runs again only if that speaker is gone.
    private func refreshTopologyIfStale() async {
        guard Date().timeIntervalSince(topologyRefreshedAt) > 30 else { return }
        if let knownSpeaker, await refreshTopology(from: knownSpeaker) { return }
        scan()
    }

    // MARK: Reading

    /// The group that is playing, or paused if none is. Stopped groups keep a track loaded for
    /// days, which isn't "now playing". Home-theatre and Spotify Connect inputs are skipped: they
    /// carry no track metadata here (and Connect sessions are what the Spotify API already shows).
    func snapshot() async -> MediaSnapshot? {
        await refreshTopologyIfStale()
        let groups = groups
        guard !groups.isEmpty else { return nil }
        let readings: [(SonosGroup, MediaSnapshot)] = await withTaskGroup(of: (SonosGroup, MediaSnapshot?).self) { tasks in
            for group in groups {
                tasks.addTask { [self] in (group, await read(group)) }
            }
            var out: [(SonosGroup, MediaSnapshot)] = []
            for await (group, snapshot) in tasks {
                if let snapshot { out.append((group, snapshot)) }
            }
            return out
        }
        let order = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($1.id, $0) })
        let sorted = readings.sorted { order[$0.0.id, default: 0] < order[$1.0.id, default: 0] }
        guard let chosen = sorted.first(where: { $0.1.isPlaying }) ?? sorted.first else {
            activeGroup = nil
            return nil
        }
        activeGroup = chosen.0
        return chosen.1
    }

    private func read(_ group: SonosGroup) async -> MediaSnapshot? {
        do {
            let ip = group.coordinatorIP
            async let transport = soap(ip: ip, service: "AVTransport", path: "/MediaRenderer/AVTransport/Control", action: "GetTransportInfo", body: "<InstanceID>0</InstanceID>")
            async let position = soap(ip: ip, service: "AVTransport", path: "/MediaRenderer/AVTransport/Control", action: "GetPositionInfo", body: "<InstanceID>0</InstanceID>")
            let state = Self.text("CurrentTransportState", in: try await transport) ?? ""
            let isPlaying: Bool
            switch state {
            case "PLAYING", "TRANSITIONING": isPlaying = true
            case "PAUSED_PLAYBACK": isPlaying = false
            default: return nil
            }
            let positionXML = try await position
            let uri = Self.text("TrackURI", in: positionXML) ?? ""
            if uri.hasPrefix("x-sonos-htastream:") || uri.hasPrefix("x-sonos-vli:") || uri.hasPrefix("x-rincon:") {
                return nil
            }
            guard let metadata = Self.text("TrackMetaData", in: positionXML).map(Self.unescape),
                  let title = Self.text("dc:title", in: metadata).map(Self.unescape), !title.isEmpty
            else { return nil }
            // Radio streams put the live track in streamContent and the station in the title.
            let stream = Self.text("r:streamContent", in: metadata).map(Self.unescape) ?? ""
            let creator = Self.text("dc:creator", in: metadata).map(Self.unescape) ?? ""
            var art = Self.text("upnp:albumArtURI", in: metadata).map(Self.unescape) ?? ""
            if art.hasPrefix("/") { art = "http://\(ip):1400\(art)" }
            return MediaSnapshot(
                title: stream.isEmpty ? title : stream,
                artist: stream.isEmpty ? creator : title,
                isPlaying: isPlaying,
                artworkURL: art,
                position: Self.seconds(Self.text("RelTime", in: positionXML)),
                duration: Self.seconds(Self.text("TrackDuration", in: positionXML)) ?? 0,
                label: "Sonos · \(group.label)"
            )
        } catch {
            sonosLog.error("\(group.label, privacy: .public) unreachable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Grouping

    /// Adds `room` to the playing group, so it plays the same stream, or splits it back off.
    /// The coordinator can't be removed: it is the one streaming.
    func setGrouped(_ room: SonosRoom, _ grouped: Bool) {
        guard let activeGroup, room.uuid != activeGroup.coordinatorUUID else { return }
        Task {
            do {
                if grouped {
                    _ = try await soap(
                        ip: room.ip, service: "AVTransport", path: "/MediaRenderer/AVTransport/Control",
                        action: "SetAVTransportURI",
                        body: "<InstanceID>0</InstanceID><CurrentURI>x-rincon:\(activeGroup.coordinatorUUID)</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
                    )
                } else {
                    _ = try await soap(
                        ip: room.ip, service: "AVTransport", path: "/MediaRenderer/AVTransport/Control",
                        action: "BecomeCoordinatorOfStandaloneGroup", body: "<InstanceID>0</InstanceID>"
                    )
                }
                sonosLog.notice("\(room.name, privacy: .public) \(grouped ? "joined" : "left", privacy: .public) \(activeGroup.name, privacy: .public)")
            } catch {
                sonosLog.error("grouping \(room.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            // Sonos takes a beat to publish the new topology.
            try? await Task.sleep(for: .milliseconds(500))
            if let knownSpeaker { await refreshTopology(from: knownSpeaker) }
        }
    }

    // MARK: Controls

    func play() async throws { try await transport("Play", body: "<InstanceID>0</InstanceID><Speed>1</Speed>") }
    func pause() async throws { try await transport("Pause", body: "<InstanceID>0</InstanceID>") }
    func next() async throws { try await transport("Next", body: "<InstanceID>0</InstanceID>") }
    func previous() async throws { try await transport("Previous", body: "<InstanceID>0</InstanceID>") }

    func seek(to seconds: Double) async throws {
        let target = Self.clock(seconds)
        try await transport("Seek", body: "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>\(target)</Target>")
    }

    private func transport(_ action: String, body: String) async throws {
        guard let activeGroup else { throw SonosError.message("No Sonos group is active.") }
        _ = try await soap(ip: activeGroup.coordinatorIP, service: "AVTransport", path: "/MediaRenderer/AVTransport/Control", action: action, body: body)
    }

    // MARK: SOAP

    private func soap(ip: String, service: String, path: String, action: String, body: String = "") async throws -> String {
        var request = URLRequest(url: URL(string: "http://\(ip):1400\(path)")!)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:\(service):1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\
        <u:\(action) xmlns:u="urn:schemas-upnp-org:service:\(service):1">\(body)</u:\(action)>\
        </s:Body></s:Envelope>
        """.utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let xml = String(decoding: data, as: UTF8.self)
        guard status == 200 else {
            let code = Self.text("errorCode", in: xml) ?? "\(status)"
            throw SonosError.message("Sonos \(action) failed (UPnP error \(code)).")
        }
        return xml
    }

    // MARK: SSDP

    /// Multicast M-SEARCH for ZonePlayers; answers arrive as unicast on the same socket. Blocking,
    /// so it runs detached. Returns speaker IPs, deduplicated, in the order they answered.
    private nonisolated static func ssdpDiscover() -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 400_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var ttl: Int32 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<Int32>.size))

        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(1900).bigEndian
        dest.sin_addr.s_addr = inet_addr("239.255.255.250")
        let message = Array("""
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 1\r
        ST: urn:schemas-upnp-org:device:ZonePlayer:1\r
        \r

        """.utf8)
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &dest) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    sendto(fd, message, message.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var found: [String] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    recvfrom(fd, &buffer, buffer.count, 0, address, &fromLength)
                }
            }
            guard count > 0 else { continue }
            let reply = String(decoding: buffer[0..<count], as: UTF8.self)
            // Other UPnP devices answer any search; only ZonePlayers describe themselves on 1400.
            guard reply.range(of: ":1400/xml/device_description.xml") != nil else { continue }
            let ip = String(cString: inet_ntoa(from.sin_addr))
            if !found.contains(ip) { found.append(ip) }
        }
        return found
    }

    // MARK: Parsing

    private nonisolated static func parseGroups(_ state: String) -> [SonosGroup] {
        guard let groupRegex = try? NSRegularExpression(pattern: #"<ZoneGroup Coordinator="([^"]+)"[^>]*>(.*?)</ZoneGroup>"#, options: [.dotMatchesLineSeparators]),
              let memberRegex = try? NSRegularExpression(pattern: #"<ZoneGroupMember ([^>]*?)/?>"#),
              let attributeRegex = try? NSRegularExpression(pattern: #"(\w+)="([^"]*)""#)
        else { return [] }
        let whole = NSRange(state.startIndex..., in: state)
        var groups: [SonosGroup] = []
        for match in groupRegex.matches(in: state, range: whole) {
            guard let coordinatorRange = Range(match.range(at: 1), in: state),
                  let bodyRange = Range(match.range(at: 2), in: state) else { continue }
            let coordinator = String(state[coordinatorRange])
            let body = String(state[bodyRange])
            var coordinatorIP: String?
            var name = ""
            var members: [SonosRoom] = []
            for member in memberRegex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let attributesRange = Range(member.range(at: 1), in: body) else { continue }
                let attributesText = String(body[attributesRange])
                var attributes: [String: String] = [:]
                for attribute in attributeRegex.matches(in: attributesText, range: NSRange(attributesText.startIndex..., in: attributesText)) {
                    guard let keyRange = Range(attribute.range(at: 1), in: attributesText),
                          let valueRange = Range(attribute.range(at: 2), in: attributesText) else { continue }
                    attributes[String(attributesText[keyRange])] = String(attributesText[valueRange])
                }
                // Invisible members are the second half of a stereo pair or a surround satellite.
                if attributes["Invisible"] == "1" { continue }
                let roomName = unescape(attributes["ZoneName"] ?? "")
                guard let uuid = attributes["UUID"],
                      let ip = attributes["Location"].flatMap({ URL(string: $0)?.host }),
                      !roomName.isEmpty
                else { continue }
                members.append(SonosRoom(uuid: uuid, ip: ip, name: roomName))
                if uuid == coordinator {
                    name = roomName
                    coordinatorIP = ip
                }
            }
            guard let coordinatorIP, !name.isEmpty else { continue }
            members.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            groups.append(SonosGroup(coordinatorUUID: coordinator, coordinatorIP: coordinatorIP, name: name, members: members))
        }
        return groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Text between `<tag>` and `</tag>`; the tags this needs never carry attributes.
    private nonisolated static func text(_ tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    private nonisolated static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// "0:03:11" → 191. Sonos reports NOT_IMPLEMENTED for inputs it can't time.
    private nonisolated static func seconds(_ clock: String?) -> Double? {
        guard let clock else { return nil }
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    private nonisolated static func clock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

enum SonosError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
