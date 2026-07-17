import Cocoa
import ApplicationServices

// claude-session-focus — focus an existing Claude desktop session WITHOUT forking it.
//
// The Claude desktop app has no focus-existing-session deeplink (claude://resume always
// imports a snapshot fork). This tool presses the real sidebar session row via the
// Accessibility API, which drives the app's internal setFocusedSession path.
//
// Usage:
//   claude-session-focus "<title substring>"        focus best-matching session row
//   claude-session-focus "<session id>"             CLI uuid or local_<uuid>; resolved to
//                                                   the session's current title via
//                                                   ~/Library/Logs/Claude/main.log
//   claude-session-focus "ccfocus://RCA%20invest"   same, URL form (scheme+percent decoding)
//   claude-session-focus --list                     print visible session row titles
//   claude-session-focus --dry "<substring|id>"     show what would be pressed, don't press
//   claude-session-focus --attrs "<substring>"      dump AX attributes of matches (debug)
//
// Matching: exact title first, then substring; a leading "Running " status prefix on row
// titles is ignored; shallowest (sidebar) match wins over in-content duplicates. If the
// row isn't rendered (virtualized list), presses "Load more sessions" up to 3x and rescans.
//
// Id resolution: "Mapping internal session local_<L> to CLI session <U>" lines map a CLI
// uuid to the app's local id; "LocalSessions.updateSession: sessionId=local_<L>,
// options={"title":...}" lines map local ids to titles (last line wins, so renames
// resolve to the current title). Both live in main.log (+ main.log.old when rotated).
//
// Exit codes: 0 ok, 2 no match, 4 accessibility not granted, 5 app not running,
// 6 session id not resolvable from the app logs.

let claudeBundleId = "com.anthropic.claudefordesktop"
let loadMoreRounds = 3

func fail(_ code: Int32, _ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

// ---- argument parsing ----
var args = Array(CommandLine.arguments.dropFirst())
var listOnly = false
var dryRun = false
var attrsDump = false
if let i = args.firstIndex(of: "--list") { listOnly = true; args.remove(at: i) }
if let i = args.firstIndex(of: "--dry") { dryRun = true; args.remove(at: i) }
if let i = args.firstIndex(of: "--attrs") { attrsDump = true; args.remove(at: i) }

var query = args.first ?? ""
if query.lowercased().hasPrefix("ccfocus://") {
    query = String(query.dropFirst("ccfocus://".count))
    if query.hasSuffix("/") { query = String(query.dropLast()) }
}
query = query.removingPercentEncoding ?? query
query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
if query.isEmpty && !listOnly { fail(2, "usage: claude-session-focus [--list|--dry|--attrs] \"<title substring | session id>\"") }

// ---- session-id resolution (CLI uuid or local_<uuid> -> current title) ----
func looksLikeSessionId(_ s: String) -> Bool {
    let core = s.hasPrefix("local_") ? String(s.dropFirst("local_".count)) : s
    return core.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                      options: .regularExpression) != nil
}

func resolveTitle(forSessionId raw: String) -> String? {
    let id = raw.hasPrefix("local_") ? String(raw.dropFirst("local_".count)) : raw
    let logsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Claude")
    // oldest first so newer files overwrite stale titles/mappings
    let files = ["main.log.old", "main.log"]
        .map { logsDir.appendingPathComponent($0).path }
        .filter { FileManager.default.fileExists(atPath: $0) }
    var cliToLocal: [String: String] = [:]
    var titles: [String: String] = [:]
    for f in files {
        guard let data = FileManager.default.contents(atPath: f),
              let text = String(data: data, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n") {
            if let r = line.range(of: "Mapping internal session local_") {
                let parts = line[r.upperBound...].split(separator: " ")
                if parts.count >= 5, parts[1] == "to", parts[2] == "CLI", parts[3] == "session" {
                    cliToLocal[String(parts[4]).lowercased()] = String(parts[0]).lowercased()
                }
            } else if let r = line.range(of: "LocalSessions.updateSession: sessionId=local_") {
                let rest = line[r.upperBound...]
                guard let comma = rest.firstIndex(of: ",") else { continue }
                let localId = String(rest[..<comma]).lowercased()
                guard let o = rest.range(of: "options=") else { continue }
                let json = String(rest[o.upperBound...])
                if let d = json.data(using: .utf8),
                   let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                   let t = obj["title"] as? String, !t.isEmpty {
                    titles[localId] = t
                } else if let m = json.range(of: "\"title\":\"([^\"]*)\"", options: .regularExpression) {
                    let frag = String(json[m])
                    let t = String(frag.dropFirst("\"title\":\"".count).dropLast())
                    if !t.isEmpty { titles[localId] = t }
                }
            }
        }
    }
    return titles[cliToLocal[id] ?? id]
}

var resolvedNote: String? = nil
if !listOnly && !query.isEmpty && looksLikeSessionId(query) {
    guard let t = resolveTitle(forSessionId: query) else {
        fail(6, "Could not resolve session id \"\(query)\" to a title via ~/Library/Logs/Claude/main.log (rotated out, or the session was never titled there). Pass a title substring instead.")
    }
    resolvedNote = "resolved: \(query) -> \"\(t)\""
    query = t.lowercased()
}

// ---- permissions & target app ----
let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
    fail(4, "Accessibility not granted for this tool's parent app. Approve it in System Settings > Privacy & Security > Accessibility, then retry.")
}
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == claudeBundleId }) else {
    fail(5, "Claude desktop app is not running.")
}
let appEl = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
usleep(400_000)

// ---- AX helpers ----
func axVal(_ el: AXUIElement, _ attr: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
}
func axStr(_ el: AXUIElement, _ attr: String) -> String { (axVal(el, attr) as? String) ?? "" }
func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    (axVal(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}
func axActions(_ el: AXUIElement) -> [String] {
    var acts: CFArray?
    if AXUIElementCopyActionNames(el, &acts) == .success, let a = acts as? [String] { return a }
    return []
}

struct Row { let el: AXUIElement; let title: String; let depth: Int }

func normalized(_ title: String) -> String {
    var t = title.lowercased()
    if t.hasPrefix("running ") { t = String(t.dropFirst("running ".count)) }
    return t
}

// BFS the app tree, collecting pressable buttons with titles (session rows and friends)
// plus any "Load more sessions" button.
func scan() -> (rows: [Row], loadMore: AXUIElement?) {
    var rows: [Row] = []
    var loadMore: AXUIElement?
    var queue: [(AXUIElement, Int)] = [(appEl, 0)]
    var walked = 0
    while !queue.isEmpty && walked < 60_000 {
        let (el, d) = queue.removeFirst()
        walked += 1
        let role = axStr(el, kAXRoleAttribute as String)
        if role == "AXButton" {
            let title = axStr(el, kAXTitleAttribute as String)
            let desc = axStr(el, kAXDescriptionAttribute as String)
            if !title.isEmpty && axActions(el).contains("AXPress") {
                rows.append(Row(el: el, title: title, depth: d))
            }
            if desc == "Load more sessions" { loadMore = el }
        }
        for c in axChildren(el) { queue.append((c, d + 1)) }
    }
    return (rows, loadMore)
}

func bestMatch(_ rows: [Row]) -> Row? {
    // BFS order = shallowest first, so .first prefers sidebar rows over in-content buttons
    if let exact = rows.first(where: { normalized($0.title) == query }) { return exact }
    return rows.first(where: { normalized($0.title).contains(query) })
}

// ---- main ----
var (rows, loadMore) = scan()

if listOnly {
    for r in rows where r.depth <= 24 { print(r.title) }
    exit(0)
}

if attrsDump {
    for m in rows.filter({ normalized($0.title).contains(query) }) {
        print("== \(m.title) (depth \(m.depth))")
        var names: CFArray?
        if AXUIElementCopyAttributeNames(m.el, &names) == .success, let ns = names as? [String] {
            for n in ns {
                let v = axVal(m.el, n)
                let s = (v as? String) ?? v.map { String(describing: $0) } ?? "nil"
                print("  \(n) = \(s.prefix(120))")
            }
        }
    }
    exit(0)
}

var match = bestMatch(rows)
var round = 0
while match == nil, let lm = loadMore, round < loadMoreRounds {
    _ = AXUIElementPerformAction(lm, "AXPress" as CFString)
    usleep(700_000)
    (rows, loadMore) = scan()
    match = bestMatch(rows)
    round += 1
}

guard let target = match else {
    fail(2, "No session row matching \"\(query)\" (after \(round) load-more rounds). Try --list to see visible titles.")
}

if let n = resolvedNote { print(n) }
print("target: \"\(target.title)\" (depth \(target.depth))")
if dryRun { exit(0) }

if axActions(target.el).contains("AXScrollToVisible") {
    _ = AXUIElementPerformAction(target.el, "AXScrollToVisible" as CFString)
    usleep(150_000)
}
let err = AXUIElementPerformAction(target.el, "AXPress" as CFString)
if err != .success { fail(3, "AXPress failed (code \(err.rawValue))") }
app.activate(options: [.activateIgnoringOtherApps])
print("focused: \"\(target.title)\"")
