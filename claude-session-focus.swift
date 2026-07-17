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
//   claude-session-focus "ccfocus://RCA%20invest"   same, URL form (scheme+percent decoding)
//   claude-session-focus --list                     print visible session row titles
//   claude-session-focus --dry "<substring>"        show what would be pressed, don't press
//
// Matching: exact title first, then substring; a leading "Running " status prefix on row
// titles is ignored; shallowest (sidebar) match wins over in-content duplicates. If the
// row isn't rendered (virtualized list), presses "Load more sessions" up to 3x and rescans.
//
// Exit codes: 0 ok, 2 no match, 4 accessibility not granted, 5 app not running.

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
if let i = args.firstIndex(of: "--list") { listOnly = true; args.remove(at: i) }
if let i = args.firstIndex(of: "--dry") { dryRun = true; args.remove(at: i) }

var query = args.first ?? ""
if query.lowercased().hasPrefix("ccfocus://") {
    query = String(query.dropFirst("ccfocus://".count))
    if query.hasSuffix("/") { query = String(query.dropLast()) }
}
query = query.removingPercentEncoding ?? query
query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
if query.isEmpty && !listOnly { fail(2, "usage: claude-session-focus [--list|--dry] \"<title substring>\"") }

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
