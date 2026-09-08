import CoreMediaIO
import Foundation

// MARK: - Configuration

let env = ProcessInfo.processInfo.environment

let feedName = env["ONAIR_FEED"] ?? "onair"
let excludedDevices = Set(
    (env["ONAIR_EXCLUDE"] ?? "OBS Virtual Camera")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty })

let pollInterval: TimeInterval = 1.0
// Adafruit IO's free tier allows 30 data points a minute; this uses two.
let heartbeatInterval: TimeInterval = 30.0
let calendarRefreshInterval: TimeInterval = 60.0

let timestamp = ISO8601DateFormatter()

func log(_ message: String) {
    print("\(timestamp.string(from: Date())) \(message)")
    fflush(stdout)
}

// MARK: - Camera

let systemObject = CMIOObjectID(kCMIOObjectSystemObject)

func address(_ selector: Int) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(selector),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
}

func cameraDevices() -> [CMIOObjectID] {
    var addr = address(kCMIOHardwarePropertyDevices)
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == 0, size > 0 else {
        return []
    }
    var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(systemObject, &addr, 0, nil, size, &used, &ids) == 0 else {
        return []
    }
    return ids
}

func deviceName(_ device: CMIOObjectID) -> String {
    var addr = address(kCMIOObjectPropertyName)
    var used: UInt32 = 0
    var value: Unmanaged<CFString>?
    let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, &value) == 0,
          let name = value?.takeRetainedValue() else { return "" }
    return name as String
}

func isStreaming(_ device: CMIOObjectID) -> Bool {
    var addr = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
    var value: UInt32 = 0
    var used: UInt32 = 0
    let size = UInt32(MemoryLayout<UInt32>.size)
    guard CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, &value) == 0 else {
        return false
    }
    return value != 0
}

/// Names of every camera currently streaming, minus the excluded ones.
func liveCameras() -> [String] {
    cameraDevices()
        .map { (name: deviceName($0), live: isStreaming($0)) }
        .filter { $0.live && !excludedDevices.contains($0.name) }
        .map(\.name)
        .sorted()
}

// MARK: - Calendar

var calendar: GoogleCalendar?
var calendarWarned = false

func refreshMeeting() -> Meeting? {
    if calendar == nil {
        do {
            calendar = try GoogleCalendar()
            log("calendars: \(calendar!.emails.joined(separator: ", "))")
        } catch {
            if !calendarWarned {
                log("calendar disabled: \(error.localizedDescription)")
                calendarWarned = true
            }
            return nil
        }
    }
    return calendar?.nextMeeting()
}

func prompt(_ label: String) -> String {
    print(label, terminator: "")
    return readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
}

/// Authorizes one Google account and adds it to the stored set.
/// Run it once per account; re-running an existing address replaces its token.
func runAuthorization(hint: String?) -> Never {
    var stored = CredentialStore.load()
        ?? Credentials(clientID: "", clientSecret: "", accounts: [],
                       aioUsername: nil, aioKey: nil)

    var client = OAuthClient(id: stored.clientID, secret: stored.clientSecret)
    var perAccount = false

    if client.id.isEmpty {
        print("No OAuth client stored yet. Create a Desktop app client in Google")
        print("Cloud Console — the README has the steps.\n")
        client = OAuthClient(id: prompt("Client ID: "), secret: prompt("Client secret: "))
        guard !client.id.isEmpty, !client.secret.isEmpty else {
            print("Both values are required.")
            exit(1)
        }
        stored.clientID = client.id
        stored.clientSecret = client.secret
    } else {
        print("Stored OAuth client: \(client.id)")
        if prompt("Use it for this account? [Y/n] ").lowercased().hasPrefix("n") {
            client = OAuthClient(id: prompt("Client ID: "), secret: prompt("Client secret: "))
            guard !client.id.isEmpty, !client.secret.isEmpty else {
                print("Both values are required.")
                exit(1)
            }
            perAccount = true
        }
    }

    do {
        let result = try client.authorize(loginHint: hint)
        var accounts = stored.accounts ?? []
        accounts.removeAll { $0.email.lowercased() == result.email.lowercased() }
        accounts.append(Account(
            email: result.email,
            refreshToken: result.refreshToken,
            clientID: perAccount ? client.id : nil,
            clientSecret: perAccount ? client.secret : nil))
        stored.accounts = accounts
        try CredentialStore.save(stored)

        print("\nAuthorized \(result.email)")
        print("Accounts now configured: \(accounts.map(\.email).joined(separator: ", "))")

        if let calendar = try? GoogleCalendar(), let meeting = calendar.nextMeeting() {
            print("Next meeting today: \(meeting.time)  (\(meeting.account))")
        } else {
            print("No upcoming meeting with a Meet link today.")
        }
        exit(0)
    } catch {
        print("\nAuthorization failed: \(error.localizedDescription)")
        exit(1)
    }
}

/// Prints what is configured, without touching the network.
func listAccounts() -> Never {
    let stored = CredentialStore.load()
    let accounts = stored?.accounts ?? []
    if accounts.isEmpty {
        print("No Google accounts authorized. Run: onair --auth <email>")
    } else {
        for account in accounts {
            let own = account.clientID == nil ? "" : "  (own OAuth client)"
            print("  \(account.email)\(own)")
        }
    }
    print(stored?.aioKey == nil ? "\nAdafruit IO: not configured" : "\nAdafruit IO: \(stored?.aioUsername ?? "?")")
    exit(0)
}

// MARK: - Reporting

let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 3
    config.waitsForConnectivity = false
    return URLSession(configuration: config)
}()

func report(live: Bool, cameras: [String], meeting: Meeting?) {
    guard let stored = CredentialStore.load(),
          let user = stored.aioUsername, let key = stored.aioKey else {
        if !aioWarned {
            log("Adafruit IO not configured — run: onair --aio <username> <key>")
            aioWarned = true
        }
        return
    }

    var state: [String: Any] = ["live": live, "cameras": cameras]
    if let meeting {
        // Only the time is published; the title never leaves this machine.
        state["next"] = ["time": meeting.time]
    }
    guard let stateData = try? JSONSerialization.data(withJSONObject: state),
          let url = URL(string:
            "https://io.adafruit.com/api/v2/\(user)/feeds/\(feedName)/data") else { return }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(key, forHTTPHeaderField: "X-AIO-Key")
    request.httpBody = try? JSONSerialization.data(
        withJSONObject: ["value": String(decoding: stateData, as: UTF8.self)])

    let done = DispatchSemaphore(value: 0)
    session.dataTask(with: request) { data, response, error in
        if let error {
            log("publish failed: \(error.localizedDescription)")
        } else if let http = response as? HTTPURLResponse,
                  !(200..<300).contains(http.statusCode) {
            let body = String(decoding: data ?? Data(), as: UTF8.self)
            log("Adafruit IO returned HTTP \(http.statusCode): \(body.prefix(160))")
        }
        done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 10)
}

var aioWarned = false

/// Stores the Adafruit IO username and key alongside the Google credentials.
func saveAdafruitCredentials(_ arguments: [String]) -> Never {
    guard arguments.count >= 2 else {
        print("usage: onair --aio <username> <key>")
        exit(1)
    }
    var stored = CredentialStore.load()
        ?? Credentials(clientID: "", clientSecret: "", accounts: [],
                       aioUsername: nil, aioKey: nil)
    stored.aioUsername = arguments[0]
    stored.aioKey = arguments[1]
    do {
        try CredentialStore.save(stored)
        print("Saved Adafruit IO credentials to \(CredentialStore.file.path)")
        exit(0)
    } catch {
        print("Could not save: \(error.localizedDescription)")
        exit(1)
    }
}

// MARK: - Main loop

if let index = CommandLine.arguments.firstIndex(of: "--auth") {
    let hint = CommandLine.arguments.dropFirst(index + 1).first
    runAuthorization(hint: hint)
}
if CommandLine.arguments.contains("--accounts") { listAccounts() }
if let index = CommandLine.arguments.firstIndex(of: "--aio") {
    saveAdafruitCredentials(Array(CommandLine.arguments.dropFirst(index + 1)))
}

log("onair started → Adafruit IO feed '\(feedName)'")
if !excludedDevices.isEmpty {
    log("ignoring: \(excludedDevices.sorted().joined(separator: ", "))")
}

var lastLive: Bool?
var lastReported = Date.distantPast
var meeting: Meeting?
var meetingCheckedAt = Date.distantPast

while true {
    if Date().timeIntervalSince(meetingCheckedAt) >= calendarRefreshInterval {
        let found = refreshMeeting()
        if found?.title != meeting?.title || found?.time != meeting?.time {
            log(found.map { "next: \($0.time) \($0.title) [\($0.account)]" } ?? "next: none today")
        }
        meeting = found
        meetingCheckedAt = Date()
    }

    let cameras = liveCameras()
    let live = !cameras.isEmpty
    let changed = live != lastLive

    if changed || Date().timeIntervalSince(lastReported) >= heartbeatInterval {
        if changed {
            log(live ? "ON  \(cameras.joined(separator: ", "))" : "OFF")
        }
        report(live: live, cameras: cameras, meeting: meeting)
        lastLive = live
        lastReported = Date()
    }

    Thread.sleep(forTimeInterval: pollInterval)
}
