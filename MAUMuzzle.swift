// MAUMuzzle — stop Microsoft AutoUpdate stealing focus when it opens itself.
//
// MAU is launched in the background with `-silent`, then puts its window in
// front of you anyway. This keeps that instance hidden and hands focus back to
// the app you were in. Each time MAU comes to the front, it asks whether you
// brought it there (a click or Cmd-Tab just now) or it did. If you did, it's
// left alone. If MAU did, it's hidden again.
//
// A muzzled MAU is quit after 5 minutes unless you bring it up. That's a
// polite quit, like Cmd-Q, and never while an update is downloading or
// installing. MAU is never force-killed. Instances started by hand (no `-silent`) are never
// touched.
//
// Build:
//   swiftc -O -o MAUMuzzle MAUMuzzle.swift -framework AppKit
//
// Modes: (no args) = install, --watch, --status, --selftest

import AppKit
import Security

let appName  = "MAUMuzzle"
let bundleID = "com.camurphy.mau-muzzle"
let mauID    = "com.microsoft.autoupdate2"

/// MAU's own launch activation always gets muzzled, even if you happened to
/// click something at the time. Nobody clicks MAU's Dock icon this soon.
let launchGrace: TimeInterval = 5
/// A click this recent counts as you choosing MAU. The Dock activates an app on
/// mouse-up, so a Dock click lands well within this.
let clickWindow: TimeInterval = 0.5
/// How long a muzzled MAU is left hidden before it's quit.
let quitAfter: TimeInterval = 300
/// If an update is in progress when that's up, check again this often.
let busyRetry: TimeInterval = 60
/// Downloads updates. MAU's window is only its front end, so quitting the
/// window is harmless unless this is mid-download. It stays running as long as
/// MAU is open, so being alive proves nothing; CPU use is the signal.
let updateAssistant = "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/Microsoft Update Assistant.app/Contents/MacOS/Microsoft Update Assistant"
/// Installs updates. launchd only starts it when there's an install or clone
/// to do, so it running at all means an install is under way.
let installHelper = "/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helper"
/// CPU the assistant may use between checks and still count as idle. Idle, it
/// used 0.7s in its first three minutes, including startup.
let idleCPU: Double = 1.0

let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/mau-muzzle")
let logFile  = stateDir.appendingPathComponent("muzzle.log")

/// Log to stdout and to a file, because launchd discards stdout by default and
/// a silent background failure is impossible to diagnose otherwise.
func log(_ s: String) {
    print(s)
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date())
    guard let d = "\(stamp)  \(s)\n".data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: logFile) {
        h.seekToEndOfFile(); h.write(d); try? h.close()
    } else {
        try? d.write(to: logFile)
    }
}

// MARK: - which MAU instance is this

/// Another process's argv, read in-process via KERN_PROCARGS2. The buffer is
/// argc, the exec path, NUL padding, then the arguments.
func arguments(of pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
    let argc = buf.withUnsafeBytes { Int($0.load(as: Int32.self)) }
    var i = 4
    while i < size && buf[i] != 0 { i += 1 }   // exec path
    while i < size && buf[i] == 0 { i += 1 }   // padding
    var args: [String] = []
    while args.count < argc && i < size {
        let start = i
        while i < size && buf[i] != 0 { i += 1 }
        args.append(String(decoding: buf[start..<i], as: UTF8.self))
        i += 1
    }
    return args
}

/// True for a background-launched MAU. That's the one that pops up uninvited.
func isSilent(_ app: NSRunningApplication) -> Bool {
    arguments(of: app.processIdentifier).contains("-silent")
}

// MARK: - the decision

enum Verdict: Equatable {
    case ignore   // not a background instance, hands off
    case allow    // you brought it forward
    case muzzle   // it brought itself forward
}

/// Pure so it can be exercised by --selftest without a real MAU.
func decide(silent: Bool, sinceLaunch: TimeInterval, sinceClick: TimeInterval,
            commandHeld: Bool) -> Verdict {
    if !silent { return .ignore }
    if sinceLaunch < launchGrace { return .muzzle }
    // Typing is deliberately not evidence: MAU popping up mid-sentence is
    // exactly the case this exists for. Cmd held means Cmd-Tab.
    if sinceClick < clickWindow || commandHeld { return .allow }
    return .muzzle
}

enum QuitVerdict: Equatable {
    case quit     // still hidden and idle, close it
    case wait     // an update is running, try again shortly
    case leave    // you're using it, stop the timer
}

/// Pure so it can be exercised by --selftest without a real MAU.
func decideQuit(hidden: Bool, active: Bool, updating: Bool) -> QuitVerdict {
    if active || !hidden { return .leave }
    return updating ? .wait : .quit
}

// MARK: - watching

/// The app you were in, so focus can go back there.
var lastApp: NSRunningApplication?

func secondsSinceClick() -> TimeInterval {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseUp)
}

func commandHeld() -> Bool {
    CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
}

func sinceLaunch(_ app: NSRunningApplication) -> TimeInterval {
    app.launchDate.map { Date().timeIntervalSince($0) } ?? .infinity
}

/// Pending quits, by pid. One per MAU instance.
var quitTimers: [pid_t: Timer] = [:]

func pids(of path: String) -> [pid_t] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", "^" + NSRegularExpression.escapedPattern(for: path) + "( |$)"]
    let pipe = Pipe(); p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [] }
    p.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return out.split(separator: "\n").compactMap { pid_t($0) }
}

/// CPU seconds a process has used so far, or nil if it's gone.
func cpuSeconds(_ pid: pid_t) -> Double? {
    var info = rusage_info_v0()
    let rc = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
        }
    }
    guard rc == 0 else { return nil }
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    let ticks = Double(info.ri_user_time + info.ri_system_time)
    return ticks * Double(tb.numer) / Double(tb.denom) / 1e9
}

/// The assistant's CPU total at the last check, by pid.
var assistantCPU: [pid_t: Double] = [:]

/// True if an update looks to be downloading or installing: the install helper
/// is running, or the assistant has been doing real work since the last check.
func updateInProgress() -> Bool {
    if !pids(of: installHelper).isEmpty { return true }
    var busy = false
    var seen: [pid_t: Double] = [:]
    for pid in pids(of: updateAssistant) {
        guard let now = cpuSeconds(pid) else { continue }
        // A pid we haven't sampled started since the last check, so judge
        // everything it has done.
        if now - (assistantCPU[pid] ?? 0) > idleCPU { busy = true }
        seen[pid] = now
    }
    assistantCPU = seen
    return busy
}

/// Quit a muzzled MAU after `delay`, unless you bring it up first. An existing
/// timer is kept, so being muzzled again doesn't push the quit back.
func armQuit(_ app: NSRunningApplication, after delay: TimeInterval = quitAfter) {
    let pid = app.processIdentifier
    guard quitTimers[pid] == nil else { return }
    _ = updateInProgress()   // baseline the assistant's CPU for the check
    quitTimers[pid] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
        quitTimers[pid] = nil
        quitIfStillMuzzled(app)
    }
}

func cancelQuit(_ app: NSRunningApplication) {
    guard let t = quitTimers.removeValue(forKey: app.processIdentifier) else { return }
    t.invalidate()
    log("quit timer cancelled, you brought it up")
}

func quitIfStillMuzzled(_ app: NSRunningApplication) {
    guard !app.isTerminated else { return }
    switch decideQuit(hidden: app.isHidden, active: app.isActive, updating: updateInProgress()) {
    case .leave:
        log("not quitting, it's open")
    case .wait:
        log("update in progress, checking again in \(Int(busyRetry))s")
        armQuit(app, after: busyRetry)
    case .quit:
        app.terminate()
        log("quit, left hidden and idle (pid \(app.processIdentifier))")
    }
}

func muzzle(_ app: NSRunningApplication, _ why: String) {
    app.hide()
    armQuit(app)
    if let prev = lastApp, !prev.isTerminated {
        prev.activate()
        log("muzzled (\(why)), focus back to \(prev.localizedName ?? "previous app")")
    } else {
        log("muzzled (\(why))")
    }
}

func activated(_ app: NSRunningApplication) {
    guard app.bundleIdentifier == mauID else { lastApp = app; return }
    let click = secondsSinceClick(), cmd = commandHeld(), age = sinceLaunch(app)
    switch decide(silent: isSilent(app), sinceLaunch: age, sinceClick: click, commandHeld: cmd) {
    case .ignore:
        break
    case .allow:
        cancelQuit(app)
        log(String(format: "allowed (click %.2fs ago, cmd=%@)", click, cmd ? "yes" : "no"))
    case .muzzle:
        muzzle(app, age < launchGrace ? "just launched" : "activated itself")
    }
}

/// Hide on launch too: MAU can put a window up without taking focus, and that
/// window should stay out of sight until you ask for it.
func launched(_ app: NSRunningApplication) {
    guard app.bundleIdentifier == mauID, isSilent(app) else { return }
    app.hide()
    armQuit(app)
    log("background launch hidden (pid \(app.processIdentifier))")
}

func watch() -> Never {
    let nc = NSWorkspace.shared.notificationCenter
    nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                   object: nil, queue: .main) { n in
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            activated(app)
        }
    }
    nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                   object: nil, queue: .main) { n in
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            launched(app)
        }
    }
    nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                   object: nil, queue: .main) { n in
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            quitTimers.removeValue(forKey: app.processIdentifier)?.invalidate()
        }
    }
    if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != mauID {
        lastApp = front
    }
    // A background MAU already hidden when we start (after a reinstall or at
    // login) gets the same timer.
    for app in NSWorkspace.shared.runningApplications
    where app.bundleIdentifier == mauID && app.isHidden && isSilent(app) {
        armQuit(app)
        log("found hidden background MAU (pid \(app.processIdentifier)), quit timer started")
    }
    log("watching")
    RunLoop.main.run()
    exit(0)
}

// MARK: - self install

@discardableResult
func run(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError  = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// Resolve App Translocation back to the real file on disk.
///
/// Launching a quarantined app from somewhere like ~/Downloads does not run it
/// in place: macOS mounts a read-only randomized copy under AppTranslocation
/// and runs that. Bundle.main.bundleURL then points at an ephemeral mount with
/// no Trash, so cleaning up needs the original path instead.
/// The SecTranslocate functions are C-only in the SDK and aren't visible to
/// Swift through `import Security`, so bind them at runtime.
private typealias IsTranslocatedFn =
    @convention(c) (CFURL, UnsafeMutablePointer<DarwinBoolean>, UnsafeMutableRawPointer?) -> Bool
private typealias OriginalPathFn =
    @convention(c) (CFURL, UnsafeMutableRawPointer?) -> Unmanaged<CFURL>?

func originalPath(of url: URL) -> URL {
    let looksTranslocated = url.path.contains("/AppTranslocation/")
    guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
          let isSym   = dlsym(handle, "SecTranslocateIsTranslocatedURL"),
          let origSym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL")
    else {
        if looksTranslocated { log("running translocated but SecTranslocate is unavailable") }
        return url
    }
    let isTranslocated = unsafeBitCast(isSym, to: IsTranslocatedFn.self)
    let createOriginal = unsafeBitCast(origSym, to: OriginalPathFn.self)

    var flag: DarwinBoolean = false
    guard isTranslocated(url as CFURL, &flag, nil), flag.boolValue,
          let original = createOriginal(url as CFURL, nil)
    else {
        if looksTranslocated { log("could not resolve the translocated path back to the original") }
        return url
    }
    return original.takeRetainedValue() as URL
}

/// True if the item carries com.apple.quarantine, i.e. it was downloaded rather
/// than built here. Used to tell a throwaway copy from a real working one.
func isQuarantined(_ url: URL) -> Bool {
    getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
}

/// Trash the copy the user launched, once it has been installed elsewhere.
/// Only for downloaded copies: a locally built bundle has no quarantine flag,
/// so `make install` never deletes your build output.
func cleanUpSource(_ source: URL) {
    guard isQuarantined(source) else {
        log("left \(source.path) alone (not a downloaded copy)")
        return
    }
    var resulting: NSURL?
    do {
        try FileManager.default.trashItem(at: source, resultingItemURL: &resulting)
        let landed = (resulting as URL?)?.path ?? "the Trash"
        log("moved the downloaded copy to the Trash: \(source.path) -> \(landed)")
    } catch {
        log("could not trash \(source.path): \(error)")
    }
}

/// Copy ourselves to ~/Applications, then write and load the LaunchAgent. This
/// is what happens when the app is simply opened. No permission prompt: the
/// input timing it reads needs no grant.
func installSelf() -> Int32 {
    let fm   = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let dest = home.appendingPathComponent("Applications/\(appName).app")
    // Where we are actually executing, which may be a translocated mount, and
    // where that really lives on disk. Copy from the former (always readable);
    // clean up the latter (the file the user can actually see).
    let running = Bundle.main.bundleURL
    let me = originalPath(of: running)
    if me != running { log("running translocated; real path is \(me.path)") }
    let copied = me.standardizedFileURL != dest.standardizedFileURL

    let agentsDir = home.appendingPathComponent("Library/LaunchAgents")
    let plistURL  = agentsDir.appendingPathComponent("\(bundleID).plist")
    let uid = getuid()
    // Stop the running watcher before replacing the bundle it runs from.
    run("/bin/launchctl", ["bootout", "gui/\(uid)", plistURL.path])

    if copied {
        try? fm.createDirectory(at: home.appendingPathComponent("Applications"),
                                withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        do { try fm.copyItem(at: running, to: dest) }
        catch { log("could not install to \(dest.path): \(error)"); return 1 }
        log("installed to \(dest.path)")
    }

    let exe = dest.appendingPathComponent("Contents/MacOS/\(appName)").path
    let agentPlist: [String: Any] = [
        "Label": bundleID,
        "ProgramArguments": [exe, "--watch"],
        "RunAtLoad": true,
        "KeepAlive": true,
        // Reacting inside the same frame as MAU's window matters, so don't let
        // launchd throttle it as a background job.
        "ProcessType": "Interactive",
        "StandardOutPath": "/tmp/mau-muzzle.out",
        "StandardErrorPath": "/tmp/mau-muzzle.err",
    ]
    try? fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
    guard let data = try? PropertyListSerialization.data(
        fromPropertyList: agentPlist, format: .xml, options: 0) else {
        log("could not build the LaunchAgent plist"); return 1
    }
    do { try data.write(to: plistURL) }
    catch { log("could not write \(plistURL.path): \(error)"); return 1 }

    // Clean up and log before bootstrapping. When we are running translocated,
    // starting the installed copy can tear down the read-only mount we are
    // executing from, killing this process the moment it faults in more code.
    if copied { cleanUpSource(me) }
    log("loading LaunchAgent")
    let rc = run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
    if rc != 0 { log("launchctl bootstrap failed (\(rc))") }
    return rc == 0 ? 0 : 1
}

// MARK: - status and self test

func status() {
    let mau = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == mauID }
    if mau.isEmpty { print("MAU: not running") }
    for app in mau {
        print("MAU pid \(app.processIdentifier): silent=\(isSilent(app)) hidden=\(app.isHidden) active=\(app.isActive)")
    }
}

func selfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ got: Verdict, _ want: Verdict) {
        let ok = got == want
        if !ok { failures += 1 }
        print("  \(ok ? "pass" : "FAIL")  \(name): got \(got), want \(want)")
    }
    check("hand-launched MAU is left alone",
          decide(silent: false, sinceLaunch: 1, sinceClick: 99, commandHeld: false), .ignore)
    check("background launch is muzzled",
          decide(silent: true, sinceLaunch: 1, sinceClick: 99, commandHeld: false), .muzzle)
    check("a stray click during launch doesn't let it through",
          decide(silent: true, sinceLaunch: 1, sinceClick: 0.1, commandHeld: false), .muzzle)
    check("popping up later while you type is muzzled",
          decide(silent: true, sinceLaunch: 3600, sinceClick: 8, commandHeld: false), .muzzle)
    check("Dock click is allowed",
          decide(silent: true, sinceLaunch: 3600, sinceClick: 0.05, commandHeld: false), .allow)
    check("Cmd-Tab is allowed",
          decide(silent: true, sinceLaunch: 3600, sinceClick: 30, commandHeld: true), .allow)
    check("a click just outside the window doesn't count",
          decide(silent: true, sinceLaunch: 3600, sinceClick: 0.6, commandHeld: false), .muzzle)
    func checkQuit(_ name: String, _ got: QuitVerdict, _ want: QuitVerdict) {
        let ok = got == want
        if !ok { failures += 1 }
        print("  \(ok ? "pass" : "FAIL")  \(name): got \(got), want \(want)")
    }
    checkQuit("hidden and idle is quit",
              decideQuit(hidden: true, active: false, updating: false), .quit)
    checkQuit("mid-update waits",
              decideQuit(hidden: true, active: false, updating: true), .wait)
    checkQuit("open on screen is left alone",
              decideQuit(hidden: false, active: false, updating: false), .leave)
    checkQuit("in front is left alone",
              decideQuit(hidden: false, active: true, updating: true), .leave)
    print(failures == 0 ? "  all passed" : "  \(failures) FAILED")
    return failures == 0 ? 0 : 1
}

// MARK: - main

switch CommandLine.arguments.dropFirst().first {

case "--watch":
    // What the LaunchAgent runs.
    watch()

case "--status":
    status()

case "--selftest":
    exit(selfTest())

case nil, "--install":
    // Opening the app (double-click, or `open -a`) installs it.
    exit(installSelf())

case .some(let other):
    log("unknown option: \(other)")
    exit(64)
}
