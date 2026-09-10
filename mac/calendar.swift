import CryptoKit
import Foundation
import Network
import Security

// Google Calendar over OAuth 2.0, for accounts that are not in macOS Calendar.
//
// A plain API key cannot read a private calendar -- keys only authorize public
// data -- so this uses the installed-app flow: one browser consent per
// account, then refresh tokens that keep working indefinitely.
//
// Several accounts are supported. Each keeps its own refresh token, and may
// carry its own OAuth client for domains that will not authorize a shared one.

/// The next video call that has not started yet.
struct Meeting {
    let time: String
    let title: String
    let account: String
}

/// A video call that is happening right now.
struct ActiveMeeting {
    let until: String
    let title: String
    let account: String
}

struct Schedule {
    var active: ActiveMeeting?
    var next: Meeting?
}

// MARK: - Stored credentials

struct Account: Codable {
    var email: String
    var refreshToken: String
    /// Set only when this account needs a client of its own.
    var clientID: String?
    var clientSecret: String?
}

struct Credentials: Codable {
    /// The client used unless an account overrides it.
    var clientID: String
    var clientSecret: String
    var accounts: [Account]?
    var aioUsername: String?
    var aioKey: String?

    func client(for account: Account) -> (id: String, secret: String) {
        (account.clientID ?? clientID, account.clientSecret ?? clientSecret)
    }
}

enum CredentialStore {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/onair", isDirectory: true)
    static let file = directory.appendingPathComponent("credentials.json")

    static func load() -> Credentials? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func save(_ credentials: Credentials) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(credentials)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path
        )
    }
}

// MARK: - Loopback redirect catcher

/// Listens on a random localhost port for Google's OAuth redirect.
final class RedirectCatcher {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let ready = DispatchSemaphore(value: 0)
    private let captured = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<String, Error>?

    private(set) var port: UInt16 = 0

    enum Failure: LocalizedError {
        case listenerFailed(String)
        case denied(String)
        case noCode

        var errorDescription: String? {
            switch self {
            case let .listenerFailed(why): return "could not open loopback listener: \(why)"
            case let .denied(why): return "Google returned an error: \(why)"
            case .noCode: return "redirect carried no authorization code"
            }
        }
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = self.listener?.port?.rawValue ?? 0
                self.ready.signal()
            case let .failed(error):
                self.finish(.failure(Failure.listenerFailed(error.localizedDescription)))
                self.ready.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 10)
        guard port != 0 else { throw Failure.listenerFailed("no port assigned") }
    }

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, _, _ in
            guard let self else { return }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let outcome = Self.parse(request)

            let page: String
            switch outcome {
            case .success:
                page = "<h2>Authorized.</h2><p>You can close this tab and return to Terminal.</p>"
            case let .failure(error):
                page = "<h2>Authorization failed.</h2><p>\(error.localizedDescription)</p>"
            }
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(page.utf8.count)\r
            Connection: close\r
            \r
            \(page)
            """
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            self.finish(outcome)
        }
    }

    /// Pulls `code` (or `error`) out of the request line's query string.
    private static func parse(_ request: String) -> Result<String, Error> {
        guard let line = request.split(separator: "\r\n").first,
              let target = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(target)"),
              let items = components.queryItems
        else {
            return .failure(Failure.noCode)
        }
        if let denial = items.first(where: { $0.name == "error" })?.value {
            return .failure(Failure.denied(denial))
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            return .failure(Failure.noCode)
        }
        return .success(code)
    }

    private func finish(_ outcome: Result<String, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        result = outcome
        captured.signal()
    }

    /// Blocks until the browser comes back, or the timeout expires.
    func waitForCode(timeout: TimeInterval = 300) throws -> String {
        defer {
            listener?.cancel()
            connections.forEach { $0.cancel() }
        }
        guard captured.wait(timeout: .now() + timeout) == .success else {
            throw Failure.noCode
        }
        lock.lock()
        let outcome = result
        lock.unlock()
        return try outcome!.get()
    }
}

// MARK: - One authorized Google account

final class GoogleAccount {
    let email: String
    private let clientID: String
    private let clientSecret: String
    private let refreshToken: String
    private var accessToken: String?
    private var accessExpiry = Date.distantPast

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    private let rfc3339: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init(email: String, clientID: String, clientSecret: String, refreshToken: String) {
        self.email = email
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.refreshToken = refreshToken
    }

    // MARK: Requests

    func send(_ request: URLRequest) throws -> Data {
        let waiter = DispatchSemaphore(value: 0)
        var payload = Data()
        var status = 0
        var failure: Error?

        session.dataTask(with: request) { data, response, error in
            payload = data ?? Data()
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            failure = error
            waiter.signal()
        }.resume()
        _ = waiter.wait(timeout: .now() + 20)

        if let failure { throw failure }
        guard (200..<300).contains(status) else {
            throw GoogleCalendar.Failure.http(status, String(decoding: payload, as: UTF8.self))
        }
        return payload
    }

    private func authorized(_ url: URL) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try validAccessToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validAccessToken() throws -> String {
        if let accessToken, Date() < accessExpiry { return accessToken }
        let tokens = try OAuthClient(id: clientID, secret: clientSecret)
            .exchange(["refresh_token": refreshToken, "grant_type": "refresh_token"])
        guard let token = tokens["access_token"] as? String else {
            throw GoogleCalendar.Failure.notAuthorized(email)
        }
        accessToken = token
        accessExpiry = Date().addingTimeInterval((tokens["expires_in"] as? Double ?? 3600) - 60)
        return token
    }

    // MARK: Events

    private struct EventList: Decodable {
        struct Event: Decodable {
            struct When: Decodable {
                let dateTime: String?
                let date: String?
            }
            struct Attendee: Decodable {
                let isSelf: Bool?
                let responseStatus: String?
                enum CodingKeys: String, CodingKey {
                    case isSelf = "self"
                    case responseStatus
                }
            }
            struct ConferenceData: Decodable {
                struct EntryPoint: Decodable {
                    let entryPointType: String?
                }
                let entryPoints: [EntryPoint]?
            }
            let summary: String?
            let status: String?
            let start: When?
            let end: When?
            let conferenceData: ConferenceData?
            let hangoutLink: String?
            let location: String?
            let description: String?
            let attendees: [Attendee]?
        }
        let items: [Event]?
    }

    private func declined(_ event: EventList.Event) -> Bool {
        event.attendees?.contains { $0.isSelf == true && $0.responseStatus == "declined" } ?? false
    }

    /// Join-link shapes only. Bare "zoom.us" would also match documentation
    /// and add-on marketplace URLs that turn up in invite bodies.
    private static let joinLinks = [
        "meet.google.com/",
        "zoom.us/j/", "zoom.us/my/",
        "teams.microsoft.com/l/meetup-join",
        "webex.com/meet", "webex.com/j.php",
    ]

    /// Whether the event has a video call attached, whoever hosts it.
    private func hasVideoLink(_ event: EventList.Event) -> Bool {
        // Structured and provider-agnostic: Google populates this for Meet and
        // for Zoom, Teams and Webex added through a calendar add-on.
        if event.conferenceData?.entryPoints?
            .contains(where: { $0.entryPointType == "video" }) == true { return true }
        if event.hangoutLink?.isEmpty == false { return true }

        // Fallback for invites that only paste a URL into the location or body.
        let haystack = [event.location, event.description]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        return Self.joinLinks.contains { haystack.contains($0) }
    }

    /// This account's in-progress video call and its next upcoming one.
    ///
    /// Google's `timeMin` filters on an event's *end*, so a meeting already
    /// under way comes back from the same query as the upcoming ones.
    func meetings() throws -> (active: (end: Date, title: String)?,
                               next: (start: Date, title: String)?) {
        let now = Date()
        guard let endOfDay = Calendar.current.date(
            bySettingHour: 23, minute: 59, second: 59, of: now) else { return (nil, nil) }

        var components = URLComponents(
            string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: rfc3339.string(from: now)),
            URLQueryItem(name: "timeMax", value: rfc3339.string(from: endOfDay)),
            // Expands recurring events into real occurrences.
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "30"),
        ]

        let list = try JSONDecoder().decode(
            EventList.self, from: send(try authorized(components.url!)))

        var active: (end: Date, title: String)?
        var next: (start: Date, title: String)?

        for event in list.items ?? [] {
            guard event.status != "cancelled",
                  let startStamp = event.start?.dateTime,   // nil for all-day events
                  let start = rfc3339.date(from: startStamp),
                  !declined(event),
                  hasVideoLink(event) else { continue }
            let title = event.summary ?? "Meeting"

            if start > now {
                if next == nil { next = (start, title) }
                continue
            }
            // Started already: still active only while its end is ahead of us.
            guard let endStamp = event.end?.dateTime,
                  let end = rfc3339.date(from: endStamp), end > now else { continue }
            if active == nil || end < active!.end { active = (end, title) }
        }
        return (active, next)
    }
}

// MARK: - OAuth

struct OAuthClient {
    let id: String
    let secret: String

    static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    static let scope = "https://www.googleapis.com/auth/calendar.readonly"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// POSTs a form to the token endpoint and returns the decoded JSON.
    func exchange(_ fields: [String: String]) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var form = fields
        form["client_id"] = id
        form["client_secret"] = secret
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let waiter = DispatchSemaphore(value: 0)
        var payload = Data()
        var status = 0
        var failure: Error?
        Self.session.dataTask(with: request) { data, response, error in
            payload = data ?? Data()
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            failure = error
            waiter.signal()
        }.resume()
        _ = waiter.wait(timeout: .now() + 20)

        if let failure { throw failure }
        guard (200..<300).contains(status) else {
            throw GoogleCalendar.Failure.http(status, String(decoding: payload, as: UTF8.self))
        }
        return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Runs the browser consent and returns a refresh token plus the account it belongs to.
    func authorize(loginHint: String?) throws -> (email: String, refreshToken: String) {
        let catcher = RedirectCatcher()
        try catcher.start()
        let redirect = "http://127.0.0.1:\(catcher.port)"

        var verifierBytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, verifierBytes.count, &verifierBytes)
        let verifier = Self.base64URL(Data(verifierBytes))
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        var components = URLComponents(string: Self.authEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let loginHint {
            components.queryItems?.append(URLQueryItem(name: "login_hint", value: loginHint))
        }

        print("\nOpening your browser. If it does not open, visit:\n")
        print(components.url!.absoluteString, "\n")
        Process.launchedProcess(launchPath: "/usr/bin/open",
                                arguments: [components.url!.absoluteString])

        let code = try catcher.waitForCode()
        let tokens = try exchange([
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirect,
        ])

        guard let refresh = tokens["refresh_token"] as? String else {
            throw GoogleCalendar.Failure.http(0, "no refresh_token returned — revoke the app at "
                + "myaccount.google.com/permissions and try again")
        }
        guard let access = tokens["access_token"] as? String else {
            throw GoogleCalendar.Failure.http(0, "no access_token returned")
        }
        return (try Self.primaryEmail(accessToken: access), refresh)
    }

    /// The calendar id of `primary` is the account's own address.
    private static func primaryEmail(accessToken: String) throws -> String {
        var request = URLRequest(
            url: URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let waiter = DispatchSemaphore(value: 0)
        var payload = Data()
        session.dataTask(with: request) { data, _, _ in
            payload = data ?? Data()
            waiter.signal()
        }.resume()
        _ = waiter.wait(timeout: .now() + 20)

        let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        guard let email = json?["id"] as? String else {
            throw GoogleCalendar.Failure.http(0, "could not read the account address")
        }
        return email
    }
}

// MARK: - All accounts together

final class GoogleCalendar {
    private let accounts: [GoogleAccount]

    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()

    /// No day period -- "until 2:30" has to fit 64px of panel.
    private let shortClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("hmm")
        return formatter
    }()

    enum Failure: LocalizedError {
        case notConfigured
        case noAccounts
        case notAuthorized(String)
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "no credentials at \(CredentialStore.file.path) — run: onair --auth"
            case .noAccounts:
                return "no Google accounts authorized yet — run: onair --auth <email>"
            case let .notAuthorized(email):
                return "\(email) needs re-authorizing — run: onair --auth \(email)"
            case let .http(code, body):
                return "Google returned HTTP \(code): \(body.prefix(200))"
            }
        }
    }

    init() throws {
        guard let stored = CredentialStore.load() else { throw Failure.notConfigured }
        let configured = stored.accounts ?? []
        guard !configured.isEmpty else { throw Failure.noAccounts }
        accounts = configured.map { account in
            let client = stored.client(for: account)
            return GoogleAccount(email: account.email,
                                 clientID: client.id,
                                 clientSecret: client.secret,
                                 refreshToken: account.refreshToken)
        }
    }

    var emails: [String] { accounts.map(\.email) }

    /// Across every authorized account: the meeting happening now, and the
    /// next one to start. One account failing does not hide the others.
    func schedule() -> Schedule {
        var soonestEnd: (end: Date, title: String, email: String)?
        var soonestStart: (start: Date, title: String, email: String)?

        for account in accounts {
            do {
                let found = try account.meetings()
                if let a = found.active, soonestEnd == nil || a.end < soonestEnd!.end {
                    soonestEnd = (a.end, a.title, account.email)
                }
                if let n = found.next, soonestStart == nil || n.start < soonestStart!.start {
                    soonestStart = (n.start, n.title, account.email)
                }
            } catch {
                log("calendar \(account.email): \(error.localizedDescription)")
            }
        }

        return Schedule(
            active: soonestEnd.map {
                ActiveMeeting(until: shortClock.string(from: $0.end),
                              title: $0.title, account: $0.email)
            },
            next: soonestStart.map {
                Meeting(time: clock.string(from: $0.start),
                        title: $0.title, account: $0.email)
            })
    }
}
