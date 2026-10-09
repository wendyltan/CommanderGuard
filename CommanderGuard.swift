import Cocoa
import IOKit
import IOKit.pwr_mgt
import Foundation
import Darwin
import CoreFoundation
import CryptoKit
import CoreGraphics

struct UsageQuota {
    enum State: String { case disconnected, connecting, refreshing, loginRequired, unavailable, fresh, stale, unlimited }
    var state: State = .disconnected
    var used: Int?
    var total: Int?
    var plan = ""
    var month = ""
    var syncedAt: Date?

    var remaining: Int? { total.map { max(0, $0 - (used ?? 0)) } }
    static func parse(_ data: Data, now: Date = Date()) -> UsageQuota? {
        guard data.count <= 8192,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any],
              let used = integer(usage["callsUsed"]),
              let plan = usage["plan"] as? String, !plan.isEmpty, plan.count <= 64,
              ["free", "pro"].contains(plan.lowercased()),
              validMonth(usage["month"])
        else { return nil }
        let total: Int?
        if usage["callsIncluded"] is NSNull, plan.lowercased() == "pro" { total = nil }
        else if let finite = integer(usage["callsIncluded"]), finite > 0 { total = finite }
        else { return nil }
        return UsageQuota(state: total == nil ? .unlimited : .fresh, used: used, total: total, plan: plan, month: usage["month"] as? String ?? "本月", syncedAt: now)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue <= 1_000_000_000,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
    }
    private static func validMonth(_ value: Any?) -> Bool {
        guard let value else { return true }
        if value is NSNull { return true }
        guard let month = value as? String else { return false }
        return month.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil
    }
}

func trustedQuotaURL(_ url: URL?) -> Bool {
    guard let url, url.scheme == "https", url.user == nil, url.password == nil,
          url.port == nil || url.port == 443, url.host?.lowercased() == "mcp.desktopcommander.app",
          url.path == "/usage", url.query == nil, url.fragment == nil else { return false }
    return true
}

let quotaRefreshOptions = [0, 60, 120, 300, 600, 1800, 3600]
let quotaDefaultRefreshSeconds = 300

func sanitizedQuotaRefreshSeconds(_ seconds: Int?) -> Int {
    guard let seconds, quotaRefreshOptions.contains(seconds) else { return quotaDefaultRefreshSeconds }
    return seconds
}

func quotaStaleInterval(for refreshSeconds: Int) -> TimeInterval {
    max(900, Double(refreshSeconds) * 2 + 60)
}

func quotaIsStale(_ quota: UsageQuota, now: Date, refreshSeconds: Int = quotaDefaultRefreshSeconds) -> Bool {
    quota.used != nil && quota.syncedAt.map { now.timeIntervalSince($0) > quotaStaleInterval(for: refreshSeconds) } == true
}

/// Uses only CommanderGuard's private Chrome profile; never attaches to another browser.
final class HeadlessQuotaBrowser {
    enum Outcome {
        case success(UsageQuota), loginRequired, loginOpen, unavailable(String), cancelled
    }
    enum Failure: Error, LocalizedError {
        case unavailable, profile, busy, timeout, cancelled, protocolError
        var errorDescription: String? {
            switch self {
            case .profile: return "专用浏览器资料目录不可用"
            case .busy: return "请先关闭专用登录浏览器"
            case .timeout: return "额度读取超时"
            case .cancelled: return "额度读取已取消"
            default: return "专用浏览器暂时无法读取额度"
            }
        }
    }
    private let stateLock = NSLock()
    private let worker = DispatchQueue(label: "CommanderGuard.QuotaBrowser", qos: .utility)
    private var reading = false
    private var cancelled = false
    private var loginProcess: Process?
    private var loginLockFD: Int32 = -1
    private var sawLoginWindow = false
    private var missingLoginWindowSamples = 0
    var onLoginClosed: (() -> Void)?
    private static let pageURL = "https://mcp.desktopcommander.app/usage"
    private static var profileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CommanderGuard/QuotaBrowser", isDirectory: true)
    }

    func read(chromeExecutable: URL, completion: @escaping (Outcome) -> Void) {
        stateLock.lock()
        if loginProcess != nil {
            stateLock.unlock(); DispatchQueue.main.async { completion(.loginOpen) }; return
        }
        if reading {
            stateLock.unlock(); DispatchQueue.main.async { completion(.unavailable("额度读取正在进行")) }; return
        }
        reading = true; cancelled = false
        stateLock.unlock()
        worker.async { [self] in
            let outcome: Outcome
            do {
                if isCancelled() { throw Failure.cancelled }
                let executable = try Self.validateExecutable(chromeExecutable)
                let profile = try Self.prepareProfile()
                let lockFD = try Self.acquireProfile(profile)
                defer { flock(lockFD, LOCK_UN); close(lockFD) }
                if try Self.hasBrowserLock(profile) { outcome = .loginOpen }
                else if !Self.loginRequested(profile) { outcome = .loginRequired }
                else {
                    if isCancelled() { throw Failure.cancelled }
                    let session = try PipeBrowser(executable: executable, profile: profile, cancelled: { [self] in isCancelled() })
                    defer { session.finish() }
                    let result = try session.fetchQuota()
                    if result == "login" { outcome = .loginRequired }
                    else if let bytes = result.data(using: .utf8), let quota = UsageQuota.parse(bytes) { outcome = .success(quota) }
                    else if result == "timeout" { outcome = .unavailable("官方额度服务读取超时") }
                    else if result == "network" { outcome = .unavailable("无法连接官方额度服务") }
                    else if result.range(of: #"^http-[1-5][0-9]{2}$"#, options: .regularExpression) != nil {
                        outcome = .unavailable("官方额度服务返回 HTTP \(result.suffix(3))")
                    } else { outcome = .unavailable("官方额度响应暂时不可用") }
                }
            } catch let error as Failure {
                switch error {
                case .cancelled: outcome = .cancelled
                case .busy: outcome = .loginOpen
                default: outcome = .unavailable(error.localizedDescription)
                }
            } catch { outcome = .unavailable("专用浏览器暂时无法读取额度") }
            stateLock.lock()
            let wasCancelled = cancelled
            reading = false
            stateLock.unlock()
            DispatchQueue.main.async { completion(wasCancelled ? .cancelled : outcome) }
        }
    }

    func cancel() {
        stateLock.lock(); if reading { cancelled = true }; stateLock.unlock()
    }
    private func isCancelled() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return cancelled
    }

    /// Explicit user action only. Returns false when the dedicated login browser is already open.
    @discardableResult func openLogin(chromeExecutable: URL) throws -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if loginProcess != nil { return false }
        guard !reading else { throw Failure.busy }
        let executable = try Self.validateExecutable(chromeExecutable)
        let profile = try Self.prepareProfile()
        let fd = try Self.acquireProfile(profile)
        var keepLock = false
        defer { if !keepLock { flock(fd, LOCK_UN); close(fd) } }
        if try Self.hasBrowserLock(profile) { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(profile: profile, headless: false)
        process.environment = Self.childEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] owned in
            guard let self else { return }
            self.stateLock.lock(); defer { self.stateLock.unlock() }
            if self.loginProcess === owned {
                self.loginProcess = nil
                self.sawLoginWindow = false
                self.missingLoginWindowSamples = 0
                DispatchQueue.main.async { [weak self] in self?.onLoginClosed?() }
                if self.loginLockFD >= 0 {
                    Self.clearExitedOwnedBrowserLock(profile, pid: owned.processIdentifier)
                    flock(self.loginLockFD, LOCK_UN); close(self.loginLockFD); self.loginLockFD = -1
                }
            }
        }
        // Store readiness before launch, so a marker failure cannot leave an untracked browser.
        try Self.markLoginRequested(profile)
        try process.run()
        loginProcess = process; loginLockFD = fd; keepLock = true
        DispatchQueue.main.async { [weak self] in self?.monitorLoginWindow() }
        return true
    }

    var hasOwnedLogin: Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return loginProcess != nil
    }
    /// Explicit completion button: terminate only the login child this instance launched.
    @discardableResult func finishOwnedLogin() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let process = loginProcess else { return false }
        if process.isRunning { process.terminate() }
        return true // onLoginClosed reads usage after the owned child has exited and released its lock.
    }

    private func monitorLoginWindow() {
        stateLock.lock()
        guard let process = loginProcess else { stateLock.unlock(); return }
        let pid = process.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        var closeOwnedProcess = false
        if let windows {
            // Only owner PID and window layer are inspected; minimized/OAuth windows count too.
            let hasWindow = windows.contains { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }
            if hasWindow { sawLoginWindow = true; missingLoginWindowSamples = 0 }
            else if sawLoginWindow && process.isRunning {
                missingLoginWindowSamples += 1
                closeOwnedProcess = missingLoginWindowSamples >= 3
            }
        } else { missingLoginWindowSamples = 0 }
        stateLock.unlock()
        if closeOwnedProcess { process.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.monitorLoginWindow() }
    }

    private static var childEnvironment: [String: String] {
        ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8"]
    }
    private static func arguments(profile: URL, headless: Bool) -> [String] {
        let shared = ["--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check"]
        return shared + (headless
            ? ["--headless=new", "--remote-debugging-pipe", "--disable-background-networking", "about:blank"]
            : ["--app=\(pageURL)"])
    }
    private static func validateExecutable(_ url: URL) throws -> URL {
        let allowed = ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Google Chrome.app/Contents/MacOS/Google Chrome").path]
        guard url.isFileURL, allowed.contains(url.path), url.standardizedFileURL.path == url.path else { throw Failure.unavailable }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0 || info.st_uid == geteuid(), info.st_mode & 0o002 == 0,
              access(url.path, X_OK) == 0 else { throw Failure.unavailable }
        return url
    }
    private static func prepareProfile() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var current = home
        let parts = ["Library", "Application Support", "CommanderGuard", "QuotaBrowser"]
        for part in [""] + parts {
            if !part.isEmpty { current.appendPathComponent(part, isDirectory: true) }
            var info = stat()
            if lstat(current.path, &info) != 0 {
                guard errno == ENOENT, !part.isEmpty, mkdir(current.path, 0o700) == 0, lstat(current.path, &info) == 0 else { throw Failure.profile }
            }
            try validateDirectory(current, privateMode: part == "QuotaBrowser")
        }
        guard current.path == profileURL.path else { throw Failure.profile }
        return current
    }
    private static func validateDirectory(_ url: URL, privateMode: Bool) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & (privateMode ? 0o077 : 0o022) == 0 else { throw Failure.profile }
    }
    private static func acquireProfile(_ profile: URL) throws -> Int32 {
        let fd = open(profile.appendingPathComponent(".commander-guard.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.profile }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1 else { close(fd); throw Failure.profile }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw Failure.busy }
        return fd
    }
    private static func hasBrowserLock(_ profile: URL) throws -> Bool {
        var info = stat()
        // Fail closed even for an abandoned Chrome SingletonLock; never remove another process's lock.
        if lstat(profile.appendingPathComponent("SingletonLock").path, &info) == 0 { return true }
        guard errno == ENOENT else { throw Failure.profile }
        return false
    }
    /// Called only for the recorded login child after termination, while its profile flock is held.
    private static func clearExitedOwnedBrowserLock(_ profile: URL, pid: pid_t) {
        guard pid > 0, kill(pid, 0) == -1, errno == ESRCH else { return }
        let lock = profile.appendingPathComponent("SingletonLock")
        var first = stat(), current = stat()
        guard lstat(lock.path, &first) == 0, (first.st_mode & S_IFMT) == S_IFLNK, first.st_uid == geteuid(),
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lock.path),
              target.split(separator: "-").last == Substring(String(pid)),
              lstat(lock.path, &current) == 0, current.st_dev == first.st_dev, current.st_ino == first.st_ino,
              current.st_mode == first.st_mode, current.st_uid == first.st_uid,
              current.st_mtimespec.tv_sec == first.st_mtimespec.tv_sec, current.st_mtimespec.tv_nsec == first.st_mtimespec.tv_nsec,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: lock.path)) == target else { return }
        _ = unlink(lock.path)
    }

    private static func loginRequested(_ profile: URL) -> Bool {
        let fd = open(profile.appendingPathComponent(".login-requested").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }; defer { close(fd) }
        var info = stat()
        return fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid() && info.st_mode & 0o077 == 0 && info.st_size == 0 && info.st_nlink == 1
    }
    private static func markLoginRequested(_ profile: URL) throws {
        let fd = open(profile.appendingPathComponent(".login-requested").path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.profile }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_size == 0, info.st_nlink == 1 else { throw Failure.profile }
    }

    private final class PipeBrowser {
        private var pid: pid_t = 0
        private var writeFD: Int32 = -1
        private var readFD: Int32 = -1
        private var buffer = Data()
        private var received = 0
        private var sequence = 0
        private let deadline = ProcessInfo.processInfo.systemUptime + 31.8
        private let cancelled: () -> Bool
        private var finished = false
        init(executable: URL, profile: URL, cancelled: @escaping () -> Bool) throws {
            self.cancelled = cancelled
            var commands: [Int32] = [0, 0], replies: [Int32] = [0, 0]
            guard pipe(&commands) == 0 else { throw Failure.unavailable }
            guard pipe(&replies) == 0 else { close(commands[0]); close(commands[1]); throw Failure.unavailable }
            var originals = commands + replies
            var high: [Int32] = []
            defer { for fd in originals + high { close(fd) } }
            // Move every source above 4 before dup2; source/target collisions must never close a pipe.
            for fd in originals {
                let duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 10)
                guard duplicate >= 0 else { throw Failure.unavailable }
                high.append(duplicate)
            }
            for fd in originals { close(fd) }; originals.removeAll()
            guard fcntl(high[1], F_SETFL, O_NONBLOCK) == 0, fcntl(high[2], F_SETFL, O_NONBLOCK) == 0,
                  fcntl(high[1], F_SETNOSIGPIPE, 1) == 0 else { throw Failure.unavailable }
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            guard posix_spawn_file_actions_init(&actions) == 0 else { throw Failure.unavailable }
            defer { posix_spawn_file_actions_destroy(&actions) }
            guard posix_spawnattr_init(&attributes) == 0 else { throw Failure.unavailable }
            defer { posix_spawnattr_destroy(&attributes) }
            guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
                  posix_spawn_file_actions_adddup2(&actions, high[0], 3) == 0,
                  posix_spawn_file_actions_adddup2(&actions, high[3], 4) == 0 else { throw Failure.unavailable }
            for target: Int32 in [0, 1, 2] {
                guard posix_spawn_file_actions_addopen(&actions, target, "/dev/null", O_RDWR, 0) == 0 else { throw Failure.unavailable }
            }
            let argv = ([executable.path] + HeadlessQuotaBrowser.arguments(profile: profile, headless: true)).map { strdup($0) }
            defer { for pointer in argv { free(pointer) } }
            var terminatedArgv = argv + [nil]
            let environment = HeadlessQuotaBrowser.childEnvironment.map { strdup("\($0.key)=\($0.value)") }
            defer { for pointer in environment { free(pointer) } }
            var terminatedEnvironment = environment + [nil]
            let status = terminatedArgv.withUnsafeMutableBufferPointer { argv in
                terminatedEnvironment.withUnsafeMutableBufferPointer { env in
                    posix_spawn(&pid, executable.path, &actions, &attributes, argv.baseAddress!, env.baseAddress!)
                }
            }
            guard status == 0 else { pid = 0; throw Failure.unavailable }
            writeFD = high[1]; readFD = high[2]
            high = [high[0], high[3]]
        }
        deinit { finish() }
        func probe() throws {
            let result = try request("Target.createTarget", ["url": "about:blank"])
            guard let id = result["targetId"] as? String else { throw Failure.protocolError }
            let attached = try request("Target.attachToTarget", ["targetId": id, "flatten": true])
            guard let session = attached["sessionId"] as? String else { throw Failure.protocolError }
            let evaluated = try request("Runtime.evaluate", ["expression": "1 + 1", "returnByValue": true], session: session)
            guard (evaluated["result"] as? [String: Any])?["value"] as? Int == 2 else { throw Failure.protocolError }
        }
        func fetchQuota() throws -> String {
            let target = try request("Target.createTarget", ["url": "about:blank"])
            guard let targetID = target["targetId"] as? String else { throw Failure.protocolError }
            let attached = try request("Target.attachToTarget", ["targetId": targetID, "flatten": true])
            guard let session = attached["sessionId"] as? String else { throw Failure.protocolError }
            let navigation = try request("Page.navigate", ["url": HeadlessQuotaBrowser.pageURL], session: session)
            guard navigation["errorText"] == nil else { throw Failure.unavailable }
            while true {
                let response = try request("Runtime.evaluate", ["expression": "document.readyState === 'loading' || location.href === 'about:blank' ? 'pending' : (location.origin === 'https://mcp.desktopcommander.app' && location.pathname === '/usage' ? 'ready' : 'login')", "returnByValue": true], session: session)
                if (response["result"] as? [String: Any])?["value"] as? String == "ready" { break }
                if let text = (response["result"] as? [String: Any])?["value"] as? String, text == "login" { return "login" }
                try check(until: deadline)
                Thread.sleep(forTimeInterval: 0.1)
            }
            let result = try request("Runtime.evaluate", ["expression": HeadlessQuotaBrowser.usageScript, "awaitPromise": true, "returnByValue": true], session: session, timeout: 14)
            guard result["exceptionDetails"] == nil, let value = (result["result"] as? [String: Any])?["value"] as? String, value.utf8.count <= 8192 else { throw Failure.protocolError }
            return value
        }
        private func check(until limit: TimeInterval) throws {
            if cancelled() { throw Failure.cancelled }
            if ProcessInfo.processInfo.systemUptime >= min(limit, deadline) { throw Failure.timeout }
        }
        private func ready(_ fd: Int32, events: Int16, until limit: TimeInterval) throws {
            while true {
                try check(until: limit)
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let result = poll(&descriptor, 1, 100)
                if result < 0 { if errno == EINTR { continue }; throw Failure.unavailable }
                if result == 0 { continue }
                if descriptor.revents & events != 0 { return }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw Failure.unavailable }
            }
        }
        private func request(_ method: String, _ params: [String: Any] = [:], session: String? = nil, timeout: TimeInterval = 5) throws -> [String: Any] {
            guard ["Target.createTarget", "Target.attachToTarget", "Page.navigate", "Runtime.evaluate"].contains(method) else { throw Failure.protocolError }
            sequence += 1
            var object: [String: Any] = ["id": sequence, "method": method, "params": params]
            if let session { object["sessionId"] = session }
            var data = try JSONSerialization.data(withJSONObject: object); data.append(0)
            let limit = min(deadline, ProcessInfo.processInfo.systemUptime + timeout)
            var offset = 0
            try data.withUnsafeBytes { bytes in
                while offset < data.count {
                    try ready(writeFD, events: Int16(POLLOUT), until: limit)
                    let count = Darwin.write(writeFD, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                    if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw Failure.unavailable }
                    guard count > 0 else { throw Failure.unavailable }; offset += count
                }
            }
            while true {
                try check(until: limit)
                if let frame = try HeadlessQuotaBrowser.popFrame(&buffer) {
                    guard let reply = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else { throw Failure.protocolError }
                    if (reply["id"] as? Int) == sequence {
                        guard reply["error"] == nil, let result = reply["result"] as? [String: Any] else { throw Failure.protocolError }
                        return result
                    }
                    continue
                }
                try ready(readFD, events: Int16(POLLIN), until: limit)
                var chunk = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(readFD, &chunk, chunk.count)
                if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw Failure.unavailable }
                guard count > 0 else { throw Failure.unavailable }
                received += count
                guard received <= 4_194_304 else { throw Failure.protocolError }
                buffer.append(contentsOf: chunk.prefix(count))
            }
        }
        func finish() {
            guard !finished else { return }; finished = true
            guard pid > 0 else { return }
            // The close command is fixed and best-effort; cleanup never waits for a remote reply.
            if writeFD >= 0 {
                let closeMessage = Data("{\"id\":2147483647,\"method\":\"Browser.close\"}\u{0}".utf8)
                closeMessage.withUnsafeBytes { bytes in _ = Darwin.write(writeFD, bytes.baseAddress, bytes.count) }
            }
            var status: Int32 = 0
            var reaped = false
            for phase in 0..<3 {
                let end = ProcessInfo.processInfo.systemUptime + (phase == 0 ? 2 : 0.4)
                while ProcessInfo.processInfo.systemUptime < end {
                    let result = waitpid(pid, &status, WNOHANG)
                    if result == pid || (result < 0 && errno == ECHILD) { reaped = true; break }
                    // Drain bounded chunks while Chrome exits, so its reply pipe cannot hold shutdown open.
                    if readFD >= 0 { var bytes = [UInt8](repeating: 0, count: 8192); _ = Darwin.read(readFD, &bytes, bytes.count) }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if reaped { break }
                if phase == 0 { _ = kill(pid, SIGTERM) }
                if phase == 1 { _ = kill(pid, SIGKILL) }
            }
            if !reaped {
                _ = kill(pid, SIGKILL)
                // Preserve the wall-clock bound even if the kernel delays reaping a killed child.
                let ownedPID = pid
                DispatchQueue.global(qos: .utility).async {
                    var exitStatus: Int32 = 0
                    while waitpid(ownedPID, &exitStatus, 0) < 0 && errno == EINTR {}
                }
            }
            if writeFD >= 0 { close(writeFD); writeFD = -1 }
            if readFD >= 0 { close(readFD); readFD = -1 }; pid = 0
        }
    }

    private static func popFrame(_ buffer: inout Data) throws -> Data? {
        if let zero = buffer.firstIndex(of: 0) {
            guard zero - buffer.startIndex <= 262144, zero != buffer.startIndex else { throw Failure.protocolError }
            let frame = Data(buffer[..<zero]); buffer.removeSubrange(...zero); return frame
        }
        guard buffer.count <= 262144 else { throw Failure.protocolError }; return nil
    }
    private static let usageScript = #"""
    (async () => {
      if (location.origin !== "https://mcp.desktopcommander.app" || location.pathname !== "/usage") return "login";
      const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 12000);
      try {
        const response = await fetch("https://auth.desktopcommander.app/auth/billing/usage", {credentials:"include",redirect:"error",cache:"no-store",signal:controller.signal});
        if (response.status === 401 || response.status === 403) return "login";
        if (!response.ok) return "http-" + response.status;
        if (Number(response.headers.get("content-length") || 0) > 262144 || !response.body) return "invalid-response";
        const reader = response.body.getReader(); const chunks = []; let bytes = 0;
        while (true) { const part = await reader.read(); if (part.done) break; bytes += part.value.byteLength; if (bytes > 262144) { await reader.cancel(); return "invalid-response"; } chunks.push(part.value); }
        const raw = new Uint8Array(bytes); let offset = 0; for (const part of chunks) { raw.set(part, offset); offset += part.length; }
        let data; try { data = JSON.parse(new TextDecoder().decode(raw)); } catch (_) { return "invalid-response"; } const usage = data && data.usage;
        if (!usage || !Number.isSafeInteger(usage.callsUsed) || usage.callsUsed < 0 || usage.callsUsed > 1000000000 || typeof usage.plan !== "string" || usage.plan.length > 64 || !["free","pro"].includes(usage.plan.toLowerCase()) || (usage.month != null && (typeof usage.month !== "string" || !/^\d{4}-(0[1-9]|1[0-2])$/.test(usage.month))) || (usage.callsIncluded === null ? usage.plan.toLowerCase() !== "pro" : (!Number.isSafeInteger(usage.callsIncluded) || usage.callsIncluded <= 0 || usage.callsIncluded > 1000000000))) return "invalid-response";
        return JSON.stringify({usage:{callsUsed:usage.callsUsed,callsIncluded:usage.callsIncluded,plan:usage.plan,month:usage.month}});
      } catch (_) { return controller.signal.aborted ? "timeout" : "network"; } finally { clearTimeout(timer); }
    })()
    """#

    /// Optional diagnostic: only about:blank, no official endpoint or page/account inspection.
    static func runHeadlessProbe(chromeExecutable: URL) throws {
        let executable = try validateExecutable(chromeExecutable)
        let profile = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("CommanderGuard-headless-probe-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(profile.path, 0o700) == 0 else { throw Failure.profile }
        defer { try? FileManager.default.removeItem(at: profile) }
        try validateDirectory(profile, privateMode: true)
        let fd = try acquireProfile(profile)
        defer { flock(fd, LOCK_UN); close(fd) }
        for _ in 0..<2 {
            let browser = try PipeBrowser(executable: executable, profile: profile, cancelled: { false })
            do { try browser.probe() } catch { browser.finish(); throw error }
            browser.finish()
            guard !(try hasBrowserLock(profile)) else { throw Failure.profile }
        }
    }

    static func runOfflineChecks() throws {
        var buffer = Data("{\"id\":1}\u{0}{\"id\":2}".utf8)
        let first = try popFrame(&buffer); precondition(first == Data("{\"id\":1}".utf8))
        let partial = try popFrame(&buffer); precondition(partial == nil)
        buffer.append(0)
        let second = try popFrame(&buffer); precondition(second == Data("{\"id\":2}".utf8))
        for bad in [Data([0]), Data(repeating: 65, count: 262145)] {
            var bytes = bad
            do { _ = try popFrame(&bytes); preconditionFailure("invalid frame accepted") } catch Failure.protocolError {}
        }
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("CommanderGuard-quota-check-\(UUID().uuidString)")
        guard mkdir(scratch.path, 0o700) == 0 else { throw Failure.profile }
        defer { try? FileManager.default.removeItem(at: scratch) }
        try validateDirectory(scratch, privateMode: true)
        let firstLock = try acquireProfile(scratch)
        do { let extra = try acquireProfile(scratch); close(extra); preconditionFailure("concurrent profile lock accepted") } catch Failure.busy {}
        flock(firstLock, LOCK_UN); close(firstLock)
        let nextLock = try acquireProfile(scratch); flock(nextLock, LOCK_UN); close(nextLock)
        let link = scratch.appendingPathComponent("linked-profile")
        guard symlink(scratch.path, link.path) == 0 else { throw Failure.profile }
        do { try validateDirectory(link, privateMode: true); preconditionFailure("symlink profile accepted") } catch Failure.profile {}
        let publicDirectory = scratch.appendingPathComponent("public-profile")
        guard mkdir(publicDirectory.path, 0o755) == 0 else { throw Failure.profile }
        do { try validateDirectory(publicDirectory, privateMode: true); preconditionFailure("public profile accepted") } catch Failure.profile {}
        let login = HeadlessQuotaBrowser()
        precondition(!login.hasOwnedLogin && !login.finishOwnedLogin())
        let ownedLogin = Process(); ownedLogin.executableURL = URL(fileURLWithPath: "/bin/sleep"); ownedLogin.arguments = ["30"]
        try ownedLogin.run()
        login.loginProcess = ownedLogin
        precondition(login.hasOwnedLogin && login.finishOwnedLogin())
        ownedLogin.waitUntilExit(); login.loginProcess = nil
        precondition(!login.hasOwnedLogin && !login.finishOwnedLogin())
        let browserLock = scratch.appendingPathComponent("SingletonLock")
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run(); child.waitUntilExit()
        let exitedPID = child.processIdentifier
        guard kill(exitedPID, 0) == -1, errno == ESRCH else { throw Failure.unavailable }
        guard symlink("owned-host-\(exitedPID)", browserLock.path) == 0 else { throw Failure.profile }
        clearExitedOwnedBrowserLock(scratch, pid: getpid())
        let runningLockPreserved = try hasBrowserLock(scratch); precondition(runningLockPreserved, "running or mismatched PID lock must be preserved")
        clearExitedOwnedBrowserLock(scratch, pid: exitedPID)
        let ownedLockCleared = !(try hasBrowserLock(scratch)); precondition(ownedLockCleared, "known exited child lock must be cleared")
        guard symlink("unknown-host-999999", browserLock.path) == 0 else { throw Failure.profile }
        clearExitedOwnedBrowserLock(scratch, pid: exitedPID)
        let unknownLockPreserved = try hasBrowserLock(scratch); precondition(unknownLockPreserved, "unknown PID lock must be preserved")
        guard unlink(browserLock.path) == 0 else { throw Failure.profile }
        try Data().write(to: browserLock)
        clearExitedOwnedBrowserLock(scratch, pid: exitedPID)
        let fileLockPreserved = try hasBrowserLock(scratch); precondition(fileLockPreserved, "non-symlink lock must be preserved")
        guard unlink(browserLock.path) == 0 else { throw Failure.profile }
        let headless = arguments(profile: profileURL, headless: true)
        let visible = arguments(profile: profileURL, headless: false)
        precondition(headless.contains("--headless=new") && headless.contains("--remote-debugging-pipe"))
        precondition(!headless.contains(where: { $0.contains("remote-debugging-port") }))
        precondition(!visible.contains(where: { $0.contains("remote-debugging") || $0.contains("headless") }))
        precondition(headless[0] == "--user-data-dir=\(profileURL.path)" && visible.last == "--app=\(pageURL)")
        for invalid in [URL(string: "https://example.com/chrome")!, URL(fileURLWithPath: "/usr/bin/true")] {
            do { _ = try validateExecutable(invalid); preconditionFailure("unapproved executable accepted") } catch Failure.unavailable {}
        }
    }
}

struct Snapshot {
    var service = "未知"
    var cloud = "未知"
    var lastSeen: Date?
    var checked = Date()
    var errorCount = 0
    var message = ""
    var channelState = "启动宽限"
    var channelDetail = "等待 Commander 与日志完成启动"
    var channelFailures = 0
    var channelChecked: Date?
    var toolExecutionState = "未验证"
    var toolExecutionDetail = "尚未检查本机工具执行"
    var toolExecutionChecked: Date?
    var toolHistory = ToolHistorySummary()
    var activity = ActivitySummary()
    var timeline = TimelineSummary()
}

struct ActivitySummary {
    var state = "调用状态未确认（初次读取中）"
    var tool = ""
    var observed: Date?
    var observedUptime: TimeInterval? = nil
    var recent: [String] = []
    var steps: [ActivityStep] = []
    var active: [String: Int] = [:]
    var latestReceivedID: String?
    var returnedStepID: String?
    var error = false
    var coverageGap = false
    var gapReason = ""
    var gapFirstAt: Date?
    var gapLastAt: Date?
    var backlogBytes: UInt64 = 0
    var idleProven = false
    var pendingLine = false
    var catchingUp: Bool { backlogBytes > 0 }
    var activeCount: Int { active.values.reduce(0, +) }
    var title: String { error ? "读取异常" : (tool.isEmpty ? state : tool) }
}

struct ActivityStep {
    let id: String
    let tool: String
    var detail: String
    let startedAt: Date
    let startedUptime: TimeInterval
    var duration: TimeInterval?
    var uncertain = false
    var failed = false
    var historical = false
    var finished = false
    var sessionKey: String?
    var sessionSource: String?
    var sessionAttributionConflict = false
    func elapsed(at uptime: TimeInterval) -> TimeInterval? { uncertain || historical ? nil : duration ?? max(0, uptime - startedUptime) }
}

struct ToolHistoryRecord {
    let fingerprint: String
    let timestamp: Date
    let tool: String
    let duration: TimeInterval?
    let returned: Bool
    let failed: Bool
    var label: String { CommanderActivity.toolLabel(tool) }
    var resultLabel: String { failed ? "工具调用返回错误" : (returned ? "工具调用已返回" : "返回状态未知") }
    var cloudReceiptLabel: String { "云端结果接收未知" }
    var processCaveat: String? { tool == "start_process" && returned && !failed ? "调用已返回；后台进程仍可能运行" : nil }
}

struct ToolHistorySummary {
    var state = "尚未读取"
    var sourceAvailable = false
    var bootstrapLimited = false
    var coverageGap = false
    var gapReason = ""
    var malformedLines = 0
    var backlogBytes: UInt64 = 0
    var latest: ToolHistoryRecord?
    var recent: [ToolHistoryRecord] = []
}

func activityStepRows(_ steps: [ActivityStep], uptime: TimeInterval) -> [String] {
    let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"
    return steps.map { step in
        let symbol = step.historical && step.finished ? (step.failed ? "!" : "✓") : (step.uncertain ? "?" : (step.failed ? "!" : (step.finished || step.duration != nil ? "✓" : "●")))
        let duration = step.historical ? (step.finished ? "已返回 · 耗时未知" : "开始时间未知 · 状态未确认") : (step.uncertain ? "未确认" : (step.duration == nil ? "进行中 \(barCallClock(step, uptime: uptime))" : barCallClock(step, uptime: uptime)))
        let attribution = step.sessionAttributionConflict ? "归属冲突" : CommanderActivity.sessionDisplay(step.sessionKey)
        return "\(step.historical ? "时间未知" : clock.string(from: step.startedAt))  \(symbol)  \(attribution.map { "[\($0)]  " } ?? "")\(step.detail)  · \(duration)"
    }
}

func visibleTimelineEvents(_ events: [TimelineEvent]) -> [TimelineEvent] {
    events.filter { $0.source == "chatgpt_app" || $0.event.hasPrefix("Commander错误:") || $0.event.hasPrefix("调用error:") }
}

func groupedTimelineEvents(_ events: [TimelineEvent], window: TimeInterval = 1) -> [(TimelineEvent, Int)] {
    var groups: [(TimelineEvent, Int)] = []
    for event in events {
        let date = ISO8601DateFormatter.parse(event.sourceAt ?? event.observedAt)
        if let index = groups.indices.last,
           groups[index].0.source == event.source,
           groups[index].0.event == event.event,
           groups[index].0.conversationTitle == event.conversationTitle,
           groups[index].0.failureKind == event.failureKind,
           let priorDate = ISO8601DateFormatter.parse(groups[index].0.sourceAt ?? groups[index].0.observedAt),
           let date, abs(priorDate.timeIntervalSince(date)) <= window {
            groups[index].1 += 1
        } else { groups.append((event, 1)) }
    }
    return groups
}

func channelIncidentCategory(for event: TimelineEvent) -> ChannelIncidentCategory? {
    guard event.source == "commander" else { return nil }
    switch event.event {
    case "Commander错误: 云端实时服务连接池异常":
        return .cloudRealtimeCapacity
    case "Commander错误: 通道错误", "Commander错误: 通道订阅超时", "Commander错误: 通道关闭":
        return .channelDisruption
    default:
        return nil
    }
}

func isCommanderRemoteCallReceipt(_ event: TimelineEvent) -> Bool {
    event.source == "commander" && event.event.hasPrefix("调用receipt:")
}

func localRestartSuppressed(for category: ChannelIncidentCategory?) -> Bool {
    category == .cloudRealtimeCapacity
}

struct TimelineEvent: Codable {
    let source: String
    let event: String
    let sourceAt: String?
    let observedAt: String
    let conversationTitle: String?
    let failureKind: String?

    init(source: String, event: String, sourceAt: String?, observedAt: String, conversationTitle: String? = nil, failureKind: String? = nil) {
        self.source = source; self.event = event; self.sourceAt = sourceAt; self.observedAt = observedAt; self.conversationTitle = conversationTitle
        self.failureKind = failureKind
    }
}

struct TimelineSummary {
    var coverage = "初次读取中"
    var events: [TimelineEvent] = []
    var history: [TimelineEvent] = []
    var commanderErrors = 0
    var latestAppEvent: TimelineEvent?
    var latestAppIssue: TimelineEvent?
    var conversationLabelsVerifiedAt: String?
}

struct IncidentDiagnosis {
    let title: String
    let startedAt: Date?
    let lastSeenAt: Date?
    let nextAction: String
    let evidence: String

    static func make(timeline: TimelineSummary, activity: ActivitySummary, service: String = "未知", channelState: String = "未知", now: Date) -> IncidentDiagnosis {
        let retained = timeline.history + (timeline.latestAppIssue.map { [$0] } ?? [])
        var seen = Set<String>()
        let events = retained.filter { event in
            let key = "\(event.source)|\(event.event)|\(event.sourceAt ?? "")|\(event.observedAt)"
            return seen.insert(key).inserted
        }.compactMap { event -> (TimelineEvent, Date)? in
            let raw = event.source == "chatgpt_app" ? (event.sourceAt ?? event.observedAt) : event.observedAt
            guard let date = ISO8601DateFormatter.parse(raw), now.timeIntervalSince(date) >= 0 else { return nil }
            return (event, date)
        }
        let recent = events.filter { now.timeIntervalSince($0.1) <= 900 }
        let closeNames: Set<String> = ["chatgpt_pubsub_transport_closed", "chatgpt_pubsub_connection_failed", "chatgpt_pubsub_reconnect_scheduled", "chatgpt_pubsub_reconnect_exhausted"]
        let appDisruptions = recent.filter { $0.0.source == "chatgpt_app" && closeNames.contains($0.0.event.components(separatedBy: " · ").first ?? "") }
        let latestOpen = recent.filter { $0.0.source == "chatgpt_app" && $0.0.event == "chatgpt_pubsub_transport_opened" }.map(\.1).max()
        let closeEvents = appDisruptions.filter { $0.0.event == "chatgpt_pubsub_transport_closed" }
        let groupedCloses = groupedTimelineEvents(closeEvents.sorted { $0.1 < $1.1 }.map(\.0))
        let answerIssues = events.filter { event, _ in
            event.source == "chatgpt_app" && (event.event == "chatgpt_completion_transport_recovery_started" || event.event == "chatgpt_completion_transport_recovery_poll_failed" || event.event == "chatgpt_conversation_refetch_completed · error")
        }
        let currentChat = chatMonitorSummary(timeline)
        let unresolvedAnswerIssue = currentChat.answer == "回答异常（恢复未确认）"
        let appIssue = unresolvedAnswerIssue ? answerIssues.filter { now.timeIntervalSince($0.1) <= 900 }.max { $0.1 < $1.1 } : nil
        let oldAnswerIssue = unresolvedAnswerIssue ? answerIssues.max { $0.1 < $1.1 } : nil
        let appDisruption = appDisruptions.max { $0.1 < $1.1 }
        let commanderConnectivity = recent.filter { $0.0.source == "commander" && ["Commander错误: 通道错误", "Commander错误: 云端实时服务连接池异常", "Commander错误: 通道订阅超时", "Commander错误: 通道关闭"].contains($0.0.event) }
        let commanderIssue = recent.filter { $0.0.source == "commander" && ($0.0.event.hasPrefix("Commander错误:") || $0.0.event.hasPrefix("调用error:")) }.max { $0.1 < $1.1 }
        let appAt = appDisruption?.1
        let matchedCommander = appAt.flatMap { appDate in commanderConnectivity.filter { abs($0.1.timeIntervalSince(appDate)) <= 10 }.min { abs($0.1.timeIntervalSince(appDate)) < abs($1.1.timeIntervalSince(appDate)) } }
        let shared = appAt != nil && matchedCommander != nil
        let unknownActivity = activity.error || activity.coverageGap || activity.catchingUp || !activity.idleProven || activity.state.contains("未确认") || activity.state.contains("未知")
        let busyActivity = activity.activeCount > 0
        let coverageUnknown = ["缺失", "不可读", "缺口", "读取失败", "截断", "轮换", "队列已满", "追赶中", "初次读取"].contains { timeline.coverage.contains($0) }
        let reopened = latestOpen.map { open in appAt.map { open > $0 } ?? false } ?? false
        let serviceIssue = service == "未运行" || ["通道异常", "通道不可用", "恢复尚未确认"].contains(channelState)
        let title: String
        let action: String
        let evidence: String
        var relevantDates: [Date] = []
        if serviceIssue {
            title = service == "未运行" ? "Commander 服务当前未运行" : "Commander 命令通道检查异常"
            action = "查看本机服务与操作记录；确认调用状态后再决定下一步。"
            evidence = "ping 只检查本机命令通道响应；未验证实际工具执行或 ChatGPT 回答。"
        } else if shared {
            title = "App 与 Commander 连接近期同时异常"
            action = "先核对 ChatGPT 与 Commander 当前状态；如两端仍同时异常，再用独立网络工具排查网络。"
            evidence = "Commander 使用本机观察时间；时间接近只说明两端可能受共同环境影响，不证明网络、代理、隧道根因或会话归属。"
            relevantDates = [appAt, matchedCommander?.1].compactMap { $0 }
        } else if let appIssue {
            title = "ChatGPT 回答异常仍未确认恢复"
            action = "回到原对话确认回答状态；不要因 ping 或公开 HTTP 成功而重发。"
            evidence = "回答异常独立保留；通道 ping 只检查本机命令通道。"
            relevantDates = [appIssue.1]
        } else if let appDisruption {
            title = "ChatGPT 更新连接近期中断" + (groupedCloses.count > 1 ? " · 近15分钟 \(groupedCloses.count) 个关闭时段" : "") + (reopened ? "，之后观察到重新连接" : "")
            action = "回到 ChatGPT App 检查连接，并确认原回答状态。"
            evidence = "重新连接不证明回答恢复；这是 App 事件，不等同于 Commander ping。"
            relevantDates = closeEvents.map(\.1)
            if relevantDates.isEmpty { relevantDates = [appDisruption.1] }
            if reopened, let latestOpen { relevantDates.append(latestOpen) }
        } else if let commanderIssue {
            title = commanderIssue.0.event.hasPrefix("调用error:") ? "Commander 本机操作近期出现异常" : "Commander 连接近期出现异常"
            action = unknownActivity || busyActivity ? "先查看操作记录并确认本机调用状态；当前不建议重启或重试。" : "查看对应本机操作记录，确认结果后再继续。"
            evidence = "Commander 时间是本机观察时间；记录不证明云端完成。"
            relevantDates = [commanderIssue.1]
        } else if coverageUnknown {
            title = "诊断覆盖存在缺口"
            action = "先确认日志重新可读，再查看原对话与本机操作记录。"
            evidence = "日志缺失或覆盖缺口不能证明当前连接或回答正常。"
            relevantDates = activity.coverageGap ? [activity.gapFirstAt, activity.gapLastAt].compactMap { $0 } : []
        } else if let oldAnswerIssue {
            title = "较早的 ChatGPT 回答异常仍未确认"
            action = "回到原对话确认回答状态；近期 ping 不会清除此异常。"
            evidence = "回答异常独立保留；通道 ping 只检查本机命令通道。"
            relevantDates = [oldAnswerIssue.1]
        } else if busyActivity {
            title = "本机调用进行中"
            action = "等待当前调用返回，再查看操作记录确认结果。"
            evidence = "本机调用仍在进行；当前不建议重启或重试。"
            relevantDates = []
        } else if unknownActivity {
            title = "本机调用状态未确认"
            action = "先查看操作记录并等待日志状态明确；当前不建议重启或重试。"
            evidence = "日志缺口、活动调用或未知状态不能当作空闲。"
            relevantDates = []
        } else {
            title = "当前没有可操作的近期异常"
            action = "如仍有问题，检查原对话中的回答与本机操作记录。"
            evidence = "ping 成功仅代表该次本机命令通道探测往返，不验证 ChatGPT 回答或工具执行。"
            relevantDates = []
        }
        return IncidentDiagnosis(title: title, startedAt: relevantDates.min(), lastSeenAt: relevantDates.max(), nextAction: action, evidence: evidence)
    }
}


/// Safe, passive summary for fixed ChatGPT App events already sanitized by TimelineReader.
/// Never accepts or retains URLs, conversation IDs, message bodies, or raw errors.
struct ChatMonitorEvidence {
    let kind: String
    let observedAt: String
    let outcome: String? // accepted only as one of TimelineReader’s fixed refetch statuses
    let failureKind: String? // fixed classification; never a raw App error
}

struct ChatMonitorSummary {
    let answer: String
    let connection: String
    let history: String?
    let deliveryLimit = "Message delivery timed out 没有可读的专属结构化事件；响应恢复尝试只是前兆，不代表该提示已出现"

    var menuLine: String { "ChatGPT：" + (answer.components(separatedBy: "；").first ?? answer) }
}

func chatMonitorSummary(events: [ChatMonitorEvidence], timelineCoverage: String) -> ChatMonitorSummary {
    let unreadable = timelineCoverage.contains("初次读取") ||
        timelineCoverage.hasPrefix("日志缺失") ||
        timelineCoverage.contains("App 日志缺失") ||
        timelineCoverage.contains("覆盖有缺口") ||
        timelineCoverage.contains("时间线有缺口") ||
        timelineCoverage.contains("时间线保存失败")
    let date: (ChatMonitorEvidence) -> Date? = { ISO8601DateFormatter.parse($0.observedAt) }
    let newer: (ChatMonitorEvidence, ChatMonitorEvidence) -> Bool = { lhs, rhs in
        guard let ld = date(lhs), let rd = date(rhs) else { return lhs.observedAt > rhs.observedAt }
        return ld > rd
    }
    let stamp: (String) -> String = { raw in
        guard let parsed = ISO8601DateFormatter.parse(raw) else { return "时间未知" }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: parsed)
    }
    let issueEvents = events.filter {
        $0.kind == "chatgpt_completion_transport_recovery_started" ||
        $0.kind == "chatgpt_completion_transport_recovery_poll_failed" ||
        ($0.kind == "chatgpt_conversation_refetch_completed" && $0.outcome == "error")
    }
    let latestIssue = issueEvents.max(by: { newer($1, $0) })

    let recoveryEvents = events.filter {
        $0.kind == "chatgpt_completion_transport_recovery_completed" ||
        $0.kind == "chatgpt_pubsub_transport_opened" ||
        ($0.kind == "chatgpt_conversation_refetch_completed" && ["idle", "streaming"].contains($0.outcome ?? ""))
    }

    let significantKinds: Set<String> = [
        "chatgpt_completion_transport_recovery_started",
        "chatgpt_completion_transport_recovery_poll_failed",
        "chatgpt_completion_transport_recovery_completed",
        "chatgpt_conversation_refetch_completed",
        "chatgpt_pubsub_reconnect_exhausted",
        "chatgpt_pubsub_connection_failed",
        "chatgpt_pubsub_transport_closed",
        "chatgpt_pubsub_reconnect_scheduled",
        "chatgpt_pubsub_transport_opened"
    ]
    let latestSignificant = events.filter { significantKinds.contains($0.kind) }.max(by: { newer($1, $0) })

    let answer: String
    if unreadable {
        answer = "状态未知"
    } else if let latest = latestSignificant {
        switch latest.kind {
        case "chatgpt_completion_transport_recovery_started",
             "chatgpt_completion_transport_recovery_poll_failed":
            answer = "回答异常（恢复未确认）"
        case "chatgpt_conversation_refetch_completed" where latest.outcome == "error":
            answer = "回答异常（恢复未确认）"
        case "chatgpt_pubsub_reconnect_exhausted",
             "chatgpt_pubsub_connection_failed",
             "chatgpt_pubsub_transport_closed",
             "chatgpt_pubsub_reconnect_scheduled":
            answer = "连接异常"
        case "chatgpt_completion_transport_recovery_completed":
            answer = "回答恢复已记录"
        case "chatgpt_pubsub_transport_opened":
            answer = "当前连接正常"
        case "chatgpt_conversation_refetch_completed" where ["idle", "streaming"].contains(latest.outcome ?? ""):
            answer = "当前连接正常"
        default:
            answer = "当前未见异常"
        }
    } else {
        answer = "当前未见异常"
    }

    let history: String?
    if let issue = latestIssue {
        let laterRecovery = recoveryEvents.filter { candidate in
            guard let issueDate = date(issue), let candidateDate = date(candidate) else { return candidate.observedAt > issue.observedAt }
            return candidateDate > issueDate
        }.max(by: { newer($1, $0) })
        if let laterRecovery, laterRecovery.kind == "chatgpt_completion_transport_recovery_completed" {
            history = "后续已记录回答恢复完成"
        } else if laterRecovery != nil {
            history = "后续连接已恢复；原中断回答是否完整恢复无法从日志确认"
        } else {
            history = "恢复情况未确认"
        }
    } else {
        history = nil
    }

    let connectionEvents = events.filter {
        ["chatgpt_pubsub_reconnect_exhausted", "chatgpt_pubsub_connection_failed", "chatgpt_pubsub_transport_closed", "chatgpt_pubsub_reconnect_scheduled", "chatgpt_pubsub_transport_opened"].contains($0.kind)
    }
    let connection: String
    if let latest = connectionEvents.max(by: { newer($1, $0) }) {
        let detail: String
        switch latest.kind {
        case "chatgpt_pubsub_reconnect_exhausted": detail = "更新连接重连已耗尽"
        case "chatgpt_pubsub_connection_failed": detail = "更新连接失败"
        case "chatgpt_pubsub_transport_closed": detail = "更新连接已关闭"
        case "chatgpt_pubsub_reconnect_scheduled": detail = "更新连接准备重连"
        default: detail = "更新连接已建立"
        }
        connection = "\(detail) · \(stamp(latest.observedAt))"
    } else if unreadable {
        connection = "连接状态未知（日志不可读或有缺口）"
    } else {
        connection = "暂无可识别的连接异常"
    }
    return ChatMonitorSummary(answer: answer, connection: connection, history: history)
}


func chatMonitorSummary(_ timeline: TimelineSummary) -> ChatMonitorSummary {
    let retained = timeline.history + (timeline.latestAppIssue.map { [$0] } ?? [])
    let evidence = retained.filter { $0.source == "chatgpt_app" }.map { event -> ChatMonitorEvidence in
        let parts = event.event.components(separatedBy: " · ")
        return ChatMonitorEvidence(kind: parts[0], observedAt: event.sourceAt ?? event.observedAt, outcome: parts.count > 1 ? parts[1] : nil, failureKind: event.failureKind)
    }
    return chatMonitorSummary(events: evidence, timelineCoverage: timeline.coverage)
}

struct ConversationLabelCatalog {
    private struct Document: Decodable { let verified_at: String; let labels: [String: String] }
    private let labels: [String: String]
    let verifiedAt: String?
    private let conversationID = try! NSRegularExpression(pattern: #"(?:^|\s)conversationId=([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?=\s|$)"#)

    init(fileURL: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber,
              size.intValue <= 64 * 1024,
              let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              ISO8601DateFormatter.parse(document.verified_at) != nil else {
            labels = [:]; verifiedAt = nil; return
        }
        labels = Self.validated(document.labels)
        verifiedAt = document.verified_at
    }

    func title(in record: String) -> String? {
        let range = NSRange(record.startIndex..., in: record)
        let matches = conversationID.matches(in: record, range: range)
        guard matches.count == 1, let match = matches.first,
              let idRange = Range(match.range(at: 1), in: record) else { return nil }
        return labels[Self.digest(for: String(record[idRange]))]
    }

    static func digest(for conversationID: String) -> String {
        SHA256.hash(data: Data(conversationID.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidTitle(_ title: String) -> Bool {
        !title.isEmpty && title.count <= 100 && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func validated(_ labels: [String: String]) -> [String: String] {
        labels.reduce(into: [:]) { result, pair in
            guard pair.key.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  Self.isValidTitle(pair.value) else { return }
            result[pair.key] = pair.value
        }
    }
}

func appEventLabel(_ event: TimelineEvent) -> String {
    let parts = event.event.components(separatedBy: " · ")
    let name = parts.first ?? ""
    let title = event.conversationTitle ?? "对话名称未识别"
    switch name {
    case "chatgpt_pubsub_transport_closed": return "更新连接已关闭"
    case "chatgpt_pubsub_transport_opened": return "更新连接已建立"
    case "chatgpt_pubsub_reconnect_scheduled": return "更新连接准备重连"
    case "chatgpt_pubsub_reconnect_exhausted": return "更新连接重连已耗尽；可回到 App 尝试恢复"
    case "chatgpt_completion_transport_recovery_completed": return "\(title) · 已记录回答恢复完成（其他异常仍需确认）"
    case "chatgpt_completion_transport_recovery_poll_failed": return "\(title) · 回答恢复检查失败"
    case "chatgpt_pubsub_connection_failed": return "更新连接失败"
    case "chatgpt_completion_transport_recovery_started": return "\(title) · \(event.failureKind == "resume_unavailable" ? "恢复流不可用" : "响应恢复尝试")"
    case "chatgpt_conversation_refetch_started": return "\(title) · 对话状态开始刷新"
    case "chatgpt_conversation_refetch_completed":
        let outcome = parts.count > 1 ? parts[1] : ""
        if outcome == "error" { return "\(title) · 对话状态刷新失败" }
        let status = ["streaming": "界面响应中", "idle": "界面空闲"][outcome] ?? "状态未确认"
        return "\(title) · 对话状态刷新（\(status)）"
    default: return "未知 App 事件"
    }
}

func conversationLabelNote(_ verifiedAt: String?) -> String {
    guard let verifiedAt else { return "会话名称未核对；Commander 调用归属未确认。" }
    let localTime = ISO8601DateFormatter.parse(verifiedAt).map { date -> String in
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm"; return formatter.string(from: date)
    } ?? "未知"
    return "会话名录核对于 \(localTime)；Commander 调用归属未确认。"
}

// Examine only the bounded structured error field; never persist its payload.
func appRecoveryFailure(_ fields: String) -> String? {
    guard let start = fields.range(of: #"(?:^|\s)error="#, options: .regularExpression)?.upperBound,
          fields[start...].first == "{" else { return nil }
    var depth = 0, quoted = false, escaped = false
    for index in fields[start...].indices {
        let character = fields[index]
        if quoted {
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" { quoted = false }
        } else if character == "\"" { quoted = true }
        else if character == "{" { depth += 1 }
        else if character == "}" {
            depth -= 1
            if depth == 0 {
                let bytes = Data(fields[start...index].utf8)
                guard let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                      object["type"] as? String == "fetch-stream-error", object["responseStatus"] as? Int == 404,
                      let body = object["error"] as? String,
                      let detail = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
                      detail["detail"] as? String == "Resume stream unavailable" else { return nil }
                return "resume_unavailable"
            }
        }
    }
    return nil
}

/// Passively tails only anchored Commander records and fixed ChatGPT App events.
final class TimelineReader {
    private struct Cursor { var offset: UInt64; var inode: UInt64? }
    private let appRoot: URL
    private let commanderLog: URL
    private let commanderErrorLog: URL?
    private let journal: URL
    private let conversationLabels: ConversationLabelCatalog
    private var cursors: [String: Cursor] = [:]
    private var partial: [String: Data] = [:]
    private var discarding: [String: Bool] = [:]
    private var coverageGap = false
    private var appLogsMissing = true
    private var initialPollComplete = false
    private var events: [TimelineEvent] = []
    private var pending: [TimelineEvent] = []
    private var pendingBytes = 0
    private var commanderErrors = 0
    private var latestAppEvent: TimelineEvent?
    private var latestAppIssue: TimelineEvent?
    private var coverage = "初次读取中"
    private let maxRead = 64 * 1024
    private let maxLine = 8 * 1024
    private let maxJournal = 1024 * 1024
    private let appLine = try! NSRegularExpression(pattern: #"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z) (?:info|warning|error) \[electron-message-handler\] (chatgpt_[a-z_]+)(?: (.*))?$"#)

    init(appRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/com.openai.codex"), commanderLog: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RemoteDesktopCommander/stdout.log"), commanderErrorLog: URL? = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RemoteDesktopCommander/stderr.log"), journal: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CommanderGuard/timeline.jsonl"), conversationLabelsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CommanderGuard/conversation-labels.json")) {
        self.appRoot = appRoot; self.commanderLog = commanderLog; self.commanderErrorLog = commanderErrorLog; self.journal = journal
        self.conversationLabels = ConversationLabelCatalog(fileURL: conversationLabelsURL)
        loadJournal()
    }

    var summary: TimelineSummary { TimelineSummary(coverage: coverage, events: Array(events.suffix(12)), history: Array(events.suffix(500)), commanderErrors: commanderErrors, latestAppEvent: latestAppEvent, latestAppIssue: latestAppIssue, conversationLabelsVerifiedAt: conversationLabels.verifiedAt) }

    func poll(now: Date = Date()) {
        var found = false
        let manager = FileManager.default
        let years = (try? manager.contentsOfDirectory(at: appRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var dates: [URL] = []
        for year in years {
            for month in (try? manager.contentsOfDirectory(at: year, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                dates.append(contentsOf: (try? manager.contentsOfDirectory(at: month, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            }
        }
        let latestDates = dates.sorted { $0.path > $1.path }.prefix(3)
        var appFiles: [(url: URL, modified: Date)] = []
        for day in latestDates {
            for file in (try? manager.contentsOfDirectory(at: day, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [] where file.pathExtension == "log" {
                appFiles.append((file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
            }
        }
        let logs = appFiles.sorted { $0.modified > $1.modified }.prefix(8).map { $0.url }
        appLogsMissing = logs.isEmpty
        if !logs.isEmpty { found = true }
        for url in logs { tail(url, source: "chatgpt_app", now: now) }
        let commanderMissing = !manager.fileExists(atPath: commanderLog.path)
        if !commanderMissing { found = true; tail(commanderLog, source: "commander", now: now) }
        if let commanderErrorLog, manager.fileExists(atPath: commanderErrorLog.path) { found = true; tail(commanderErrorLog, source: "commander_stderr", now: now) }
        let activePaths = Set(logs.map { $0.path } + [commanderLog.path] + (commanderErrorLog.map { [$0.path] } ?? []))
        cursors = cursors.filter { activePaths.contains($0.key) }; partial = partial.filter { activePaths.contains($0.key) }; discarding = discarding.filter { activePaths.contains($0.key) }
        if !found { coverage = "日志缺失 · Commander 调用归属未确认" }
        else if appLogsMissing { coverage = "App 日志缺失 · Commander 调用归属未确认" }
        else if commanderMissing { coverage = "Commander stdout 日志缺失 · Commander 调用归属未确认" }
        else if let commanderErrorLog, !manager.fileExists(atPath: commanderErrorLog.path) { coverage = "Commander 错误日志缺失 · 调用归属未确认" }
        else if !coverageGap {
            let catchingUp = logs.contains { url in
                guard let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value, let cursor = cursors[url.path] else { return true }
                return size > cursor.offset
            }
            coverage = catchingUp ? "App 日志追赶中 · Commander 调用归属未确认" : "已覆盖当前日志 · Commander 调用归属未确认"
        }
        initialPollComplete = true
        saveIfNeeded()
    }

    private func tail(_ url: URL, source: String, now: Date) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attributes[.size] as? UInt64 else { coverageGap = true; coverage = "日志不可读 · 覆盖有缺口"; return }
        let key = url.path
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        var cursor = cursors[key]
        if cursor == nil {
            let offset = source == "chatgpt_app" ? (size > 2 * 1024 * 1024 ? size - 2 * 1024 * 1024 : 0) : size
            if initialPollComplete && offset > 0 { coverageGap = true; coverage = "新日志路径跳过了旧记录 · 覆盖有缺口" }
            cursor = Cursor(offset: offset, inode: inode); cursors[key] = cursor; partial[key] = Data()
            discarding[key] = source == "chatgpt_app" && offset > 0
            if offset == size { return }
        }
        if cursor!.inode != inode || size < cursor!.offset { coverageGap = true; coverage = "日志轮换或截断 · 覆盖有缺口"; cursors[key] = Cursor(offset: size, inode: inode); partial[key] = Data(); discarding[key] = false; return }
        guard size > cursor!.offset else { return }
        let count = Int(min(UInt64(maxRead), size - cursor!.offset))
        guard let handle = try? FileHandle(forReadingFrom: url) else { coverageGap = true; coverage = "日志不可读 · 覆盖有缺口"; return }
        do { try handle.seek(toOffset: cursor!.offset) } catch { try? handle.close(); coverageGap = true; coverage = "日志读取失败 · 覆盖有缺口"; return }
        guard let data = try? handle.read(upToCount: count) else { try? handle.close(); coverageGap = true; coverage = "日志读取失败 · 覆盖有缺口"; return }
        try? handle.close()
        guard !data.isEmpty else { coverageGap = true; coverage = "日志读取失败 · 覆盖有缺口"; return }
        cursor!.offset += UInt64(data.count); cursors[key] = cursor
        consume(data, key: key, source: source, now: now)
    }

    private func consume(_ data: Data, key: String, source: String, now: Date) {
        var line = partial[key] ?? Data(), dropping = discarding[key] ?? false
        for byte in data {
            if byte == 10 { parse(line, source: source, now: now); line.removeAll(keepingCapacity: true); dropping = false }
            else if !dropping {
                if line.count < maxLine { line.append(byte) }
                else {
                    if source == "chatgpt_app" {
                        let prefix = String(decoding: line, as: UTF8.self)
                        if appLine.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) != nil {
                            coverageGap = true; coverage = "App 事件过长 · 覆盖有缺口"
                        }
                    }
                    dropping = true
                }
            }
        }
        partial[key] = line; discarding[key] = dropping
    }

    private func parse(_ bytes: Data, source: String, now: Date) {
        let line = String(decoding: bytes, as: UTF8.self)
        if source == "commander" || source == "commander_stderr" {
            if source == "commander", let parsed = CommanderActivity.parse(Data(line.utf8)) {
                let type = parsed.2 == "received" ? "receipt" : (parsed.2 == "failed" ? "error" : "completion")
                append(TimelineEvent(source: source, event: "调用\(type): \(CommanderActivity.tools[parsed.1] ?? "本机操作")", sourceAt: nil, observedAt: ISO8601DateFormatter.flex.string(from: now)))
                return
            }
            if line.hasPrefix("❌ Channel error:"),
               line.contains("IncreaseConnectionPool: Please increase your connection pool size") {
                append(TimelineEvent(source: "commander", event: "Commander错误: 云端实时服务连接池异常", sourceAt: nil, observedAt: ISO8601DateFormatter.flex.string(from: now)))
                return
            }
            let errors = [("[DEBUG] Failed to update call result:", "Commander错误: 回传结果写入失败"), ("[DEBUG] Failed to update transport capability:", "Commander错误: 通道能力写入失败"), ("[DEBUG] Failed to mark call executing:", "Commander错误: 调用认领失败"), ("[DEBUG] Doorbell claim attempt failed for ", "Commander错误: 调用认领失败"), ("[DEBUG] Heartbeat update failed:", "Commander错误: 心跳写入失败"), ("Heartbeat failed:", "Commander错误: 心跳失败"), ("[DEBUG] Manual token refresh failed:", "Commander错误: 认证刷新失败"), ("[DEBUG] Manual token refresh threw:", "Commander错误: 认证刷新异常"), ("❌ Channel error:", "Commander错误: 通道错误"), ("⏱️ Channel subscription timed out,", "Commander错误: 通道订阅超时"), ("⚠️ Channel closed —", "Commander错误: 通道关闭"), ("[DEBUG] Tool call handler rejected:", "Commander错误: 调用处理器拒绝"), ("[DEBUG] Tool call handler threw:", "Commander错误: 调用处理器异常"), ("❌ Could not report failure for ", "Commander错误: 失败结果报告失败")]
            if let (_, label) = errors.first(where: { line.hasPrefix($0.0) }) { append(TimelineEvent(source: "commander", event: label, sourceAt: nil, observedAt: ISO8601DateFormatter.flex.string(from: now))) }
            return
        }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = appLine.firstMatch(in: line, range: range), let nameRange = Range(match.range(at: 2), in: line), let dateRange = Range(match.range(at: 1), in: line) else { return }
        let name = String(line[nameRange])
        let allowed = ["chatgpt_pubsub_transport_closed", "chatgpt_pubsub_transport_opened", "chatgpt_pubsub_reconnect_scheduled", "chatgpt_pubsub_connection_failed", "chatgpt_pubsub_reconnect_exhausted", "chatgpt_completion_transport_recovery_completed", "chatgpt_completion_transport_recovery_poll_failed", "chatgpt_completion_transport_recovery_started", "chatgpt_conversation_refetch_started", "chatgpt_conversation_refetch_completed"]
        guard allowed.contains(name) else { return }
        var label = name
        let rest = Range(match.range(at: 3), in: line).map { String(line[$0]) } ?? ""
        if name == "chatgpt_conversation_refetch_completed" {
            guard let status = rest.split(separator: " ").first(where: { $0.hasPrefix("statusAfter=") }).map({ String($0.dropFirst("statusAfter=".count)) }), ["streaming", "error", "idle"].contains(status) else { return }
            label += " · \(status)"
        }
        let title = ["chatgpt_completion_transport_recovery_completed", "chatgpt_completion_transport_recovery_poll_failed", "chatgpt_completion_transport_recovery_started", "chatgpt_conversation_refetch_started", "chatgpt_conversation_refetch_completed"].contains(name) ? conversationLabels.title(in: rest) : nil
        let failureKind = name == "chatgpt_completion_transport_recovery_started" ? appRecoveryFailure(rest) : nil
        append(TimelineEvent(source: source, event: label, sourceAt: String(line[dateRange]), observedAt: ISO8601DateFormatter.flex.string(from: now), conversationTitle: title, failureKind: failureKind))
    }

    private func append(_ event: TimelineEvent) {
        if event.source == "chatgpt_app", events.contains(where: { $0.source == event.source && $0.sourceAt == event.sourceAt && $0.event == event.event && $0.failureKind == event.failureKind && $0.conversationTitle == event.conversationTitle }) { return }
        events.append(event)
        if let row = try? JSONEncoder().encode(event), pendingBytes + row.count + 1 <= maxJournal / 2 { pending.append(event); pendingBytes += row.count + 1 }
        else { coverageGap = true; coverage = "时间线有缺口 · 保存队列已满" }
        if event.source == "commander" && (event.event.contains("错误") || event.event.contains("error")) { commanderErrors += 1 }
        if event.source == "chatgpt_app" {
            let stamp = event.sourceAt ?? event.observedAt
            if latestAppEvent == nil || stamp > (latestAppEvent!.sourceAt ?? latestAppEvent!.observedAt) {
                latestAppEvent = event
            }
        }
        rememberAppIssue(event)
        if events.count > 5000 { events.removeFirst(events.count - 5000) }
    }

    private func rememberAppIssue(_ event: TimelineEvent) {
        guard event.source == "chatgpt_app", event.event == "chatgpt_completion_transport_recovery_started" || event.event == "chatgpt_completion_transport_recovery_poll_failed" || event.event == "chatgpt_conversation_refetch_completed · error" else { return }
        let stamp = event.sourceAt ?? event.observedAt
        if latestAppIssue == nil || stamp > (latestAppIssue!.sourceAt ?? latestAppIssue!.observedAt) || (stamp == (latestAppIssue!.sourceAt ?? latestAppIssue!.observedAt) && event.failureKind != nil) { latestAppIssue = event }
    }

    private func valid(_ event: TimelineEvent) -> Bool {
        guard ISO8601DateFormatter.parse(event.observedAt) != nil else { return false }
        guard event.failureKind == nil || (event.source == "chatgpt_app" && event.event == "chatgpt_completion_transport_recovery_started" && event.failureKind == "resume_unavailable") else { return false }
        if event.source == "commander" {
            guard event.conversationTitle == nil else { return false }
            if event.event.hasPrefix("Commander错误: ") { return event.sourceAt == nil && Set(["回传结果写入失败", "通道能力写入失败", "调用认领失败", "心跳写入失败", "心跳失败", "认证刷新失败", "认证刷新异常", "通道错误", "云端实时服务连接池异常", "通道订阅超时", "通道关闭", "调用处理器拒绝", "调用处理器异常", "失败结果报告失败"]).contains(String(event.event.dropFirst("Commander错误: ".count))) }
            guard event.sourceAt == nil, let colon = event.event.range(of: ": ") else { return false }
            let kind = String(event.event[..<colon.lowerBound]), tool = String(event.event[colon.upperBound...])
            return ["调用receipt", "调用completion", "调用error"].contains(kind) && Set(CommanderActivity.tools.values).contains(tool)
        }
        guard event.source == "chatgpt_app", let stamp = event.sourceAt, ISO8601DateFormatter.parse(stamp) != nil else { return false }
        let parts = event.event.components(separatedBy: " · ")
        let allNames: Set<String> = ["chatgpt_pubsub_transport_closed", "chatgpt_pubsub_transport_opened", "chatgpt_pubsub_reconnect_scheduled", "chatgpt_pubsub_connection_failed", "chatgpt_pubsub_reconnect_exhausted", "chatgpt_completion_transport_recovery_completed", "chatgpt_completion_transport_recovery_poll_failed", "chatgpt_completion_transport_recovery_started", "chatgpt_conversation_refetch_started", "chatgpt_conversation_refetch_completed"]
        guard let name = parts.first, allNames.contains(name) else { return false }
        let canHaveTitle = ["chatgpt_completion_transport_recovery_completed", "chatgpt_completion_transport_recovery_poll_failed", "chatgpt_completion_transport_recovery_started", "chatgpt_conversation_refetch_started", "chatgpt_conversation_refetch_completed"].contains(name)
        guard event.conversationTitle.map(ConversationLabelCatalog.isValidTitle) ?? true,
              canHaveTitle || event.conversationTitle == nil else { return false }
        return name == "chatgpt_conversation_refetch_completed" ? (parts.count == 2 && ["streaming", "error", "idle"].contains(parts[1])) : parts.count == 1
    }

    private func loadJournal() {
        let manager = FileManager.default
        for file in [journal.appendingPathExtension("bak"), journal] {
            guard let size = try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber, size.intValue <= maxJournal, let data = try? Data(contentsOf: file) else { continue }
            for line in data.split(separator: 10).suffix(2500) {
                if let event = try? JSONDecoder().decode(TimelineEvent.self, from: Data(line)), valid(event) {
                    events.append(event)
                    if event.source == "chatgpt_app" {
                        let stamp = event.sourceAt ?? event.observedAt
                        if latestAppEvent == nil || stamp > (latestAppEvent!.sourceAt ?? latestAppEvent!.observedAt) {
                            latestAppEvent = event
                        }
                    }
                    rememberAppIssue(event)
                }
            }
        }
        if events.count > 5000 { events = Array(events.suffix(5000)) }
    }

    private func saveIfNeeded() {
        // Flush only sanitized records accumulated since the last successful save.
        guard !pending.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try pending.map { try JSONEncoder().encode($0) + Data([10]) }.reduce(into: Data()) { $0.append($1) }
            if let size = try? FileManager.default.attributesOfItem(atPath: journal.path)[.size] as? NSNumber, size.intValue + data.count > maxJournal {
                let backup = journal.appendingPathExtension("bak"); try? FileManager.default.removeItem(at: backup)
                if size.intValue <= maxJournal { try FileManager.default.moveItem(at: journal, to: backup); _ = chmod(backup.path, S_IRUSR | S_IWUSR) }
                else { try? FileManager.default.removeItem(at: journal); coverageGap = true }
            }
            if FileManager.default.fileExists(atPath: journal.path) { let f = try FileHandle(forWritingTo: journal); try f.seekToEnd(); try f.write(contentsOf: data); try f.close() }
            else { try data.write(to: journal, options: .atomic) }
            _ = chmod(journal.path, S_IRUSR | S_IWUSR)
            pending.removeAll(keepingCapacity: true)
            pendingBytes = 0
        } catch { coverageGap = true; coverage = "时间线保存失败 · 覆盖有缺口" }
    }
}

func barCallClock(_ step: ActivityStep?, uptime: TimeInterval) -> String {
    guard let step else { return "待调用" }
    guard let elapsed = step.elapsed(at: uptime) else { return "耗时未确认" }
    return elapsed < 1 ? "<1 秒" : "\(Int(elapsed)) 秒"
}

func currentCallStep(_ activity: ActivitySummary) -> ActivityStep? {
    guard activity.activeCount > 0, !activity.error, !activity.state.contains("调用状态未确认"), !activity.state.contains("日志读取异常"), !activity.state.contains("状态未知") else { return nil }
    return activity.steps.first { activity.active[$0.tool, default: 0] > 0 && !$0.finished && $0.duration == nil }
}

func recentlyReturnedCall(_ activity: ActivitySummary, uptime: TimeInterval) -> ActivityStep? {
    guard activity.activeCount == 0, !activity.error,
          activity.state == "本机已返回（云端结果未知）",
          let observed = activity.observedUptime, observed.isFinite,
          (uptime - observed).isFinite, uptime >= observed, uptime - observed < 3,
          let step = activity.steps.first(where: {
              guard $0.id == activity.returnedStepID, !$0.uncertain,
                    let duration = $0.duration, duration.isFinite, duration >= 0,
                    $0.startedUptime.isFinite else { return false }
              return abs(duration - (observed - $0.startedUptime)) < 0.001
          }) else { return nil }
    return step
}

func callState(_ activity: ActivitySummary) -> String {
    if activity.activeCount > 0 {
        guard let step = currentCallStep(activity) else { return "状态未确认" }
        return step.uncertain ? "耗时未确认" : "等待返回"
    }
    let uncertain = !activity.idleProven || activity.error || activity.coverageGap || activity.catchingUp || activity.state.contains("调用状态未确认") || activity.state.contains("日志读取异常") || activity.state.contains("状态未知")
    return uncertain ? "状态未确认" : "未观察到新调用"
}

func activitySafeForRecovery(_ activity: ActivitySummary) -> Bool {
    activity.idleProven && !activity.error && !activity.coverageGap && !activity.catchingUp && activity.activeCount == 0 &&
    !activity.state.contains("未确认") && !activity.state.contains("状态未知") &&
    !activity.state.contains("日志有间隔") && !activity.state.contains("读取异常") && !activity.state.contains("读取中断")
}

let toolExecutionEvidenceTTL: TimeInterval = 120

func recentSuccessfulToolExecution(_ activity: ActivitySummary, now: Date, maxAge: TimeInterval = toolExecutionEvidenceTTL) -> Date? {
    activity.steps.compactMap { step -> Date? in
        guard step.finished, !step.failed, !step.uncertain, !step.historical,
              step.tool != "ping", step.tool != "list_sessions",
              let duration = step.duration, duration.isFinite, duration >= 0 else { return nil }
        let finishedAt = step.startedAt.addingTimeInterval(duration)
        let age = now.timeIntervalSince(finishedAt)
        return age >= 0 && age <= maxAge ? finishedAt : nil
    }.max()
}

func toolExecutionFresh(_ snapshot: Snapshot, now: Date, maxAge: TimeInterval = toolExecutionEvidenceTTL) -> Bool {
    guard snapshot.toolExecutionState == "已验证", let checked = snapshot.toolExecutionChecked else { return false }
    let age = now.timeIntervalSince(checked)
    return age >= 0 && age <= maxAge
}

func actualProbeTimestamp(submitted: Bool, at date: Date) -> String? { submitted ? ISO8601DateFormatter.flex.string(from: date) : nil }

func recoveryConfirmed(oldPID: Int32, newPID: Int32?, currentPID: Int32?, oldProcessExited: Bool, probe: ChannelProbeResult) -> Bool {
    guard let newPID, oldPID > 0, newPID > 0, newPID != oldPID, currentPID == newPID, oldProcessExited else { return false }
    if case .healthy = probe { return true }
    return false
}

func channelIndicator(service: String, state: String, checked: Date?, now: Date) -> String {
    if service == "未运行" || state == "通道异常" || state == "通道不可用" { return "!" }
    guard service == "运行中", let checked, now.timeIntervalSince(checked) >= 0, now.timeIntervalSince(checked) <= 75 else { return "?" }
    return state == "通道畅通" || state == "通道已恢复" ? "●" : "?"
}

func channelSummary(_ snapshot: Snapshot, now: Date) -> String {
    if snapshot.service == "未运行" { return "Commander 服务未运行" }
    if snapshot.channelState == "通道畅通" || snapshot.channelState == "通道已恢复" {
        guard let checked = snapshot.channelChecked, checked <= now else { return "探测结果待核对" }
        return "上次探测成功"
    }
    return ["启动宽限": "启动等待中", "通道异常": "异常", "通道不可用": "不可用", "通道状态未知": "未确认", "正在恢复通道": "正在恢复", "恢复尚未确认": "恢复尚未确认"][snapshot.channelState] ?? snapshot.channelState
}

func displayEvidenceTime(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "时间未知" }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm:ss" : "yyyy-MM-dd HH:mm:ss"
    let stamp = formatter.string(from: date)
    let age = now.timeIntervalSince(date)
    guard age >= 0 else { return stamp }
    let seconds = Int(age)
    let relative = seconds < 60 ? "刚刚" : seconds < 3600 ? "\(seconds / 60)分钟前" : seconds < 86400 ? "\(seconds / 3600)小时前" : "\(seconds / 86400)天前"
    return "\(stamp)（\(relative)）"
}

func activityOverviewText(_ activity: ActivitySummary) -> String {
    if activity.catchingUp { return "日志追赶中；尚无法确认空闲" }
    if activity.activeCount > 0 { return "处理中：\(activity.activeCount) 项活动" }
    if activity.error || activity.coverageGap || !activity.idleProven { return "尚无法确认空闲" }
    return "已确认空闲"
}

func chatOverviewTitle(_ summary: ChatMonitorSummary) -> String {
    if summary.answer.hasPrefix("回答异常") { return "回答异常" }
    if summary.connection.contains("已建立") { return "连接正常" }
    if summary.connection.contains("准备重连") { return "正在重连" }
    if ["失败", "已关闭", "耗尽"].contains(where: summary.connection.contains) { return "连接异常" }
    return summary.connection.contains("未知") ? "连接未知" : "连接状态未确认"
}

func chatOverviewDetail(_ summary: ChatMonitorSummary) -> String {
    let answer = summary.answer == "回答恢复已记录" ? "记录到回答恢复完成" : summary.answer.hasPrefix("回答异常") ? "原回答恢复：尚未确认" : "原回答是否完整：无法确认"
    return [answer, summary.history].compactMap { $0 }.joined(separator: "；")
}

func wakePreventionSummary(enabled: Bool, serviceRunning: Bool, assertionActive: Bool) -> String {
    guard enabled else { return "已关闭" }
    guard serviceRunning else { return "等待 Commander 服务运行" }
    return assertionActive ? "Guard 正在防止闲置睡眠" : "Guard 的防睡眠请求未生效"
}

enum CommanderActivity {
    struct SessionAttribution {
        let key: String
        let source: String
        let conflict: Bool
        init(key: String, source: String, conflict: Bool = false) { self.key = key; self.source = source; self.conflict = conflict }
    }

    static let tools = ["ping": "连接检查（ping）", "read_file": "读取文件", "read_multiple_files": "读取文件", "read_process_output": "读取进程输出", "list_sessions": "查看终端会话", "list_processes": "查看进程", "list_directory": "查看目录", "search_files": "搜索文件", "start_search": "开始搜索", "get_more_search_results": "读取搜索结果", "stop_search": "停止搜索", "list_searches": "查看搜索任务", "get_file_info": "查看文件信息", "start_process": "启动进程", "interact_with_process": "操作进程", "kill_process": "结束进程", "force_terminate": "结束进程", "write_file": "写入文件", "edit_block": "编辑文件", "create_directory": "创建目录", "move_file": "移动文件", "get_config": "读取配置"]
    static let uuidPattern = try! NSRegularExpression(pattern: #"^🔧 Received tool call ([0-9a-fA-F-]{36}): ([A-Za-z0-9_-]+) "#)
    static let completionPattern = try! NSRegularExpression(pattern: #"^[✅❌] Tool call ([A-Za-z0-9_-]+) (completed|failed):"#)

    static func toolLabel(_ tool: String) -> String {
        if let label = tools[tool] { return label }
        guard tool.range(of: #"^[A-Za-z][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil,
              safeName(tool),
              !["sk-", "ghp_", "github_pat_", "eyj"].contains(where: tool.lowercased().hasPrefix),
              tool.range(of: #"(?i)^[0-9a-f]{8}-[0-9a-f-]{27,}$"#, options: .regularExpression) == nil else { return "未知工具" }
        return tool
    }

    static func safeToolIdentifier(_ tool: String) -> String { toolLabel(tool) == "未知工具" ? "未知工具" : tool }

    static func parse(_ bytes: Data, partial: Bool = false) -> (String, String, String, String)? {
        // A bounded prefix may end inside a UTF-8 scalar; discard only that incomplete suffix.
        let line = partial ? (0...3).lazy.compactMap { trim in
            trim <= bytes.count ? String(data: Data(bytes.prefix(bytes.count - trim)), encoding: .utf8) : nil
        }.first : String(data: bytes, encoding: .utf8)
        guard let line else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        if let m = uuidPattern.firstMatch(in: line, range: range), let idRange = Range(m.range(at: 1), in: line), let toolRange = Range(m.range(at: 2), in: line) {
            let id = String(line[idRange]), tool = String(line[toolRange])
            guard UUID(uuidString: id) != nil else { return nil }
            guard let separator = line.range(of: ": \(tool) ") else { return nil }
            let args = String(line[separator.upperBound...])
            return (id, tool, "received", detail(tool: tool, args: args))
        }
        if let m = completionPattern.firstMatch(in: line, range: range), let toolRange = Range(m.range(at: 1), in: line), let resultRange = Range(m.range(at: 2), in: line) {
            let tool = String(line[toolRange])
            return ("", tool, String(line[resultRange]), toolLabel(tool))
        }
        return nil
    }

    static func sessionAttribution(_ bytes: Data) -> SessionAttribution? {
        guard bytes.count <= 8 * 1024,
              let text = String(data: bytes, encoding: .utf8),
              let marker = text.range(of: " metadata: ", options: .backwards) else { return nil }
        let jsonText = String(text[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard jsonText.utf8.count <= 4 * 1024,
              let data = jsonText.data(using: .utf8),
              let metadata = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var candidates: [SessionAttribution] = []
        for source in ["openai/session", "origin_context_id"] {
            guard let raw = metadata[source] as? String else { continue }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= 512,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
            let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
            candidates.append(SessionAttribution(key: digest, source: source))
        }
        guard let first = candidates.first else { return nil }
        if candidates.dropFirst().contains(where: { $0.key != first.key }) {
            return SessionAttribution(key: "", source: "conflict", conflict: true)
        }
        return first
    }

    static func sessionDisplay(_ key: String?) -> String? {
        guard let key, key.count == 64, key.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "会话 " + key.prefix(10).uppercased()
    }

    private static func detail(tool: String, args: String) -> String {
        let path = stringValue(keys: ["file_path", "filePath", "path", "filename", "directory", "dir"], in: args)
        let components = path.flatMap { $0.utf8.count <= 1000 ? $0.split(separator: "/").map(String.init) : nil } ?? []
        let safeLeaf = components.last.flatMap { safeName($0) ? $0 : nil }
        let safePath = !components.isEmpty && components.allSatisfy(safeName) ? path : nil
        switch tool {
        case "read_file", "read_multiple_files": return safePath.map { "读取 \($0)" } ?? safeLeaf.map { "读取 \($0)" } ?? "读取文件"
        case "list_directory": return safePath.map { "查看目录 \($0)" } ?? safeLeaf.map { "查看目录 \($0)" } ?? "查看目录内容"
        case "write_file": return safePath.map { "更新 \($0)" } ?? safeLeaf.map { "更新 \($0)" } ?? "更新文件"
        case "edit_block": return safePath.map { "编辑 \($0)" } ?? safeLeaf.map { "编辑 \($0)" } ?? "编辑文件"
        case "read_process_output":
            // ponytail: read_process_output currently puts pid first; fall back to its generic label if that API shape changes.
            let pidPattern = try! NSRegularExpression(pattern: #"^\s*\{\s*\"(?:pid|process_id)\"\s*:\s*([0-9]{1,10})(?=\s*[,}])"#)
            if let match = pidPattern.firstMatch(in: args, range: NSRange(args.startIndex..., in: args)), let range = Range(match.range(at: 1), in: args) { return "读取进程 \(args[range]) 输出" }
            return "读取进程输出"
        case "start_process": return processDetail(args)
        case "search_files", "start_search": return "搜索文件内容"
        case "get_more_search_results", "list_searches": return "查看搜索结果"
        default: return toolLabel(tool)
        }
    }

    private static func firstObject(in args: String, keys: [String]) -> (String?, Bool) {
        guard args.utf8.count <= 4 * 1024 else { return (nil, false) }
        guard let start = args.firstIndex(where: { !$0.isWhitespace }), args[start] == "{" else { return (nil, false) }
        var braces = 0, brackets = 0, quoted = false, escaped = false, expectingKey = false, knownKey = false
        var keyStart: String.Index?, key: String?
        for index in args[start...].indices {
            let character = args[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" {
                    quoted = false
                    if let keyStart { key = String(args[keyStart..<index]); expectingKey = false }
                    keyStart = nil
                }
                continue
            }
            switch character {
            case "{": braces += 1; if braces == 1 { expectingKey = true }
            case "}":
                braces -= 1
                if braces == 0 { return (String(args[start...index]), knownKey) }
            case "[": brackets += 1
            case "]": brackets -= 1
            case ",": if braces == 1 && brackets == 0 { expectingKey = true; key = nil }
            case "\"": quoted = true; if braces == 1 && brackets == 0 && expectingKey { keyStart = args.index(after: index) }
            case ":": if braces == 1 && brackets == 0, let candidate = key { knownKey = knownKey || keys.contains(candidate); key = nil; expectingKey = false }
            default: break
            }
        }
        return (nil, knownKey)
    }

    private static func stringValue(keys: [String], in args: String) -> String? {
        guard args.utf8.count <= 4 * 1024 else { return nil }
        let (object, _) = firstObject(in: args, keys: keys)
        if let object {
            guard let data = object.data(using: .utf8), let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return keys.compactMap { values[$0] as? String }.first
        }
        for key in keys {
            let pattern = try! NSRegularExpression(pattern: #"^\s*\{\s*\""# + NSRegularExpression.escapedPattern(for: key) + #"\"\s*:\s*(\"(?:\\.|[^\"\\])*\")"#)
            let range = NSRange(args.startIndex..., in: args)
            if let match = pattern.firstMatch(in: args, range: range), let valueRange = Range(match.range(at: 1), in: args),
               let data = "[\(args[valueRange])]".data(using: .utf8), let value = (try? JSONSerialization.jsonObject(with: data)) as? [String], let first = value.first { return first }
        }
        return nil
    }

    private static func processDetail(_ args: String) -> String {
        guard let command = stringValue(keys: ["command", "cmd"], in: args) else {
            let (_, known) = firstObject(in: args, keys: ["command", "cmd"])
            return known ? "命令未完整读取" : "启动进程"
        }
        guard !command.isEmpty else { return "启动进程" }
        guard !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\t" && $0 != "\n" && $0 != "\r" }) else { return "命令含控制字符（内容已隐藏）" }
        guard !command.contains("$("), !command.contains("`") else { return "命令包含动态展开（内容已隐藏）" }
        guard let words = shellWords(command) else { return "命令格式未闭合（内容已隐藏）" }
        let safe = safeCommandPreview(words)
        return safe.count > 1000 ? String(safe.prefix(1000)) + "…（预览已截断）" : safe
    }

    static func menuDetail(_ detail: String) -> String {
        for (prefix, label) in [("读取 ", "读取"), ("查看目录 ", "查看目录"), ("更新 ", "更新"), ("编辑 ", "编辑")] where detail.hasPrefix(prefix) {
            let path = String(detail.dropFirst(prefix.count))
            let components = path.split(separator: "/").map(String.init)
            guard !components.isEmpty, components.allSatisfy(safeName) else { return detail }
            return "\(label) \(components.suffix(3).joined(separator: "/"))"
        }
        guard let words = shellWords(detail), words.count >= 4,
              !words[0].syntax, words[0].value == "cd", !words[1].syntax,
              words[2].syntax, words[2].raw == "&&" else { return detail }
        let path = words[1].value
        let components = path.split(separator: "/").map(String.init)
        guard path.utf8.count <= 1000, !components.isEmpty, components.allSatisfy(safeName) else { return detail }
        var command = ""
        for word in words.dropFirst(3) {
            if !command.isEmpty && word.spaced { command += " " }
            command += word.raw
        }
        guard !command.isEmpty else { return detail }
        return "目录 \(components.last!) · \(command)"
    }

    private static func shellWords(_ command: String) -> [(value: String, raw: String, syntax: Bool, spaced: Bool)]? {
        var words: [(value: String, raw: String, syntax: Bool, spaced: Bool)] = [], word = "", raw = "", quote: Character?, started = false, escaped = false, spaced = false, wordSpaced = false
        func flush() {
            if started { words.append((word, raw, false, wordSpaced)); word = ""; raw = ""; started = false }
        }
        for character in command {
            if escaped { raw.append(character); word.append(character); escaped = false; continue }
            if character == "\\" && quote != "'" { if !started { wordSpaced = spaced; spaced = false }; raw.append(character); started = true; escaped = true; continue }
            if let active = quote {
                raw.append(character)
                if character == active { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" { if !started { wordSpaced = spaced; spaced = false }; quote = character; started = true; raw.append(character) }
            else if character == "\n" || character == "\r" { flush(); words.append((";", ";", true, true)); spaced = true }
            else if character.isWhitespace { flush(); spaced = true }
            else if ";|&<>".contains(character) {
                flush()
                if let last = words.last, last.syntax, !spaced,
                   (last.raw.last == character && "|&<>".contains(character) || last.raw == ">" && character == "&" || last.raw == "&" && character == ">") {
                    words[words.count - 1] = (last.value + String(character), last.raw + String(character), true, last.spaced)
                } else { words.append((String(character), String(character), true, spaced)) }
                spaced = false
            }
            else { if !started { wordSpaced = spaced; spaced = false }; word.append(character); raw.append(character); started = true }
        }
        guard quote == nil, !escaped else { return nil }
        flush()
        return words
    }

    private static func safeCommandPreview(_ words: [(value: String, raw: String, syntax: Bool, spaced: Bool)]) -> String {
        let sensitiveHeader = #"(?i)^(?:authorization|proxy-authorization|cookie|set-cookie|x-(?:api-key|token|auth(?:-[a-z0-9-]+)?))\s*:"#
        func sensitiveName(_ name: String) -> Bool {
            let compact = name.lowercased().filter { $0.isLetter || $0.isNumber }
            return ["token", "secret", "password", "credential", "authorization", "cookie", "apikey", "privatekey", "accesskey"].contains(where: compact.contains) || compact == "auth" || compact == "oauth2bearer" || compact == "user" || compact == "proxyuser"
        }
        func secretShape(_ value: String) -> Bool {
            if value.range(of: #"(?i)(?:sk-|ghp_|github_pat_)[a-z0-9_-]{12,}"#, options: .regularExpression) != nil { return true }
            if value.range(of: #"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, options: .regularExpression) != nil { return true }
            if value.range(of: #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, options: .regularExpression) != nil { return true }
            return value.split(separator: "/").contains { part in
                let word = String(part)
                if word.range(of: #"(?i)^[a-f0-9]{24,}$"#, options: .regularExpression) != nil { return true }
                return word.range(of: #"^[A-Za-z0-9+_-]{32,}={0,2}$"#, options: .regularExpression) != nil && word.contains(where: \.isUppercase) && word.contains(where: \.isLowercase) && word.contains(where: \.isNumber) && Set(word).count >= 12
            }
        }
        var result = "", pendingValue = false, pendingScript = false, pendingHeader = false, hereDoc = false, executable = "", commandStart = true
        func add(_ text: String, spaced: Bool) {
            if !result.isEmpty && spaced { result += " " }
            result += text
        }
        for token in words {
            if token.syntax {
                if hereDoc && token.raw == ";" { add("[内联脚本已隐藏]", spaced: true); break }
                if pendingValue || pendingScript { add("[已隐藏]", spaced: true); pendingValue = false; pendingScript = false }
                add(token.raw, spaced: token.spaced)
                if [";", "&&", "||", "|", "&"].contains(token.raw) { commandStart = true; executable = ""; pendingHeader = false }
                if token.raw == "<<" || token.raw == "<<-" { hereDoc = true }
                continue
            }
            let value = token.value, lower = value.lowercased()
            if pendingHeader { continue }
            if pendingValue || pendingScript {
                if pendingValue && value == "=" { add("=", spaced: token.spaced); continue }
                add(pendingScript ? "[内联脚本已隐藏]" : "[已隐藏]", spaced: token.spaced)
                pendingValue = false; pendingScript = false
                continue
            }
            if commandStart && !value.contains("=") {
                executable = URL(fileURLWithPath: value).lastPathComponent.lowercased()
                commandStart = false
            }
            if lower.range(of: sensitiveHeader, options: .regularExpression) != nil {
                add(String(value.prefix(while: { $0 != ":" })) + ": [已隐藏]", spaced: token.spaced)
                pendingHeader = value.trimmingCharacters(in: .whitespaces).hasSuffix(":")
                continue
            }
            if value.contains("://") && (value.contains("@") || value.contains("?") || secretShape(value)) {
                add("[网址已隐藏]", spaced: token.spaced); continue
            }
            if let equal = value.firstIndex(of: "=") {
                let key = String(value[..<equal])
                if sensitiveName(key) || executable == "curl" && ["-u", "-U"].contains(key) {
                    add(key + "=[已隐藏]", spaced: token.spaced); continue
                }
                if ["-h", "--header", "--proxy-header"].contains(key.lowercased()),
                   value[value.index(after: equal)...].range(of: sensitiveHeader, options: .regularExpression) != nil {
                    add(key + "=[敏感请求头已隐藏]", spaced: token.spaced); continue
                }
            }
            if executable == "curl" && (value.hasPrefix("-u") || value.hasPrefix("-U")) && value.count > 2 {
                add(String(value.prefix(2)) + "[已隐藏]", spaced: token.spaced); continue
            }
            if value.hasPrefix("-"), sensitiveName(value) || executable == "curl" && ["-u", "-U"].contains(value) {
                add(token.raw, spaced: token.spaced); pendingValue = true; continue
            }
            if ["python", "python3", "node", "sh", "bash", "zsh"].contains(executable),
               (value == "-c" || executable == "node" && ["-e", "--eval"].contains(value) || ["sh", "bash", "zsh"].contains(executable) && value.range(of: #"^-[A-Za-z]*c$"#, options: .regularExpression) != nil) {
                add(token.raw, spaced: token.spaced); pendingScript = true; continue
            }
            if value.contains("{"), value.range(of: #"(?i)[\"'][a-z0-9_-]*(?:token|secret|password|credential|authorization|api[-_]?key)[a-z0-9_-]*[\"']\s*:"#, options: .regularExpression) != nil {
                add("[含敏感字段的内容已隐藏]", spaced: token.spaced); continue
            }
            if value.contains("@") || secretShape(value) {
                add("[已隐藏]", spaced: token.spaced); continue
            }
            add(token.raw, spaced: token.spaced)
        }
        if pendingValue || pendingScript { add("[已隐藏]", spaced: true) }
        return result.isEmpty ? "启动进程" : result
    }

    private static func safeName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64,
              value.range(of: #"^[\p{L}\p{N}._ -]+$"#, options: .regularExpression) != nil,
              !value.contains(".."), !value.contains("@"), !value.contains("://") else { return false }
        let compact = value.filter { $0.isLetter || $0.isNumber }
        let lower = value.lowercased()
        return !["token", "secret", "credential", "password", "apikey", "api_key"].contains(where: lower.contains) && (compact.count < 28 || Set(compact).count <= 10)
    }

}

/// Reads Desktop Commander's bounded JSONL history without retaining arguments or output bodies.
/// The history has no reliable call id, so these records remain a separate evidence source and
/// are never merged into stdout-derived ActivityStep rows by timestamp.
final class ToolHistoryReader {
    private let url: URL
    private var offset: UInt64 = 0
    private var fileID: UInt64?
    private var initialized = false
    private var partial = Data()
    private var discarding = false
    private var recent = [ToolHistoryRecord]()
    private var seen = Set<String>()
    private let bootstrapLimit: UInt64 = 512 * 1024
    private let readLimit: UInt64 = 256 * 1024
    private let lineLimit = 64 * 1024
    private(set) var summary = ToolHistorySummary()

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-server-commander/tool-history.jsonl")) { self.url = url }

    func poll() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let id = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else {
            summary.sourceAvailable = false; summary.state = "结构化历史不可用"; return
        }
        summary.sourceAvailable = true
        if !initialized {
            bootstrap(size: size, id: id); return
        }
        if fileID != id || size < offset {
            summary.coverageGap = true
            summary.gapReason = fileID != id ? "结构化历史已轮换" : "结构化历史已截断"
            partial.removeAll(keepingCapacity: true); discarding = false
            bootstrap(size: size, id: id); return
        }
        guard size > offset else {
            summary.backlogBytes = 0
            summary.state = summary.coverageGap ? "结构化历史可读 · 覆盖有缺口" : "结构化历史读取正常"
            publish(); return
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { summary.state = "结构化历史读取失败"; return }
        var data = Data()
        do {
            var statBuffer = stat()
            guard fstat(handle.fileDescriptor, &statBuffer) == 0, UInt64(statBuffer.st_ino) == id, UInt64(statBuffer.st_size) >= offset else { throw CocoaError(.fileReadUnknown) }
            try handle.seek(toOffset: offset)
            data = try handle.read(upToCount: Int(min(readLimit, size - offset))) ?? Data()
            if size > offset && data.isEmpty { throw CocoaError(.fileReadUnknown) }
        } catch {
            try? handle.close(); summary.state = "结构化历史读取失败"; return
        }
        try? handle.close(); offset += UInt64(data.count)
        consume(data)
        summary.backlogBytes = size - offset
        summary.state = summary.backlogBytes > 0 ? "结构化历史追赶中" : (summary.coverageGap ? "结构化历史可读 · 覆盖有缺口" : "结构化历史读取正常")
        publish()
    }

    private func bootstrap(size: UInt64, id: UInt64) {
        initialized = true; fileID = id; partial.removeAll(keepingCapacity: true); discarding = false
        let start = size > bootstrapLimit ? size - bootstrapLimit : 0
        summary.bootstrapLimited = start > 0
        guard size > 0 else { offset = 0; summary.state = "结构化历史为空"; publish(); return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { offset = size; summary.state = "结构化历史读取失败"; return }
        var data = Data()
        do {
            var statBuffer = stat()
            guard fstat(handle.fileDescriptor, &statBuffer) == 0, UInt64(statBuffer.st_ino) == id, UInt64(statBuffer.st_size) >= size else { throw CocoaError(.fileReadUnknown) }
            try handle.seek(toOffset: start)
            data = try handle.read(upToCount: Int(size - start)) ?? Data()
        } catch {
            try? handle.close(); offset = size; summary.state = "结构化历史读取失败"; return
        }
        try? handle.close(); offset = size
        if start > 0, let firstNewline = data.firstIndex(of: 10) { data = Data(data[data.index(after: firstNewline)...]) }
        else if start > 0 { data.removeAll() }
        consume(data)
        summary.backlogBytes = 0
        summary.state = summary.coverageGap ? "结构化历史可读 · 覆盖有缺口" : (summary.bootstrapLimited ? "最近结构化历史已读取" : "结构化历史读取正常")
        publish()
    }

    private func consume(_ data: Data) {
        for byte in data {
            if byte == 10 {
                if !discarding && !partial.isEmpty { parseLine(partial) }
                partial.removeAll(keepingCapacity: true); discarding = false
            } else if !discarding {
                if partial.count < lineLimit { partial.append(byte) }
                else { discarding = true; summary.coverageGap = true; summary.gapReason = "结构化历史存在超长记录"; summary.malformedLines += 1 }
            }
        }
    }

    private func parseLine(_ data: Data) {
        guard data.count <= lineLimit,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawTime = object["timestamp"] as? String, let timestamp = ISO8601DateFormatter.parse(rawTime),
              let tool = object["toolName"] as? String, tool.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil else {
            summary.coverageGap = true; summary.gapReason = "结构化历史包含损坏记录"; summary.malformedLines += 1; return
        }
        let duration: TimeInterval?
        if let number = object["duration"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 86_400_000 {
            duration = number.doubleValue / 1000
        } else { duration = nil }
        let output = object["output"] as? [String: Any]
        let returned = object.keys.contains("output") && !(object["output"] is NSNull)
        let failed = output?["isError"] as? Bool == true
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard !seen.contains(fingerprint) else { return }
        let record = ToolHistoryRecord(fingerprint: fingerprint, timestamp: timestamp, tool: tool, duration: duration, returned: returned, failed: failed)
        recent.insert(record, at: 0); seen.insert(fingerprint)
        if recent.count > 100 {
            let removed = recent.removeLast(); seen.remove(removed.fingerprint)
        }
    }

    private func publish() {
        summary.recent = recent
        summary.latest = recent.max(by: { $0.timestamp < $1.timestamp })
    }
}

/// Reads only bounded log prefixes. Bootstrap supplies recent labels, never live-running state.
final class ActivityLogReader {
    private let url: URL
    private let errorURL: URL?
    private var offset: UInt64 = 0
    private var fileID: UInt64?
    private var initialized = false
    private var searchEnd: UInt64?
    private var searchSize: UInt64 = 0
    private var replaying = false
    private var provenEpoch = false
    private var freshEmptyLog = false
    private var partial = Data()
    private var discarding = false
    private var discardedTail = Data()
    private var discardedCallID: String?
    private var prefixEvent = ""
    private var errorOffset: UInt64 = 0
    private var errorFileID: UInt64?
    private var errorPartial = Data()
    private var errorDiscarding = false
    // Keep every observed ID for this reader lifetime: an old replay must never look like a new call.
    private var seen = Set<String>()
    private var active = [String: Int]()
    private var steps = [ActivityStep]()
    private var recent = [String]()
    private var recentIDs = [String]()
    private var lastObserved: Date?
    private var lastTool = ""
    private var observedLive = false
    private var uncertain = false
    private var coverageGap = false
    private var gapReason = ""
    private var gapFirstAt: Date?
    private var gapLastAt: Date?
    private var lastOutcome = "调用状态未确认"
    private(set) var summary = ActivitySummary()
    private let lineLimit = 4 * 1024
    private let metadataTailLimit = 8 * 1024
    private let ioLimit = 64 * 1024

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RemoteDesktopCommander/stdout.log"), errorURL: URL? = nil) { self.url = url; self.errorURL = errorURL }

    func poll(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        defer {
            summary.coverageGap = coverageGap
            summary.gapReason = gapReason
            summary.gapFirstAt = gapFirstAt
            summary.gapLastAt = gapLastAt
            summary.pendingLine = !partial.isEmpty || discarding || !errorPartial.isEmpty || errorDiscarding
            summary.idleProven = provenEpoch && !replaying && !coverageGap && !summary.error && !summary.catchingUp && !summary.pendingLine
        }
        defer { pollErrors(now: now, uptime: uptime) }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? UInt64 else {
            if initialized && !FileManager.default.fileExists(atPath: url.path) { markGap("调用日志暂时不存在", now: now) }
            summary.error = true; summary.state = "日志不可读 / 状态未知"; return
        }
        let id = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        guard id != nil else { summary.error = true; summary.state = "日志身份未确认 / 状态未知"; return }
        if !initialized {
            initialized = true; fileID = id; searchEnd = size; searchSize = size
            summary.backlogBytes = size; summary.state = "查找当前服务日志中"
            if size == 0 { searchEnd = nil; freshEmptyLog = true; summary.backlogBytes = 0; summary.state = "等待服务启动记录" }
            return
        } else if id != fileID || size < offset {
            markGap(id != fileID ? "调用日志已轮换" : "调用日志已截断", now: now)
            offset = size; fileID = id; replaying = false; provenEpoch = false
            partial.removeAll(); discarding = false; discardedTail.removeAll(); discardedCallID = nil; prefixEvent = ""
            invalidateSteps(); active.removeAll(); seen.removeAll(); recent.removeAll(); recentIDs.removeAll()
            lastObserved = nil; lastTool = ""; observedLive = false; uncertain = true; lastOutcome = "调用状态未确认"
            summary.active = [:]; summary.steps = steps; summary.state = "调用状态未确认"
            return
        }
        if let end = searchEnd {
            guard size >= searchSize else { markGap("查找期间调用日志已截断", now: now); searchEnd = nil; summary.state = "调用状态未确认"; return }
            let marker = Data("🚀 Starting MCP Device...\n".utf8)
            let start = end > 4 * 1024 * 1024 ? end - 4 * 1024 * 1024 : 0
            let readStart = start > 0 ? start - 1 : 0
            let readEnd = min(searchSize, end + UInt64(marker.count))
            guard let handle = try? FileHandle(forReadingFrom: url) else { summary.error = true; summary.state = "日志读取异常 / 状态未知"; return }
            var block = Data()
            do {
                var statBuffer = stat()
                guard fstat(handle.fileDescriptor, &statBuffer) == 0,
                      UInt64(statBuffer.st_ino) == id, UInt64(statBuffer.st_size) >= searchSize else { throw CocoaError(.fileReadUnknown) }
                try handle.seek(toOffset: readStart)
                block = try handle.read(upToCount: Int(readEnd - readStart)) ?? Data()
                if block.count != Int(readEnd - readStart) { throw CocoaError(.fileReadUnknown) }
            } catch {
                try? handle.close(); summary.error = true; summary.state = "日志读取异常 / 状态未知"; return
            }
            try? handle.close(); summary.error = false
            var markerOffset: UInt64?
            var upper = block.count
            while let found = block.range(of: marker, options: .backwards, in: 0..<upper) {
                let absolute = readStart + UInt64(found.lowerBound)
                if absolute < end && (found.lowerBound == 0 ? readStart == 0 : block[found.lowerBound - 1] == 10) {
                    markerOffset = absolute; break
                }
                upper = found.lowerBound
            }
            if let markerOffset {
                offset = markerOffset
                searchEnd = nil; replaying = true; summary.backlogBytes = size - offset
            } else if start == 0 {
                searchEnd = nil; offset = size; summary.backlogBytes = 0
                summary.state = "当前日志缺少服务启动记录"; return
            } else {
                searchEnd = start; summary.backlogBytes = size; summary.state = "查找当前服务日志中"; return
            }
        }
        if size == offset && !summary.error {
            summary.backlogBytes = 0; summary.state = activityState(); return
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { summary.error = true; summary.state = "日志读取异常 / 状态未知"; return }
        var data = Data()
        do {
            var statBuffer = stat()
            guard fstat(handle.fileDescriptor, &statBuffer) == 0,
                  UInt64(statBuffer.st_ino) == id, UInt64(statBuffer.st_size) >= offset else {
                throw CocoaError(.fileReadUnknown)
            }
            try handle.seek(toOffset: offset)
            let limit = replaying ? 4 * 1024 * 1024 : ioLimit
            if size > offset { data = try handle.read(upToCount: Int(min(UInt64(limit), size - offset))) ?? Data() }
            if size > offset && data.isEmpty { throw CocoaError(.fileReadUnknown) }
        } catch {
            try? handle.close(); summary.error = true; summary.state = "日志读取异常 / 状态未知"; return
        }
        try? handle.close(); offset += UInt64(data.count)
        if !data.isEmpty { consume(data, live: true, now: now, uptime: uptime) }
        if replaying && offset == size { replaying = false }
        summary.error = false
        summary.backlogBytes = size - offset
        summary.active = active
        summary.recent = recent
        summary.steps = steps
        summary.observed = lastObserved
        summary.observedUptime = lastObserved == nil ? nil : summary.observedUptime
        summary.state = replaying || summary.catchingUp ? "调用日志追赶中" : activityState()
    }

    private func activityState() -> String {
        !provenEpoch ? "调用状态未确认" : (!observedLive ? (uncertain ? "调用状态未确认" : "未观察到新调用") : (active.isEmpty ? lastOutcome : "收到调用（处理中）"))
    }

    private func markGap(_ reason: String, now: Date) {
        if !coverageGap { gapFirstAt = now }
        coverageGap = true; gapReason = reason; gapLastAt = now
    }

    @discardableResult func confirmedProcessRestart(oldPID: Int32, newPID: Int32, oldProcessExited: Bool) -> Bool {
        guard oldPID > 0, newPID > 0, oldPID != newPID, oldProcessExited else { return false }
        offset = 0; fileID = nil; initialized = false; searchEnd = nil; searchSize = 0
        replaying = false; provenEpoch = false; freshEmptyLog = false
        partial.removeAll(); discarding = false; discardedTail.removeAll(); discardedCallID = nil; prefixEvent = ""
        active.removeAll(); seen.removeAll(); steps.removeAll(); recent.removeAll(); recentIDs.removeAll()
        observedLive = false; uncertain = true; lastOutcome = "调用状态未确认"; lastObserved = nil; lastTool = ""
        errorOffset = 0; errorFileID = nil; errorPartial.removeAll(); errorDiscarding = false
        coverageGap = false; gapReason = ""; gapFirstAt = nil; gapLastAt = nil
        summary = ActivitySummary(state: "正在重建新服务进程的调用记录")
        return true
    }

    private func pollErrors(now: Date, uptime: TimeInterval) {
        guard let errorURL else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: errorURL.path),
              let size = attrs[.size] as? UInt64,
              let id = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else {
            summary.error = true; summary.state = "错误日志不可读 / 状态未知"; return
        }
        if errorFileID == nil { errorFileID = id; errorOffset = size; return }
        if replaying || searchEnd != nil { return }
        if id != errorFileID || size < errorOffset {
            markGap(id != errorFileID ? "错误日志已轮换" : "错误日志已截断", now: now)
            errorFileID = id; errorOffset = size; errorPartial.removeAll(); errorDiscarding = false; return
        }
        guard size > errorOffset else { return }
        guard let handle = try? FileHandle(forReadingFrom: errorURL) else { summary.error = true; summary.state = "错误日志读取异常 / 状态未知"; return }
        var data = Data()
        do {
            var statBuffer = stat()
            guard fstat(handle.fileDescriptor, &statBuffer) == 0,
                  UInt64(statBuffer.st_ino) == id, UInt64(statBuffer.st_size) >= errorOffset else {
                throw CocoaError(.fileReadUnknown)
            }
            try handle.seek(toOffset: errorOffset)
            data = try handle.read(upToCount: Int(min(UInt64(ioLimit), size - errorOffset))) ?? Data()
            if data.isEmpty { throw CocoaError(.fileReadUnknown) }
        } catch {
            try? handle.close(); summary.error = true; summary.state = "错误日志读取异常 / 状态未知"; return
        }
        try? handle.close(); errorOffset += UInt64(data.count)
        for byte in data {
            if byte == 10 {
                if !errorDiscarding {
                    if let event = CommanderActivity.parse(errorPartial), event.2 == "failed" {
                        let known = active[event.1, default: 0] > 0
                        if !known { markGap("错误终态没有对应的开始记录", now: now) }
                        self.handle(event, live: true, now: now, uptime: uptime)
                    } else if let prefix = String(data: errorPartial, encoding: .utf8), prefix.hasPrefix("❌ Tool call ") {
                        markGap("错误事件格式无法识别", now: now)
                    }
                }
                errorPartial.removeAll(keepingCapacity: true); errorDiscarding = false
            } else if errorPartial.count < lineLimit { errorPartial.append(byte) }
            else if !errorDiscarding {
                if errorPartial.starts(with: Data("❌ Tool call ".utf8)) {
                    if let event = CommanderActivity.parse(errorPartial, partial: true), event.2 == "failed" {
                        if active[event.1, default: 0] == 0 { markGap("错误终态没有对应的开始记录", now: now) }
                        self.handle(event, live: true, now: now, uptime: uptime)
                    } else { markGap("错误事件前缀超过读取上限", now: now) }
                }
                errorDiscarding = true
            }
        }
        summary.backlogBytes += size - errorOffset
        summary.active = active; summary.steps = steps
        if !summary.error { summary.state = summary.catchingUp ? "调用日志追赶中" : activityState() }
    }

    private func consume(_ data: Data, live: Bool, now: Date, uptime: TimeInterval) {
        for byte in data {
            if byte == 10 {
                if !discarding {
                    emit(partial, live: live, complete: true, now: now, uptime: uptime)
                } else if let callID = discardedCallID, let attribution = CommanderActivity.sessionAttribution(discardedTail) {
                    attachSession(callID: callID, attribution: attribution)
                }
                partial.removeAll(keepingCapacity: true); discarding = false; discardedTail.removeAll(keepingCapacity: true); discardedCallID = nil; prefixEvent = ""
            } else if !discarding {
                if partial.count < lineLimit { partial.append(byte) }
                else {
                    let parsed = CommanderActivity.parse(partial, partial: true)
                    if live,
                       (partial.starts(with: Data("🔧 Received tool call ".utf8)) || partial.starts(with: Data("✅ Tool call ".utf8)) || partial.starts(with: Data("❌ Tool call ".utf8))),
                       parsed == nil { markGap("调用事件前缀超过读取上限", now: now) }
                    discardedCallID = parsed?.2 == "received" ? parsed?.0 : nil
                    discardedTail = Data(partial.suffix(metadataTailLimit))
                    discarding = true
                    emit(partial, live: live, complete: false, now: now, uptime: uptime)
                }
            } else if discardedCallID != nil {
                discardedTail.append(byte)
                if discardedTail.count > metadataTailLimit { discardedTail.removeFirst(discardedTail.count - metadataTailLimit) }
            }
        }
        if live && !discarding && !partial.isEmpty { emit(partial, live: true, complete: false, now: now, uptime: uptime) }
    }

    private func emit(_ bytes: Data, live: Bool, complete: Bool, now: Date, uptime: TimeInterval) {
        if live && freshEmptyLog {
            let marker = Data("🚀 Starting MCP Device...".utf8)
            if !bytes.starts(with: marker) && !marker.starts(with: bytes) { freshEmptyLog = false }
        }
        if let text = String(data: bytes, encoding: .utf8),
           text.hasPrefix("🚀 Starting MCP Device") || text.hasPrefix("🛑 Shutting down device") {
            let key = text.hasPrefix("🚀") ? "service-start" : "service-stop"
            guard key != prefixEvent else { return }; prefixEvent = key
            if live {
                if replaying {
                    // The retained start marker begins a new service epoch before it can accept calls.
                    provenEpoch = key == "service-start"; uncertain = !provenEpoch
                } else if key == "service-start" && freshEmptyLog && !coverageGap {
                    provenEpoch = true; uncertain = false; freshEmptyLog = false
                } else {
                    markGap(key == "service-start" ? "服务启动时旧调用状态未确认" : "服务停止时调用状态未确认", now: now)
                    provenEpoch = false; uncertain = true
                }
                active.removeAll(); seen.removeAll(); observedLive = false; lastOutcome = "调用状态未确认"; lastObserved = nil; summary.active.removeAll(); summary.state = "调用状态未确认"
            }
            if live { invalidateSteps(); summary.steps = steps }
            return
        }
        guard let event = CommanderActivity.parse(bytes, partial: !complete) else {
            if live && complete,
               bytes.starts(with: Data("🔧 Received tool call ".utf8)) || bytes.starts(with: Data("✅ Tool call ".utf8)) || bytes.starts(with: Data("❌ Tool call ".utf8)) {
                markGap("调用事件格式无法识别", now: now)
            }
            return
        }
        if live && !provenEpoch { freshEmptyLog = false }
        let key = "\(event.0)|\(event.1)|\(event.2)|\(event.3)"
        let attribution = event.2 == "received" ? CommanderActivity.sessionAttribution(bytes) : nil
        if key == prefixEvent {
            if let attribution { attachSession(callID: event.0, attribution: attribution) }
            return
        }
        prefixEvent = key
        handle(event, live: live, now: now, uptime: uptime)
        if let attribution { attachSession(callID: event.0, attribution: attribution) }
    }

    private func attachSession(callID: String, attribution: CommanderActivity.SessionAttribution) {
        guard let index = steps.firstIndex(where: { $0.id == callID }) else { return }
        if steps[index].sessionAttributionConflict { return }
        if attribution.conflict {
            steps[index].sessionKey = nil; steps[index].sessionSource = nil; steps[index].sessionAttributionConflict = true; summary.steps = steps; return
        }
        if let existing = steps[index].sessionKey, existing != attribution.key {
            steps[index].sessionKey = nil; steps[index].sessionSource = nil; steps[index].sessionAttributionConflict = true
        } else {
            steps[index].sessionKey = attribution.key; steps[index].sessionSource = attribution.source
        }
        summary.steps = steps
    }

    private func handle(_ event: (String, String, String, String), live: Bool, now: Date, uptime: TimeInterval) {
        let (id, tool, result, detail) = event
        if result == "received" {
            if seen.contains(id) {
                if live && summary.latestReceivedID == id {
                    lastTool = detail; summary.tool = detail
                    if let i = steps.firstIndex(where: { $0.id == id && !$0.finished && $0.duration == nil && !$0.uncertain }) { steps[i].detail = detail }
                    summary.steps = steps
                }
                return
            }
            lastTool = detail
            summary.tool = detail
            seen.insert(id)
            let recentLabel = "收到：\(detail)"
            if recent.first != recentLabel { recent.insert(recentLabel, at: 0); recentIDs.insert(id, at: 0) }
            else if !recentIDs.isEmpty { recentIDs[0] = id }
            recent = Array(recent.prefix(3)); recentIDs = Array(recentIDs.prefix(3))
            if live { observedLive = true; lastOutcome = "收到调用（处理中）"; summary.returnedStepID = nil; active[tool, default: 0] += 1; summary.tool = detail; summary.observed = now; summary.observedUptime = uptime; summary.latestReceivedID = id; lastObserved = now }
            if live { steps.insert(ActivityStep(id: id, tool: tool, detail: detail, startedAt: now, startedUptime: uptime, uncertain: replaying, historical: replaying), at: 0); steps = Array(steps.prefix(100)); summary.steps = steps }
        } else {
            if live {
                if active[tool, default: 0] == 0 { markGap("调用结束缺少对应的开始记录", now: now) }
                observedLive = true; lastOutcome = result == "completed" ? "本机已返回（云端结果未知）" : "本机异常（云端结果未知）"; summary.returnedStepID = nil; lastObserved = now; summary.observedUptime = uptime
                let candidates = steps.indices.filter { steps[$0].tool == tool && !steps[$0].finished && steps[$0].duration == nil }
                if candidates.count == 1 && active[tool] == 1 { let i = candidates[0]; steps[i].finished = true; if !steps[i].historical && !steps[i].uncertain { steps[i].duration = max(0, uptime - steps[i].startedUptime) }; steps[i].failed = result == "failed"; if result == "completed" && !steps[i].historical { summary.returnedStepID = steps[i].id } }
                else { for i in candidates { steps[i].uncertain = true } }
                if let count = active[tool], count > 0 { if count == 1 { active.removeValue(forKey: tool) } else { active[tool] = count - 1 } }
                summary.steps = steps
            }
        }
    }

    private func invalidateSteps() { for i in steps.indices where !steps[i].finished && steps[i].duration == nil { steps[i].uncertain = true } }
}

enum CloudState {
    static func trustedBackend(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", url.host?.lowercased() == "olvbkozcufcbptfogatw.supabase.co",
              url.port == nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        return url
    }
    static func validDeviceID(_ value: String) -> Bool { UUID(uuidString: value) != nil }
    static func classify(status: String?, lastSeen: Date?, now: Date, serverDate: Date? = nil) -> String {
        guard let status, let lastSeen else { return "未知（监测不可用）" }
        let adjustedNow = serverDate.map { now.addingTimeInterval($0.timeIntervalSince(now)) } ?? now
        if status.lowercased() == "offline" { return "设备离线（服务器记录）" }
        guard status.lowercased() == "online" else { return "未知（服务器状态：\(status)）" }
        let age = adjustedNow.timeIntervalSince(lastSeen)
        guard age >= -300 else { return "未知（设备时间异常）" }
        return age <= 900 ? "服务器登记在线" : "记录已过期（超过15分钟）"
    }
}

final class Monitor: NSObject, URLSessionTaskDelegate {
    static let shared = Monitor()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    private var publicConfig: (URL, String)?
    private var busy = false

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func check(_ done: @escaping (String, Date?, String?) -> Void) {
        guard !busy else { return }
        busy = true
        func finish(_ state: String, _ seen: Date? = nil, _ message: String? = nil) {
            self.busy = false
            done(state, seen, message)
        }
        func query(_ base: URL, _ key: String) {
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".desktop-commander-device/device.json")
            guard let data = try? Data(contentsOf: file), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = root["deviceId"] as? String, CloudState.validDeviceID(id),
                  let session = root["session"] as? [String: Any], let token = session["access_token"] as? String, !token.isEmpty else {
                finish("未知（本机登录信息不可用）", nil, "device.json 或现有 access token 不可用")
                return
            }
            var c = URLComponents(url: base.appendingPathComponent("rest/v1/mcp_devices"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "select", value: "status,last_seen"), URLQueryItem(name: "id", value: "eq.\(id)"), URLQueryItem(name: "limit", value: "1")]
            guard let url = c.url else { finish("未知（监测不可用）", nil, "无效请求地址"); return }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = "GET"
            request.setValue(key, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            self.session.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async {
                self.busy = false
                guard error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
                      let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], let row = rows.first,
                      let status = row["status"] as? String,
                      let raw = row["last_seen"] as? String,
                      let seen = ISO8601DateFormatter.parse(raw) else {
                    let code = (response as? HTTPURLResponse)?.statusCode
                    done("未知（监测不可用）", nil, code.map { "云端请求失败（HTTP \($0)）" } ?? "网络、认证或云端数据不可用")
                    return
                }
                let server = (http.value(forHTTPHeaderField: "Date")).flatMap(ISO8601DateFormatter.httpDate.date(from:))
                done(CloudState.classify(status: status, lastSeen: seen, now: Date(), serverDate: server), seen, nil)
                }
            }.resume()
        }
        if let (url, key) = publicConfig { query(url, key); return }
        let configURL = URL(string: "https://mcp.desktopcommander.app/api/mcp-info")!
        session.dataTask(with: URLRequest(url: configURL, timeoutInterval: 10)) { data, response, error in
            guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let raw = json["supabaseUrl"] as? String, let url = CloudState.trustedBackend(raw),
                  let key = json["supabasePublishableKey"] as? String, !key.isEmpty else {
                DispatchQueue.main.async { self.busy = false; done("未知（监测不可用）", nil, "公开服务配置不可用或主机不受信任") }
                return
            }
            DispatchQueue.main.async { self.publicConfig = (url, key); query(url, key) }
        }.resume()
    }

    /// Confirms that the server has no pending or executing calls before a recovery restart.
    func checkOutstandingCalls(_ done: @escaping (Bool?, String?) -> Void) {
        guard let (base, key) = publicConfig else { done(nil, "服务配置或监测状态未知"); return }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".desktop-commander-device/device.json")
        guard let data = try? Data(contentsOf: file), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = root["deviceId"] as? String, CloudState.validDeviceID(id),
              let auth = root["session"] as? [String: Any], let token = auth["access_token"] as? String, !token.isEmpty else {
            done(nil, "本机登录信息不可用"); return
        }
        var components = URLComponents(url: base.appendingPathComponent("rest/v1/mcp_remote_calls"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "select", value: "id"), URLQueryItem(name: "device_id", value: "eq.\(id)"), URLQueryItem(name: "status", value: "in.(pending,executing)"), URLQueryItem(name: "limit", value: "1")]
        guard let url = components.url else { done(nil, "监测请求无效"); return }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"; request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
                      let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    done(nil, "云端待执行调用状态未知"); return
                }
                done(rows.isEmpty, rows.isEmpty ? nil : "云端仍有待执行调用")
            }
        }.resume()
    }
}

enum ChannelProbeResult {
    case healthy
    case noLiveConnection
    case unknown(String)
}

enum ChannelIncidentCategory: String, Codable {
    case channelDisruption = "channel_disruption"
    case cloudRealtimeCapacity = "cloud_realtime_capacity"

    var title: String {
        switch self {
        case .channelDisruption: return "Commander 通道持续异常"
        case .cloudRealtimeCapacity: return "云端实时服务连接池异常"
        }
    }
}

struct ChannelIncidentState: Codable {
    var activeCategory: ChannelIncidentCategory?
    var recentCategory: ChannelIncidentCategory?
    var firstSeen: Date?
    var lastSeen: Date?
    var recoveredAt: Date?
    var lastProcessedTimelineAt: Date
    var eventCount = 0
    var alertIssued = false
    var recheckAttempt = 0
    var nextRecheck: Date?
    var lastProbeAt: Date?
    var lastProbeResult: String?

    init(now: Date = Date()) { lastProcessedTimelineAt = now }

    mutating func observe(_ category: ChannelIncidentCategory, at date: Date) -> Bool {
        let wasActive = activeCategory != nil
        if !wasActive {
            activeCategory = category
            recentCategory = category
            firstSeen = date
            lastSeen = date
            recoveredAt = nil
            eventCount = 1
            alertIssued = false
            recheckAttempt = 0
            nextRecheck = date
            return true
        }
        if activeCategory == .channelDisruption && category == .cloudRealtimeCapacity {
            activeCategory = .cloudRealtimeCapacity
            recentCategory = .cloudRealtimeCapacity
            alertIssued = false
        }
        lastSeen = max(lastSeen ?? date, date)
        eventCount += 1
        return false
    }

    mutating func markRecovered(at date: Date) {
        guard activeCategory != nil else { return }
        recentCategory = activeCategory
        activeCategory = nil
        recoveredAt = date
        nextRecheck = nil
        recheckAttempt = 0
        alertIssued = false
    }

    mutating func consumeCapacityAlert() -> Bool {
        guard activeCategory == .cloudRealtimeCapacity, !alertIssued else { return false }
        alertIssued = true
        return true
    }

    mutating func scheduleAfterCheck(now: Date) {
        let delays: [TimeInterval] = [10, 20, 40, 80, 120]
        let delay = delays[min(recheckAttempt, delays.count - 1)]
        recheckAttempt += 1
        nextRecheck = now.addingTimeInterval(delay)
    }

    mutating func deferRecheck(now: Date) {
        nextRecheck = now.addingTimeInterval(15)
    }

    func recheckDue(now: Date) -> Bool {
        guard activeCategory != nil, let nextRecheck else { return false }
        return now >= nextRecheck
    }

    func canDeclareRecovered(afterHealthyProbeAt now: Date) -> Bool {
        guard activeCategory != nil, let lastSeen else { return false }
        return now.timeIntervalSince(lastSeen) >= 60
    }

    static func load(from url: URL, now: Date = Date()) -> ChannelIncidentState {
        guard FileManager.default.fileExists(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let data = try? Data(contentsOf: url), data.count <= 8192,
              let value = try? JSONDecoder().decode(ChannelIncidentState.self, from: data) else {
            return ChannelIncidentState(now: now)
        }
        return value
    }

    func save(to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return false }
            let data = try JSONEncoder().encode(self)
            guard data.count <= 8192 else { return false }
            try data.write(to: url, options: .atomic)
            return chmod(url.path, S_IRUSR | S_IWUSR) == 0
        } catch { return false }
    }
}

struct ChannelDecisionRecord: Codable {
    let at: Date
    let kind: String
    let result: String
    let category: String?
    let explicitDisconnects: Int
    let action: String?
}

final class ChannelDecisionJournal {
    private let url: URL
    private let maxBytes: Int

    init(url: URL, maxBytes: Int = 512 * 1024) {
        self.url = url
        self.maxBytes = max(4096, maxBytes)
    }

    @discardableResult
    func append(_ record: ChannelDecisionRecord) -> Bool {
        guard let encoded = try? JSONEncoder().encode(record), encoded.count <= 2048 else { return false }
        var row = encoded; row.append(10)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return false }
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue) ?? 0
            if size + row.count > maxBytes {
                let backup = url.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: backup)
                if size > 0 && size <= maxBytes {
                    try FileManager.default.moveItem(at: url, to: backup)
                    _ = chmod(backup.path, S_IRUSR | S_IWUSR)
                } else if size > maxBytes {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd(); try handle.write(contentsOf: row); try handle.close()
            } else {
                try row.write(to: url, options: .atomic)
            }
            return chmod(url.path, S_IRUSR | S_IWUSR) == 0
        } catch { return false }
    }

    func readRecent(limit: Int = 100) -> [ChannelDecisionRecord] {
        var rows: [ChannelDecisionRecord] = []
        for file in [url.appendingPathExtension("bak"), url] {
            guard let data = try? Data(contentsOf: file), data.count <= maxBytes else { continue }
            for line in data.split(separator: 10) {
                if let item = try? JSONDecoder().decode(ChannelDecisionRecord.self, from: Data(line)) { rows.append(item) }
            }
        }
        return Array(rows.suffix(max(1, limit)))
    }
}

struct ChannelWatchdogState {
    let startedAt: Date
    var lastProbe = Date.distantPast
    var failures = 0
    var status = "启动宽限"
    var detail = "等待 Commander 与日志完成启动"
    var recovering = false

    func isDue(now: Date, intervalSeconds: Int = ActiveProbeBudget.defaultIntervalSeconds) -> Bool { now.timeIntervalSince(startedAt) >= 90 && now.timeIntervalSince(lastProbe) >= TimeInterval(intervalSeconds) && !recovering }
    mutating func observed(_ result: ChannelProbeResult, now: Date) {
        switch result {
        case .healthy:
            failures = 0; status = "通道畅通"; detail = "MCP ping 已往返"
        case .noLiveConnection:
            failures += 1; status = failures >= 3 ? "通道不可用" : "通道异常"; detail = "累计明确断链 \(failures)/3"
        case .unknown(let reason):
            status = "通道状态未知"; detail = reason
        }
    }
    mutating func observedManual(_ result: ChannelProbeResult, now: Date) {
        if case .noLiveConnection = result {
            failures = 0; status = "通道异常"; detail = "手动检查：设备连接不可用"
        } else { observed(result, now: now) }
    }
}

struct ChannelRecoveryLedger: Codable {
    var lastAttempt: Date?
    var autoRecoveryEnabled = true

    func canAttempt(at now: Date) -> Bool { lastAttempt.map { now.timeIntervalSince($0) >= 300 } ?? true }
    mutating func recordAttempt(at now: Date) { lastAttempt = now }
    static func load(from url: URL) -> ChannelRecoveryLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return ChannelRecoveryLedger() }
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let data = try? Data(contentsOf: url), data.count <= 4096,
              let ledger = try? JSONDecoder().decode(ChannelRecoveryLedger.self, from: data) else {
            return ChannelRecoveryLedger(lastAttempt: nil, autoRecoveryEnabled: false)
        }
        return ledger
    }
    func save(to url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return false }
            let data = try JSONEncoder().encode(self)
            guard data.count <= 4096 else { return false }
            try data.write(to: url, options: .atomic)
            return chmod(url.path, S_IRUSR | S_IWUSR) == 0
        } catch { return false }
    }
}

func prominentStamp(_ date: Date?) -> String { date.map { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: $0) } ?? "暂无" }

/// Shared by every Guard tools/call path, including command-line and recovery probes.
/// Reserve before submission: failures/timeouts still consume a slot; denied requests do not.
final class ActiveProbeBudget {
    static let intervalOptions = [300, 600, 900, 1800, 3600, 7200, 10800, 21600]
    static let intervalTitles = intervalOptions.map { seconds in seconds < 3600 ? "每 \(seconds / 60) 分钟" : seconds == 3600 ? "每小时" : "每 \(seconds / 3600) 小时" }
    static let defaultIntervalSeconds = 3600
    static let defaultIntervalIndex = intervalOptions.firstIndex(of: defaultIntervalSeconds)!
    static let shared = ActiveProbeBudget(directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CommanderGuard"))
    struct State: Codable {
        var version = 2
        var enabled = false
        var intervalSeconds = ActiveProbeBudget.defaultIntervalSeconds
        var lastSubmittedAt: Double?
    }
    private struct LegacyState: Decodable {
        let version: Int
        let enabled: Bool
        let attempts: [Double]
    }
    struct Status {
        let enabled: Bool
        let intervalSeconds: Int
        let lastSubmittedAt: Date?
        let now: Date
        let error: String?
        var permissionBlockReason: String? { error ?? (!enabled ? "云端主动探测已关闭" : nil) }
        var nextAllowedAt: Date? { lastSubmittedAt?.addingTimeInterval(TimeInterval(intervalSeconds)) }
        var blockReason: String? {
            permissionBlockReason ?? nextAllowedAt.flatMap { $0 > now ? "探测间隔未到；下次可检查：\(prominentStamp($0))" : nil }
        }
        var dailyEstimate: Int { 86400 / intervalSeconds }
        var intervalTitle: String { ActiveProbeBudget.intervalOptions.firstIndex(of: intervalSeconds).map { ActiveProbeBudget.intervalTitles[$0] } ?? "未知频率" }
        var display: String {
            let detail: String
            if let error { detail = error }
            else if !enabled { detail = "已关闭" }
            else if let nextAllowedAt, nextAllowedAt > now { detail = "下次：\(prominentStamp(nextAllowedAt))" }
            else { detail = "现在可检查" }
            return "\(intervalTitle) · 按此频率约\(dailyEstimate)次/天 · \(detail)"
        }
    }
    private func status(_ state: State, now: Date) -> Status {
        Status(enabled: state.enabled, intervalSeconds: state.intervalSeconds, lastSubmittedAt: state.lastSubmittedAt.map(Date.init(timeIntervalSince1970:)), now: now, error: nil)
    }
    private let directory: URL
    private let localLock = NSLock()
    init(directory: URL) { self.directory = directory }

    func status(now: Date = Date()) -> Status {
        do {
            let fd = try openDirectory(createIfMissing: false); defer { close(fd) }
            // Atomic replacement gives readers a complete snapshot; admission reloads under the lock.
            let state = try load(fd, now: now)
            return status(state, now: now)
        } catch Failure.missingDirectory { return Status(enabled: false, intervalSeconds: Self.defaultIntervalSeconds, lastSubmittedAt: nil, now: now, error: nil) }
        catch { return Status(enabled: false, intervalSeconds: Self.defaultIntervalSeconds, lastSubmittedAt: nil, now: now, error: "探测记录不可用；已暂停") }
    }
    func setEnabled(_ enabled: Bool, now: Date = Date()) -> Bool {
        do { return try locked { fd in var state = try load(fd, now: now); state.enabled = enabled; try save(state, fd); return true } }
        catch { return false }
    }
    func setIntervalSeconds(_ seconds: Int, now: Date = Date()) -> Bool {
        guard Self.intervalOptions.contains(seconds) else { return false }
        do { return try locked { fd in var state = try load(fd, now: now); state.intervalSeconds = seconds; try save(state, fd); return true } }
        catch { return false }
    }
    /// Keep the cross-process lock until the request is submitted, so OFF cannot race admission.
    func submit(now: Date = Date(), _ request: () -> Void) -> String? {
        do {
            return try locked { fd in
                var state = try load(fd, now: now)
                let status = status(state, now: now)
                if let reason = status.blockReason { return reason }
                state.lastSubmittedAt = now.timeIntervalSince1970
                try save(state, fd)
                request()
                return nil
            }
        } catch { return "探测记录无法安全保存；未发送请求" }
    }
    private enum Failure: Error { case unsafeStorage, missingDirectory }
    private func locked<T>(_ body: (Int32) throws -> T) throws -> T {
        localLock.lock(); defer { localLock.unlock() }
        let fd = try openDirectory(); defer { close(fd) }
        let lock = openat(fd, "active-probe.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw Failure.unsafeStorage }
        defer { close(lock) }
        guard safeFile(lock), flock(lock, LOCK_EX) == 0 else { throw Failure.unsafeStorage }
        defer { flock(lock, LOCK_UN) }
        return try body(fd)
    }
    /// Walk with file descriptors: reject symlinks even in ancestors and never follow a replaced path.
    private func openDirectory(createIfMissing: Bool = true) throws -> Int32 {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.pathComponents.contains(".."), !directory.pathComponents.contains(".") else { throw Failure.unsafeStorage }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unsafeStorage }
        do {
            let parts = directory.path.split(separator: "/").map(String.init)
            for (index, part) in parts.enumerated() {
                var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT {
                    guard createIfMissing else { throw Failure.missingDirectory }
                    guard mkdirat(fd, part, 0o700) == 0 || errno == EEXIST else { throw Failure.unsafeStorage }
                    next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw Failure.unsafeStorage }
                var info = stat()
                guard fstat(next, &info) == 0,
                      info.st_uid == 0 || info.st_uid == geteuid(),
                      info.st_mode & 0o022 == 0 || (info.st_uid == 0 && info.st_mode & S_ISVTX != 0 && index < parts.count - 1),
                      index < parts.count - 1 || info.st_uid == geteuid() else { close(next); throw Failure.unsafeStorage }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    private func safeFile(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == geteuid() && info.st_mode & 0o077 == 0 && info.st_nlink == 1
    }
    private func load(_ directoryFD: Int32, now: Date) throws -> State {
        let fd = openat(directoryFD, "active-probe-budget.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return State() }
        guard fd >= 0 else { throw Failure.unsafeStorage }
        defer { close(fd) }
        guard safeFile(fd) else { throw Failure.unsafeStorage }
        var bytes = [UInt8](repeating: 0, count: 4097)
        let count = read(fd, &bytes, bytes.count)
        guard count > 0, count <= 4096, now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else { throw Failure.unsafeStorage }
        let data = Data(bytes.prefix(count))
        struct Version: Decodable { let version: Int }
        guard let version = try? JSONDecoder().decode(Version.self, from: data) else { throw Failure.unsafeStorage }
        let state: State
        if version.version == 1 {
            guard let legacy = try? JSONDecoder().decode(LegacyState.self, from: data), legacy.attempts.count <= 6,
                  legacy.attempts.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= now.timeIntervalSince1970 }) else { throw Failure.unsafeStorage }
            // Raising the old six-call limit requires a new opt-in; preserve its latest reservation.
            state = State(lastSubmittedAt: legacy.attempts.max())
        } else {
            guard version.version == 2, let decoded = try? JSONDecoder().decode(State.self, from: data) else { throw Failure.unsafeStorage }
            state = decoded
        }
        guard Self.intervalOptions.contains(state.intervalSeconds),
              state.lastSubmittedAt.map({ $0.isFinite && $0 >= 0 && $0 <= now.timeIntervalSince1970 }) ?? true else { throw Failure.unsafeStorage }
        return state
    }
    private func save(_ state: State, _ directoryFD: Int32) throws {
        // Never overwrite an unsafe ledger, including a dangling symlink.
        let existing = openat(directoryFD, "active-probe-budget.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if existing >= 0 { defer { close(existing) }; guard safeFile(existing) else { throw Failure.unsafeStorage } }
        else if errno != ENOENT { throw Failure.unsafeStorage }
        let name = ".active-probe-" + UUID().uuidString
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unsafeStorage }
        defer { close(fd); unlinkat(directoryFD, name, 0) }
        let data = try JSONEncoder().encode(state)
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(fd) == 0,
              renameat(directoryFD, name, directoryFD, "active-probe-budget.json") == 0,
              fsync(directoryFD) == 0 else { throw Failure.unsafeStorage }
    }
}

/// Makes one bounded, read-only MCP ping. Credentials are loaded for each request and never surfaced.
final class MCPChannelProbe: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private static let endpoint = URL(string: "https://mcp.desktopcommander.app/mcp")!
    private static let maxResponseBytes = 16 * 1024
    private var session: URLSession!
    private var completion: ((ChannelProbeResult) -> Void)?
    private var body = Data()
    private var http: HTTPURLResponse?
    private var requestID = UUID().uuidString
    private var deviceID = ""
    private(set) var submitted = false

    func run(budget: ActiveProbeBudget = .shared, _ done: @escaping (ChannelProbeResult) -> Void) {
        completion = done; submitted = false
        if let reason = budget.status().blockReason { finish(.unknown(reason)); return }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".desktop-commander-device/device.json")
        guard let data = try? Data(contentsOf: file), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = root["deviceId"] as? String, CloudState.validDeviceID(id),
              let auth = root["session"] as? [String: Any], let token = auth["access_token"] as? String, !token.isEmpty else {
            finish(.unknown("本机登录信息不可用")); return
        }
        deviceID = id
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": requestID, "method": "tools/call", "params": ["name": "ping", "arguments": ["deviceId": id]]])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2024-11-05", forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 10
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())
        if let reason = budget.submit({ self.submitted = true; self.session.dataTask(with: request).resume() }) { finish(.unknown(reason)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.url?.scheme == "https", response.url?.host == "mcp.desktopcommander.app" else {
            completionHandler(.cancel); finish(.unknown("MCP 服务响应未知")); return
        }
        http = response
        if let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), length > Self.maxResponseBytes {
            completionHandler(.cancel); finish(.unknown("MCP 响应超过大小限制")); return
        }
        guard response.statusCode == 200 else { completionHandler(.cancel); finish(.unknown("MCP 服务不可用（HTTP \(response.statusCode)）")); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= Self.maxResponseBytes else { dataTask.cancel(); finish(.unknown("MCP 响应超过大小限制")); return }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error == nil, http?.statusCode == 200 else { finish(.unknown("MCP 网络请求未完成")); return }
        finish(Self.classify(body, id: requestID, deviceID: deviceID))
    }

    private func finish(_ result: ChannelProbeResult) {
        guard let done = completion else { return }
        completion = nil; session?.invalidateAndCancel(); done(result)
    }

    static func classify(_ data: Data, id: String, deviceID: String) -> ChannelProbeResult {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root["jsonrpc"] as? String == "2.0", root["id"] as? String == id else {
            return .unknown("MCP 响应格式或请求编号不匹配")
        }
        let noLive = "This Desktop Commander device has no live connection and cannot receive commands right now."
        if let error = root["error"] as? [String: Any] {
            let code = (error["data"] as? [String: Any])?["error_code"] as? String ?? error["error_code"] as? String
            let message = error["message"] as? String ?? ""
            return (code == nil || code == "INVALID_ARGUMENT") && message.hasPrefix(noLive) && message.contains("(\(deviceID))")
                ? .noLiveConnection : .unknown("MCP 服务返回错误")
        }
        guard let result = root["result"] as? [String: Any], let content = result["content"] as? [[String: Any]] else {
            return .unknown("MCP 响应内容未知")
        }
        let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        guard texts.count == content.count, let first = texts.first else { return .unknown("MCP 响应内容未知") }
        let structured = result["structuredContent"] as? [String: Any]
        let isError = result["isError"] as? Bool == true
        let structuredCode = structured?["error_code"] as? String
        if isError, first.hasPrefix(noLive), first.contains("(\(deviceID))"), structuredCode == nil || structuredCode == "INVALID_ARGUMENT" {
            return .noLiveConnection
        }
        guard !isError else { return .unknown("MCP 服务返回工具错误") }
        guard texts.count == 2, first.range(of: #"^pong \d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z$"#, options: .regularExpression) != nil,
              ISO8601DateFormatter.parse(String(first.dropFirst(5))) != nil,
              texts[1].hasPrefix("\n[executed on device: "), texts[1].hasSuffix(" (\(deviceID))]") else {
            return .unknown("MCP 未返回有效 ping 时间戳")
        }
        return .healthy
    }
}

enum ToolExecutionProbeResult {
    case verified
    case failed(String)
    case unknown(String)
}

/// Verifies the real local tool-execution path with a bounded, read-only tool call.
/// The list_sessions payload is intentionally discarded; only the fixed result class and device attribution survive.
final class MCPToolExecutionProbe: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private static let endpoint = URL(string: "https://mcp.desktopcommander.app/mcp")!
    static let maxResponseBytes = 32 * 1024
    private var session: URLSession!
    private var completion: ((ToolExecutionProbeResult) -> Void)?
    private var body = Data()
    private var http: HTTPURLResponse?
    private var requestID = UUID().uuidString
    private var deviceID = ""
    private(set) var submitted = false

    func run(budget: ActiveProbeBudget = .shared, _ done: @escaping (ToolExecutionProbeResult) -> Void) {
        completion = done; submitted = false
        if let reason = budget.status().blockReason { finish(.unknown(reason)); return }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".desktop-commander-device/device.json")
        guard let data = try? Data(contentsOf: file), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = root["deviceId"] as? String, CloudState.validDeviceID(id),
              let auth = root["session"] as? [String: Any], let token = auth["access_token"] as? String, !token.isEmpty else {
            finish(.unknown("本机登录信息不可用")); return
        }
        deviceID = id
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": requestID, "method": "tools/call", "params": ["name": "list_sessions", "arguments": ["deviceId": id]]])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2024-11-05", forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 10
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())
        if let reason = budget.submit({ self.submitted = true; self.session.dataTask(with: request).resume() }) { finish(.unknown(reason)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.url?.scheme == "https", response.url?.host == "mcp.desktopcommander.app" else {
            completionHandler(.cancel); finish(.unknown("工具服务响应未知")); return
        }
        http = response
        if let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), length > Self.maxResponseBytes {
            completionHandler(.cancel); finish(.unknown("工具检查响应超过大小限制")); return
        }
        guard response.statusCode == 200 else { completionHandler(.cancel); finish(.unknown("工具服务不可用（HTTP \(response.statusCode)）")); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= Self.maxResponseBytes else { dataTask.cancel(); finish(.unknown("工具检查响应超过大小限制")); return }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure = Self.transportFailure(error: error, statusCode: http?.statusCode) { finish(failure); return }
        finish(Self.classify(body, id: requestID, deviceID: deviceID))
    }
    static func transportFailure(error: Error?, statusCode: Int?) -> ToolExecutionProbeResult? {
        if error != nil || statusCode != 200 { return .unknown("工具检查网络请求未完成") }
        return nil
    }
    private func finish(_ result: ToolExecutionProbeResult) {
        guard let done = completion else { return }
        completion = nil; session?.invalidateAndCancel(); done(result)
    }
    static func classify(_ data: Data, id: String, deviceID: String) -> ToolExecutionProbeResult {
        guard data.count <= Self.maxResponseBytes else { return .unknown("工具检查响应超过大小限制") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root["jsonrpc"] as? String == "2.0", root["id"] as? String == id else {
            return .unknown("工具响应格式或请求编号不匹配")
        }
        if let error = root["error"] as? [String: Any] {
            let message = error["message"] as? String ?? ""
            return message.contains(deviceID) && message.contains("no live connection") ? .failed("设备连接不可用") : .unknown("工具服务返回错误")
        }
        guard let result = root["result"] as? [String: Any], let content = result["content"] as? [[String: Any]], !content.isEmpty else {
            return .unknown("工具响应内容未知")
        }
        let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        guard texts.count == content.count else { return .unknown("工具响应包含未知内容") }
        if result["isError"] as? Bool == true { return .failed("本机工具返回错误") }
        let markerPattern = #"^\n?\[executed on device: .+ \("# + NSRegularExpression.escapedPattern(for: deviceID) + #"\)\]$"#
        let attributed = texts.filter { $0.range(of: markerPattern, options: .regularExpression) != nil }
        if attributed.count == 1 { return .verified }
        if texts.contains(where: { $0.contains("[executed on device:") }) { return .unknown("工具响应设备不匹配") }
        return .unknown("工具响应缺少设备归属")
    }
}

enum CommanderProcessTree {
    private struct Entry { let pid: Int32; let parent: Int32; let command: String }

    static func safe(servicePID: Int32, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/ps"); process.arguments = ["-axo", "pid=,ppid=,command="]
        let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
        do { try process.run() } catch { return false }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return process.terminationStatus == 0 && safe(String(data: data, encoding: .utf8) ?? "", servicePID: servicePID, home: home)
    }

    static func safe(_ text: String, servicePID: Int32, home: String) -> Bool {
        guard text.utf8.count <= 1024 * 1024 else { return false }
        var entries: [Int32: Entry] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return false }
            entries[pid] = Entry(pid: pid, parent: parent, command: String(fields[2]))
        }
        guard let root = entries[servicePID], validRoot(root.command, home: home) else { return false }
        var descendants: [Entry] = [], frontier = [servicePID], visited: Set<Int32> = [servicePID]
        while let parent = frontier.popLast() {
            for entry in entries.values where entry.parent == parent {
                guard visited.insert(entry.pid).inserted else { return false }
                descendants.append(entry); frontier.append(entry.pid)
            }
        }
        var nodeCount = 0, helperCount = 0
        for entry in descendants {
            if validMCPChild(entry.command, home: home) { nodeCount += 1 }
            else if validCaffeinate(entry.command, parent: servicePID) { helperCount += 1 }
            else { return false }
        }
        return nodeCount == 1 && helperCount <= 1 && descendants.allSatisfy { entries[$0.pid]?.parent == servicePID }
    }

    private static func validRoot(_ command: String, home: String) -> Bool {
        let args = command.split(whereSeparator: \.isWhitespace).map(String.init)
        return args.count == 3 && validNode(args[0], home: home) && args[1] == "\(home)/.local/share/remote-desktop-commander/node_modules/@wonderwhy-er/desktop-commander/dist/index.js" && args[2] == "remote"
    }
    private static func validMCPChild(_ command: String, home: String) -> Bool {
        let args = command.split(whereSeparator: \.isWhitespace).map(String.init)
        return args.count == 2 && validNode(args[0], home: home) && args[1] == "\(home)/.local/share/remote-desktop-commander/node_modules/@wonderwhy-er/desktop-commander/dist/index.js"
    }
    private static func validNode(_ path: String, home: String) -> Bool {
        path.hasPrefix("\(home)/.nvm/versions/node/v") && path.hasSuffix("/bin/node") && !path.contains("/../")
    }
    private static func validCaffeinate(_ command: String, parent: Int32) -> Bool {
        let args = command.split(whereSeparator: \.isWhitespace).map(String.init)
        return (args.first == "caffeinate" || args.first == "/usr/bin/caffeinate") && args.count == 3 && args[1] == "-w" && args[2] == String(parent)
    }
}

extension ISO8601DateFormatter {
    static let flex: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let httpDate: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"; return f
    }()
    static func parse(_ value: String) -> Date? { flex.date(from: value) ?? plain.date(from: value) }
    static let plain = ISO8601DateFormatter()
}

private func selfTestSessionAttributionParser() {
    let safeID = "123e4567-e89b-12d3-a456-426614174000"
    let rawSession = "private-openai-session-A"
    let sessionLine = Data("🔧 Received tool call \(safeID): read_file {} metadata: {\"openai/session\":\"\(rawSession)\",\"origin_instance\":\"unstable\"}".utf8)
    let sessionAttribution = CommanderActivity.sessionAttribution(sessionLine)
    precondition(sessionAttribution?.source == "openai/session" && sessionAttribution?.key.count == 64 && sessionAttribution?.key.contains(rawSession) == false)
    precondition(CommanderActivity.sessionDisplay(sessionAttribution?.key)?.hasPrefix("会话 ") == true)
    let sameSession = CommanderActivity.sessionAttribution(Data(" metadata: {\"openai/session\":\"\(rawSession)\"}".utf8))
    precondition(sameSession?.key == sessionAttribution?.key)
    let contextAttribution = CommanderActivity.sessionAttribution(Data(" metadata: {\"origin_context_id\":\"opaque-context-B\"}".utf8))
    precondition(contextAttribution?.source == "origin_context_id" && contextAttribution?.key != sessionAttribution?.key)
    let sameDualAttribution = CommanderActivity.sessionAttribution(Data(" metadata: {\"openai/session\":\"\(rawSession)\",\"origin_context_id\":\"\(rawSession)\"}".utf8))
    precondition(sameDualAttribution?.key == sessionAttribution?.key && sameDualAttribution?.source == "openai/session" && sameDualAttribution?.conflict == false)
    let conflictingDualAttribution = CommanderActivity.sessionAttribution(Data(" metadata: {\"openai/session\":\"\(rawSession)\",\"origin_context_id\":\"different-context\"}".utf8))
    precondition(conflictingDualAttribution?.conflict == true && conflictingDualAttribution?.key.isEmpty == true)
    precondition(CommanderActivity.sessionAttribution(Data(" metadata: {\"origin_instance\":\"not-a-session\"}".utf8)) == nil)
    precondition(CommanderActivity.sessionAttribution(Data(" metadata: {\"openai/session\":\"bad\\nvalue\"}".utf8)) == nil)
    let tooLongSession = String(repeating: "s", count: 513)
    precondition(CommanderActivity.sessionAttribution(Data(" metadata: {\"openai/session\":\"\(tooLongSession)\"}".utf8)) == nil)
}

private func selfTestSessionAttributionReader(dir: URL, now: Date) {
    let rawSession = "private-openai-session-A"
    let expected = CommanderActivity.sessionAttribution(Data(" metadata: {\"openai/session\":\"\(rawSession)\"}".utf8))!
    let attributionLog = dir.appendingPathComponent("session-attribution.log")
    FileManager.default.createFile(atPath: attributionLog.path, contents: Data("🚀 Starting MCP Device...\n".utf8))
    let attributionReader = ActivityLogReader(url: attributionLog); attributionReader.poll(); attributionReader.poll()
    func appendAttribution(_ value: String) { let handle = try! FileHandle(forWritingTo: attributionLog); try! handle.seekToEnd(); try! handle.write(contentsOf: Data(value.utf8)); try! handle.close() }
    let attributedID = "f23e4567-e89b-12d3-a456-426614174000"
    appendAttribution("🔧 Received tool call \(attributedID): read_file {} metadata: {\"openai/session\":\"\(rawSession)\",\"origin_instance\":\"unstable-1\"}\n")
    attributionReader.poll(now: now, uptime: 50)
    precondition(attributionReader.summary.steps.first?.sessionKey == expected.key && attributionReader.summary.steps.first?.sessionSource == "openai/session" && !attributionReader.summary.steps.first!.sessionAttributionConflict)
    appendAttribution("🔧 Received tool call \(attributedID): read_file {} metadata: {\"origin_context_id\":\"conflicting-context\"}\n")
    attributionReader.poll(now: now.addingTimeInterval(1), uptime: 51)
    precondition(attributionReader.summary.steps.first?.sessionKey == nil && attributionReader.summary.steps.first?.sessionAttributionConflict == true)
    appendAttribution("✅ Tool call read_file completed: done\n")
    attributionReader.poll(now: now.addingTimeInterval(2), uptime: 52)
    precondition(attributionReader.summary.activeCount == 0 && !attributionReader.summary.coverageGap)

    let oversizedLog = dir.appendingPathComponent("session-attribution-oversized.log")
    FileManager.default.createFile(atPath: oversizedLog.path, contents: Data("🚀 Starting MCP Device...\n".utf8))
    let oversizedReader = ActivityLogReader(url: oversizedLog); oversizedReader.poll(); oversizedReader.poll()
    let oversizedID = "f33e4567-e89b-12d3-a456-426614174000"
    let oversizedRawSession = "oversized-openai-session"
    let oversizedExpected = CommanderActivity.sessionAttribution(Data(" metadata: {\"openai/session\":\"\(oversizedRawSession)\"}".utf8))!
    let oversizedLine = "🔧 Received tool call \(oversizedID): read_file {\"padding\":\"" + String(repeating: "x", count: 20_000) + "\"} metadata: {\"openai/session\":\"\(oversizedRawSession)\"}\n"
    let oversizedHandle = try! FileHandle(forWritingTo: oversizedLog); try! oversizedHandle.seekToEnd(); try! oversizedHandle.write(contentsOf: Data(oversizedLine.utf8)); try! oversizedHandle.close()
    oversizedReader.poll(now: now, uptime: 60)
    precondition(oversizedReader.summary.steps.first?.id == oversizedID && oversizedReader.summary.steps.first?.sessionKey == oversizedExpected.key && oversizedReader.summary.steps.first?.sessionSource == "openai/session" && !oversizedReader.summary.coverageGap)
    let oversizedCompletion = try! FileHandle(forWritingTo: oversizedLog); try! oversizedCompletion.seekToEnd(); try! oversizedCompletion.write(contentsOf: Data("✅ Tool call read_file completed: done\n".utf8)); try! oversizedCompletion.close()
    oversizedReader.poll(now: now.addingTimeInterval(1), uptime: 61)
    precondition(oversizedReader.summary.activeCount == 0 && !oversizedReader.summary.coverageGap && activitySafeForRecovery(oversizedReader.summary))
}

private func selfTestActiveProbeBudget(dir: URL, now: Date) {
    let physicalPath = dir.path.hasPrefix("/var/") ? "/private" + dir.path : dir.path
    let physicalDir = URL(fileURLWithPath: physicalPath, isDirectory: true)
    let directory = physicalDir.appendingPathComponent("active-budget")
    let budget = ActiveProbeBudget(directory: directory)
    var submitted = 0
    let expectedSubmissions = ActiveProbeBudget.intervalOptions.count * 2
    var lastSubmittedAt = now
    precondition(ActiveProbeBudget.intervalOptions == [300, 600, 900, 1800, 3600, 7200, 10800, 21600])
    precondition(ActiveProbeBudget.intervalTitles == ["每 5 分钟", "每 10 分钟", "每 15 分钟", "每 30 分钟", "每小时", "每 2 小时", "每 3 小时", "每 6 小时"])
    precondition(ActiveProbeBudget.intervalOptions[ActiveProbeBudget.defaultIntervalIndex] == ActiveProbeBudget.defaultIntervalSeconds)
    precondition(!budget.status(now: now).enabled && budget.status(now: now).intervalSeconds == 3600 && budget.status(now: now).lastSubmittedAt == nil)
    precondition(budget.submit(now: now, { submitted += 1 }) != nil && submitted == 0)
    precondition(budget.setIntervalSeconds(600, now: now) && !budget.status(now: now).enabled, "Changing frequency must not grant permission")
    // OFF and cadence denial happen before loading real credentials or sending a request.
    let ping = MCPChannelProbe(), tool = MCPToolExecutionProbe()
    var pingDenied = false, toolDenied = false
    ping.run(budget: budget) { if case .unknown(let reason) = $0 { pingDenied = reason == "云端主动探测已关闭" } }
    tool.run(budget: budget) { if case .unknown(let reason) = $0 { toolDenied = reason == "云端主动探测已关闭" } }
    precondition(pingDenied && toolDenied && !ping.submitted && !tool.submitted)
    precondition(budget.setEnabled(true, now: now))
    for (index, interval) in ActiveProbeBudget.intervalOptions.enumerated() {
        let moment = now.addingTimeInterval(Double(index * 50000))
        precondition(budget.setIntervalSeconds(interval, now: moment))
        precondition(budget.submit(now: moment, { submitted += 1 }) == nil)
        let reopened = ActiveProbeBudget(directory: directory)
        let status = reopened.status(now: moment)
        precondition(status.lastSubmittedAt == moment && status.nextAllowedAt == moment.addingTimeInterval(Double(interval)))
        precondition(status.permissionBlockReason == nil && status.blockReason != nil, "Cadence must not revoke recovery permission")
        precondition(status.dailyEstimate == [288, 144, 96, 48, 24, 12, 8, 4][index] && status.intervalTitle == ActiveProbeBudget.intervalTitles[index])
        precondition(reopened.submit(now: moment.addingTimeInterval(Double(interval - 1)), { submitted += 1 }) != nil)
        precondition(budget.setEnabled(false, now: moment) && budget.setEnabled(true, now: moment))
        precondition(budget.submit(now: moment, { submitted += 1 }) != nil)
        lastSubmittedAt = moment.addingTimeInterval(Double(interval))
        precondition(budget.submit(now: lastSubmittedAt, { submitted += 1 }) == nil)
    }
    precondition(submitted == expectedSubmissions)
    let expiry = now.addingTimeInterval(Double(ActiveProbeBudget.intervalOptions.count * 50000))
    precondition(!budget.setIntervalSeconds(60, now: expiry))
    precondition(budget.setIntervalSeconds(600, now: expiry) && budget.status(now: expiry).lastSubmittedAt == lastSubmittedAt)
    precondition(budget.status(now: now).error != nil, "A backwards clock must fail closed")
    let ledger = directory.appendingPathComponent("active-probe-budget.json")
    try! Data("invalid".utf8).write(to: ledger)
    precondition(budget.status(now: expiry).error != nil && !budget.setEnabled(true, now: expiry))
    precondition(budget.submit(now: expiry, { submitted += 1 }) != nil && submitted == expectedSubmissions)
    // Safe legacy state requires a new opt-in and keeps its last submitted timestamp.
    let legacy = "{\"version\":1,\"enabled\":true,\"attempts\":[\(expiry.timeIntervalSince1970)]}"
    try! Data(legacy.utf8).write(to: ledger)
    precondition(!budget.status(now: expiry).enabled && budget.status(now: expiry).lastSubmittedAt == expiry)
    precondition(budget.setEnabled(true, now: expiry) && budget.status(now: expiry).blockReason != nil)
    for invalid in ["{\"version\":3,\"enabled\":true,\"intervalSeconds\":600}", "{\"version\":2,\"enabled\":true,\"intervalSeconds\":60}", "{\"version\":2,\"enabled\":true,\"intervalSeconds\":600,\"lastSubmittedAt\":\(expiry.timeIntervalSince1970 + 1)}"] {
        try! Data(invalid.utf8).write(to: ledger)
        precondition(budget.status(now: expiry).error != nil && budget.submit(now: expiry, { submitted += 1 }) != nil)
    }
    try! FileManager.default.removeItem(at: ledger)
    try! FileManager.default.createSymbolicLink(atPath: ledger.path, withDestinationPath: dir.appendingPathComponent("missing").path)
    precondition(budget.status(now: expiry).error != nil && budget.submit(now: expiry, { submitted += 1 }) != nil)
    let linkedDirectory = physicalDir.appendingPathComponent("linked-budget")
    try! FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: directory)
    precondition(ActiveProbeBudget(directory: linkedDirectory).status(now: expiry).error != nil)
    let failingDirectory = physicalDir.appendingPathComponent("cannot-persist")
    let failing = ActiveProbeBudget(directory: failingDirectory)
    precondition(failing.setEnabled(true, now: now))
    precondition(chmod(failingDirectory.path, 0o500) == 0)
    precondition(failing.submit(now: now, { submitted += 1 }) != nil && submitted == expectedSubmissions)
    precondition(failing.status(now: now).lastSubmittedAt == nil, "Failed persistence must not reserve or send")
    precondition(chmod(failingDirectory.path, 0o700) == 0)
    let concurrentDirectory = physicalDir.appendingPathComponent("concurrent-budget")
    precondition(ActiveProbeBudget(directory: concurrentDirectory).setEnabled(true, now: now))
    let countLock = NSLock()
    var concurrentSubmissions = 0
    DispatchQueue.concurrentPerform(iterations: 12) { _ in
        _ = ActiveProbeBudget(directory: concurrentDirectory).submit(now: now) {
            countLock.lock(); concurrentSubmissions += 1; countLock.unlock()
        }
    }
    precondition(concurrentSubmissions == 1 && ActiveProbeBudget(directory: concurrentDirectory).status(now: now).lastSubmittedAt == now)
    // Actual entry points reject timing before credential reads; this ledger is isolated.
    let waiting = ActiveProbeBudget(directory: physicalDir.appendingPathComponent("waiting-budget"))
    let liveNow = Date()
    precondition(waiting.setEnabled(true, now: liveNow) && waiting.submit(now: liveNow, {}) == nil)
    let waitingPing = MCPChannelProbe(), waitingTool = MCPToolExecutionProbe()
    var pingTimingDenied = false, toolTimingDenied = false
    waitingPing.run(budget: waiting) { if case .unknown(let reason) = $0 { pingTimingDenied = reason.contains("探测间隔未到") } }
    waitingTool.run(budget: waiting) { if case .unknown(let reason) = $0 { toolTimingDenied = reason.contains("探测间隔未到") } }
    precondition(pingTimingDenied && toolTimingDenied && !waitingPing.submitted && !waitingTool.submitted)

}

func selfTest() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    func quota(_ usage: [String: Any]) -> UsageQuota? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["usage": usage]) else { return nil }
        return UsageQuota.parse(data, now: now)
    }
    let freeQuota = quota(["plan": "free", "callsUsed": 100, "callsIncluded": 100, "month": "2026-10"])
    precondition(freeQuota?.remaining == 0 && freeQuota?.state == .fresh && freeQuota?.month == "2026-10")
    let proQuota = quota(["plan": "pro", "callsUsed": 90, "callsIncluded": NSNull()])
    precondition(proQuota?.state == .unlimited && proQuota?.total == nil && proQuota?.remaining == nil)
    precondition(quota(["plan": "free", "callsUsed": 1, "callsIncluded": NSNull()]) == nil)
    precondition(quota(["plan": "enterprise", "callsUsed": 1, "callsIncluded": 10]) == nil)
    precondition(quota(["plan": "free", "callsUsed": -1, "callsIncluded": 10]) == nil)
    precondition(quota(["plan": "free", "callsUsed": true, "callsIncluded": 10]) == nil)
    precondition(quota(["plan": "free", "callsUsed": 1, "callsIncluded": true]) == nil)
    precondition(quota(["plan": "free", "callsUsed": 1, "callsIncluded": 1_000_000_001]) == nil)
    precondition(quota(["plan": "free", "callsUsed": 1, "callsIncluded": 10, "month": "2026-13"]) == nil)
    precondition(quota(["plan": "free", "callsUsed": 1, "callsIncluded": 10, "month": 202610]) == nil)
    precondition(UsageQuota.parse(Data(repeating: 65, count: 8193), now: now) == nil)
    precondition(UsageQuota(state: .loginRequired).used == nil && UsageQuota(state: .loginRequired).total == nil)
    precondition(quotaRefreshOptions == [0, 60, 120, 300, 600, 1800, 3600] && quotaRefreshOptions.allSatisfy { sanitizedQuotaRefreshSeconds($0) == $0 } && sanitizedQuotaRefreshSeconds(nil) == 300 && sanitizedQuotaRefreshSeconds(121) == 300)
    precondition(quotaStaleInterval(for: 0) == 900 && quotaStaleInterval(for: 300) == 900 && quotaStaleInterval(for: 600) == 1260 && UsageQuota.State.refreshing.rawValue == "refreshing")
    precondition(quotaIsStale(freeQuota!, now: now.addingTimeInterval(901)) && !quotaIsStale(freeQuota!, now: now.addingTimeInterval(899)))
    precondition(!quotaIsStale(freeQuota!, now: now.addingTimeInterval(1260), refreshSeconds: 600) && quotaIsStale(freeQuota!, now: now.addingTimeInterval(1261), refreshSeconds: 600))
    try! HeadlessQuotaBrowser.runOfflineChecks()
    precondition(trustedQuotaURL(URL(string: "https://mcp.desktopcommander.app/usage")))
    precondition(!trustedQuotaURL(URL(string: "https://auth.desktopcommander.app/auth")))
    precondition(!trustedQuotaURL(URL(string: "https://mcp.desktopcommander.app/usage/extra")))
    precondition(!trustedQuotaURL(URL(string: "http://mcp.desktopcommander.app/usage")))
    precondition(!trustedQuotaURL(URL(string: "https://example.com/usage")))
    precondition(!trustedQuotaURL(URL(string: "https://user@mcp.desktopcommander.app/usage")))
    precondition(!trustedQuotaURL(URL(string: "https://mcp.desktopcommander.app:444/usage")))
    let fresh = now.addingTimeInterval(-300)
    let device = "00000000-0000-4000-8000-000000000001"
    func probeKind(_ value: ChannelProbeResult) -> Int {
        switch value { case .healthy: return 0; case .noLiveConnection: return 1; case .unknown: return 2 }
    }
    func classifyProbe(_ object: [String: Any], id: String = "request") -> Int {
        probeKind(MCPChannelProbe.classify(try! JSONSerialization.data(withJSONObject: object), id: id, deviceID: device))
    }
    let pong: [String: Any] = ["jsonrpc": "2.0", "id": "request", "result": ["content": [["type": "text", "text": "pong 2026-10-03T02:00:18.395Z"], ["type": "text", "text": "\n[executed on device: Mac-mini.local (\(device))]"]]]]
    precondition(classifyProbe(pong) == 0 && classifyProbe(pong, id: "other") == 2)
    var falsePong = pong; falsePong["result"] = ["isError": true, "content": [["type": "text", "text": "pong 2026-10-03T02:00:18.395Z"], ["type": "text", "text": "\n[executed on device: Mac-mini.local (\(device))]"]]]
    precondition(classifyProbe(falsePong) == 2)
    let noLive = "This Desktop Commander device has no live connection and cannot receive commands right now. Restart the terminal running it, then try again. [device: Mac-mini.local (\(device))]"
    precondition(classifyProbe(["jsonrpc": "2.0", "id": "request", "error": ["code": -32602, "message": noLive]]) == 1)
    precondition(classifyProbe(["jsonrpc": "2.0", "id": "request", "error": ["code": -32602, "message": noLive, "data": ["error_code": "OTHER"]]]) == 2)
    precondition(classifyProbe(["jsonrpc": "2.0", "id": "request", "result": ["isError": true, "content": [["type": "text", "text": noLive]], "structuredContent": ["error_code": "INVALID_ARGUMENT"]]]) == 1)
    func toolProbeKind(_ value: ToolExecutionProbeResult) -> Int {
        switch value { case .verified: return 0; case .failed: return 1; case .unknown: return 2 }
    }
    func classifyTool(_ object: [String: Any], id: String = "tool-request") -> Int {
        toolProbeKind(MCPToolExecutionProbe.classify(try! JSONSerialization.data(withJSONObject: object), id: id, deviceID: device))
    }
    let toolOK: [String: Any] = ["jsonrpc": "2.0", "id": "tool-request", "result": ["content": [["type": "text", "text": "No active terminal sessions"], ["type": "text", "text": "\n[executed on device: Mac-mini.local (\(device))]"]]]]
    precondition(classifyTool(toolOK) == 0 && classifyTool(toolOK, id: "wrong") == 2)
    let wrongDevice: [String: Any] = ["jsonrpc": "2.0", "id": "tool-request", "result": ["content": [["type": "text", "text": "ok"], ["type": "text", "text": "\n[executed on device: Other Mac (00000000-0000-4000-8000-000000000099)]"]]]]
    precondition(classifyTool(wrongDevice) == 2)
    let toolError: [String: Any] = ["jsonrpc": "2.0", "id": "tool-request", "result": ["isError": true, "content": [["type": "text", "text": "failed"]]]]
    precondition(classifyTool(toolError) == 1)
    precondition(classifyTool(["jsonrpc": "2.0", "id": "tool-request", "result": ["content": []]]) == 2)
    precondition(toolProbeKind(MCPToolExecutionProbe.classify(Data(repeating: 65, count: MCPToolExecutionProbe.maxResponseBytes + 1), id: "tool-request", deviceID: device)) == 2)
    let timeoutError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
    precondition(toolProbeKind(MCPToolExecutionProbe.transportFailure(error: timeoutError, statusCode: nil)!) == 2)
    precondition(MCPToolExecutionProbe.transportFailure(error: nil, statusCode: 200) == nil)
    precondition(actualProbeTimestamp(submitted: false, at: now) == nil && actualProbeTimestamp(submitted: true, at: now) == ISO8601DateFormatter.flex.string(from: now))
    var watchdogTest = ChannelWatchdogState(startedAt: now)
    precondition(!watchdogTest.isDue(now: now.addingTimeInterval(89)) && watchdogTest.isDue(now: now.addingTimeInterval(90)))
    watchdogTest.lastProbe = now.addingTimeInterval(90)
    precondition(!watchdogTest.isDue(now: now.addingTimeInterval(689), intervalSeconds: 600) && watchdogTest.isDue(now: now.addingTimeInterval(690), intervalSeconds: 600))
    for n in 1...3 { watchdogTest.observed(.noLiveConnection, now: now.addingTimeInterval(Double(90 + n * 30))); precondition(watchdogTest.failures == n) }
    watchdogTest.observed(.unknown("网络未知"), now: now.addingTimeInterval(200)); precondition(watchdogTest.failures == 3, "Unknown probes must preserve explicit disconnect history")
    watchdogTest.observed(.healthy, now: now.addingTimeInterval(230)); precondition(watchdogTest.failures == 0 && watchdogTest.status == "通道畅通")
    watchdogTest.observed(.noLiveConnection, now: now.addingTimeInterval(240))
    watchdogTest.observed(.unknown("服务未知"), now: now.addingTimeInterval(250))
    watchdogTest.observed(.noLiveConnection, now: now.addingTimeInterval(260))
    precondition(watchdogTest.failures == 2, "Unknown results are neither success nor another explicit disconnect")
    for _ in 0..<5 { watchdogTest.observedManual(.noLiveConnection, now: now); precondition(watchdogTest.failures == 0 && watchdogTest.status == "通道异常") }
    watchdogTest.observed(.noLiveConnection, now: now); precondition(watchdogTest.failures == 1)
    watchdogTest.observedManual(.healthy, now: now); precondition(watchdogTest.failures == 0 && watchdogTest.status == "通道畅通")
    var ledgerTest = ChannelRecoveryLedger(); ledgerTest.recordAttempt(at: now)
    precondition(!ledgerTest.canAttempt(at: now.addingTimeInterval(299)) && ledgerTest.canAttempt(at: now.addingTimeInterval(300)))
    precondition(!recoveryConfirmed(oldPID: 100, newPID: nil, currentPID: nil, oldProcessExited: true, probe: .healthy))
    precondition(!recoveryConfirmed(oldPID: 100, newPID: 100, currentPID: 100, oldProcessExited: true, probe: .healthy))
    precondition(!recoveryConfirmed(oldPID: 100, newPID: 101, currentPID: 101, oldProcessExited: true, probe: .unknown("未知")))
    precondition(recoveryConfirmed(oldPID: 100, newPID: 101, currentPID: 101, oldProcessExited: true, probe: .healthy))
    precondition(!recoveryConfirmed(oldPID: 100, newPID: 101, currentPID: 102, oldProcessExited: true, probe: .healthy))
    precondition(!recoveryConfirmed(oldPID: 100, newPID: 101, currentPID: 101, oldProcessExited: false, probe: .healthy))
    precondition(activitySafeForRecovery(ActivitySummary(state: "未观察到新调用", idleProven: true)))
    precondition(!activitySafeForRecovery(ActivitySummary(state: "未观察到新调用", coverageGap: true)))
    precondition(callState(ActivitySummary(state: "未观察到新调用", coverageGap: true)) == "状态未确认")
    precondition(!activitySafeForRecovery(ActivitySummary(state: "收到调用（处理中）", active: ["read_file": 1])))
    let rootCommand = "/test/.nvm/versions/node/v22.0.0/bin/node /test/.local/share/remote-desktop-commander/node_modules/@wonderwhy-er/desktop-commander/dist/index.js"
    let safeTree = "100 1 \(rootCommand) remote\n101 100 \(rootCommand)\n102 100 /usr/bin/caffeinate -w 100\n"
    precondition(CommanderProcessTree.safe(safeTree, servicePID: 100, home: "/test"))
    precondition(!CommanderProcessTree.safe(safeTree + "103 101 sleep 30\n", servicePID: 100, home: "/test"))
    precondition(!CommanderProcessTree.safe(safeTree.replacingOccurrences(of: "/test/.nvm/versions/node/v22.0.0/bin/node", with: "/tmp/node"), servicePID: 100, home: "/test"))
    precondition(channelIndicator(service: "运行中", state: "启动宽限", checked: nil, now: now) == "?")
    precondition(channelIndicator(service: "运行中", state: "通道畅通", checked: now.addingTimeInterval(-30), now: now) == "●")
    precondition(channelIndicator(service: "运行中", state: "通道畅通", checked: now.addingTimeInterval(-76), now: now) == "?")
    precondition(channelIndicator(service: "运行中", state: "通道不可用", checked: now, now: now) == "!")
    precondition(channelIndicator(service: "未运行", state: "通道畅通", checked: now, now: now) == "!")
    precondition(displayEvidenceTime(now.addingTimeInterval(-90), now: now).contains("分钟前"))
    precondition(!displayEvidenceTime(now.addingTimeInterval(60), now: now).contains("前"))
    precondition(activityOverviewText(ActivitySummary(state: "未观察到新调用")) == "尚无法确认空闲")
    precondition(activityOverviewText(ActivitySummary(state: "未观察到新调用", idleProven: true)) == "已确认空闲")
    let chatOverview = ChatMonitorSummary(answer: "当前未见异常", connection: "更新连接已建立", history: nil)
    precondition(chatOverviewTitle(chatOverview) == "连接正常" && chatOverviewDetail(chatOverview).contains("原回答是否完整：无法确认"))
    precondition(chatOverviewTitle(ChatMonitorSummary(answer: "回答异常（恢复未确认）", connection: "更新连接已建立", history: nil)) == "回答异常")
    precondition(chatOverviewDetail(ChatMonitorSummary(answer: "回答恢复已记录", connection: "更新连接已建立", history: nil)) == "记录到回答恢复完成")
    precondition(wakePreventionSummary(enabled: true, serviceRunning: true, assertionActive: true) == "Guard 正在防止闲置睡眠")
    precondition(wakePreventionSummary(enabled: true, serviceRunning: false, assertionActive: false) == "等待 Commander 服务运行")
    precondition(wakePreventionSummary(enabled: false, serviceRunning: true, assertionActive: false) == "已关闭")
    var displaySnapshot = Snapshot(service: "运行中", channelState: "通道畅通", channelChecked: now)
    precondition(channelSummary(displaySnapshot, now: now).contains("上次探测成功"))
    for age in [76.0, 600.0, 3600.0] {
        precondition(channelSummary(displaySnapshot, now: now.addingTimeInterval(age)) == "上次探测成功" && channelIndicator(service: displaySnapshot.service, state: displaySnapshot.channelState, checked: displaySnapshot.channelChecked, now: now.addingTimeInterval(age)) == "?")
    }
    displaySnapshot.channelChecked = nil
    precondition(channelSummary(displaySnapshot, now: now) == "探测结果待核对")
    displaySnapshot.channelChecked = now.addingTimeInterval(1)
    precondition(channelSummary(displaySnapshot, now: now) == "探测结果待核对")
    displaySnapshot.channelChecked = now
    displaySnapshot.service = "未运行"
    precondition(channelSummary(displaySnapshot, now: now) == "Commander 服务未运行")
    precondition(CloudState.classify(status: "online", lastSeen: fresh, now: now) == "服务器登记在线")
    precondition(CloudState.classify(status: "offline", lastSeen: fresh, now: now).contains("离线"))
    precondition(CloudState.classify(status: nil, lastSeen: nil, now: now).contains("未知"))
    precondition(CloudState.classify(status: "online", lastSeen: now.addingTimeInterval(-901), now: now).contains("过期"))
    precondition(CloudState.classify(status: "online", lastSeen: now.addingTimeInterval(600), now: now, serverDate: now.addingTimeInterval(900)).contains("在线"))
    precondition(CloudState.classify(status: "online", lastSeen: now.addingTimeInterval(600), now: now).contains("异常"))
    precondition(ISO8601DateFormatter.parse("2026-10-01T08:32:58+0800") != nil)
    precondition(CloudState.trustedBackend("https://olvbkozcufcbptfogatw.supabase.co") != nil)
    precondition(CloudState.trustedBackend("http://olvbkozcufcbptfogatw.supabase.co") == nil)
    precondition(CloudState.trustedBackend("https://other.supabase.co") == nil)
    precondition(CloudState.trustedBackend("https://olvbkozcufcbptfogatw.supabase.co/evil") == nil)
    precondition(CloudState.trustedBackend("https://olvbkozcufcbptfogatw.supabase.co?x=1") == nil)
    precondition(CloudState.validDeviceID("not-a-uuid") == false)
    let pending = ActivityStep(id: "call-1", tool: "read_file", detail: "读取文件", startedAt: now, startedUptime: 10, duration: nil)
    precondition(barCallClock(nil, uptime: 11) == "待调用")
    precondition(barCallClock(pending, uptime: 12) == "2 秒")
    precondition(barCallClock(pending, uptime: 13) == "3 秒")
    var completed = pending; completed.duration = 2; completed.finished = true
    precondition(barCallClock(completed, uptime: 99) == "2 秒")
    let evidenceActivity = ActivitySummary(steps: [completed])
    precondition(recentSuccessfulToolExecution(evidenceActivity, now: now.addingTimeInterval(2)) == now.addingTimeInterval(2))
    precondition(recentSuccessfulToolExecution(evidenceActivity, now: now.addingTimeInterval(123)) == nil)
    var toolSnapshot = Snapshot(); toolSnapshot.toolExecutionState = "已验证"; toolSnapshot.toolExecutionChecked = now
    precondition(toolExecutionFresh(toolSnapshot, now: now.addingTimeInterval(120)))
    precondition(!toolExecutionFresh(toolSnapshot, now: now.addingTimeInterval(121)))
    precondition(evidenceActivity.steps[0].tool == "read_file", "Tool evidence fixture changed")
    var probeOnly = completed; probeOnly = ActivityStep(id: probeOnly.id, tool: "list_sessions", detail: probeOnly.detail, startedAt: probeOnly.startedAt, startedUptime: probeOnly.startedUptime, duration: probeOnly.duration, uncertain: probeOnly.uncertain, failed: probeOnly.failed, historical: probeOnly.historical, finished: probeOnly.finished)
    precondition(recentSuccessfulToolExecution(ActivitySummary(steps: [probeOnly]), now: now.addingTimeInterval(2)) == nil)
    precondition(activityStepRows([pending], uptime: 13)[0].contains("●  读取文件  · 进行中 3 秒") && !activityStepRows([pending], uptime: 13)[0].contains("归属"))
    precondition(activityStepRows([completed], uptime: 99)[0].contains("✓  读取文件  · 2 秒") && !activityStepRows([completed], uptime: 99)[0].contains("归属"))
    var failedStep = completed; failedStep.failed = true
    precondition(activityStepRows([failedStep], uptime: 99)[0].contains("!  读取文件  · 2 秒") && !activityStepRows([failedStep], uptime: 99)[0].contains("归属"))
    var uncertainStep = failedStep; uncertainStep.uncertain = true
    precondition(activityStepRows([uncertainStep], uptime: 99)[0].contains("?  读取文件  · 未确认") && !activityStepRows([uncertainStep], uptime: 99)[0].contains("归属"))
    var attributed = pending; attributed.sessionKey = String(repeating: "a", count: 64)
    precondition(activityStepRows([attributed], uptime: 13)[0].contains("[会话 AAAAAAAAAA]"))
    attributed.sessionAttributionConflict = true
    precondition(activityStepRows([attributed], uptime: 13)[0].contains("[归属冲突]"))
    let uiTimeline = [TimelineEvent(source: "commander", event: "调用receipt: 读取文件", sourceAt: nil, observedAt: ""), TimelineEvent(source: "commander", event: "调用completion: 读取文件", sourceAt: nil, observedAt: ""), TimelineEvent(source: "commander", event: "调用error: 未匹配步骤", sourceAt: nil, observedAt: ""), TimelineEvent(source: "commander", event: "Commander错误: 通道错误", sourceAt: nil, observedAt: ""), TimelineEvent(source: "chatgpt_app", event: "chatgpt_pubsub_transport_opened", sourceAt: nil, observedAt: "")]
    precondition(visibleTimelineEvents(uiTimeline).map(\.event) == ["调用error: 未匹配步骤", "Commander错误: 通道错误", "chatgpt_pubsub_transport_opened"])
    let nextCall = ActivityStep(id: "call-2", tool: "read_file", detail: "读取文件", startedAt: now, startedUptime: 20, duration: nil)
    precondition(barCallClock(nextCall, uptime: 20) == "<1 秒")
    precondition(barCallClock(nextCall, uptime: 21) == "1 秒")
    var unknown = pending; unknown.uncertain = true
    precondition(barCallClock(unknown, uptime: 12) == "耗时未确认")
    var justReturned = ActivitySummary(state: "本机已返回（云端结果未知）", observedUptime: 12,
        steps: [ActivityStep(id: "call-1", tool: "read_file", detail: "读取文件", startedAt: now, startedUptime: 10, duration: 2)])
    justReturned.returnedStepID = "call-1"
    precondition(recentlyReturnedCall(justReturned, uptime: 12)?.duration == 2)
    precondition(recentlyReturnedCall(justReturned, uptime: 14.999) != nil)
    precondition(recentlyReturnedCall(justReturned, uptime: 15) == nil)
    precondition(recentlyReturnedCall(justReturned, uptime: 11) == nil)
    precondition(recentlyReturnedCall(justReturned, uptime: .infinity) == nil)
    var activeReturned = justReturned; activeReturned.active = ["read_file": 1]
    precondition(recentlyReturnedCall(activeReturned, uptime: 12) == nil)
    for state in ["本机异常（云端结果未知）", "调用状态未确认", "调用状态未确认（日志有间隔）"] {
        var hidden = justReturned; hidden.state = state
        precondition(recentlyReturnedCall(hidden, uptime: 12) == nil)
    }
    var erroredReturn = justReturned; erroredReturn.error = true
    precondition(recentlyReturnedCall(erroredReturn, uptime: 12) == nil)
    var uncertainReturn = justReturned; uncertainReturn.steps[0].uncertain = true
    precondition(recentlyReturnedCall(uncertainReturn, uptime: 12) == nil)
    var invalidDuration = justReturned; invalidDuration.steps[0].duration = -.infinity
    precondition(recentlyReturnedCall(invalidDuration, uptime: 12) == nil)
    var unmatchedCompletion = justReturned; unmatchedCompletion.observedUptime = 13; unmatchedCompletion.returnedStepID = nil
    precondition(recentlyReturnedCall(unmatchedCompletion, uptime: 13) == nil)
    precondition(callState(ActivitySummary(state: "本机已返回（云端结果未知）", idleProven: true)) == "未观察到新调用")
    precondition(callState(ActivitySummary()) == "状态未确认")
    precondition(callState(ActivitySummary(state: "调用状态未确认（日志有间隔）")) == "状态未确认")
    precondition(callState(ActivitySummary(state: "未观察到新调用", error: true)) == "状态未确认")
    let failedRead = ActivitySummary(state: "日志读取异常 / 状态未知", steps: [pending], active: ["read_file": 1], error: true)
    precondition(currentCallStep(failedRead) == nil && callState(failedRead) == "状态未确认")
    var untracked = ActivitySummary(state: "收到调用（处理中）", active: ["read_file": 1])
    precondition(currentCallStep(untracked) == nil && callState(untracked) == "状态未确认")
    untracked.steps = [unknown]
    precondition(currentCallStep(untracked)?.uncertain == true && callState(untracked) == "耗时未确认")
    var overlapping = ActivitySummary(state: "收到调用（处理中）", steps: [completed, nextCall], active: ["read_file": 1, "start_process": 1])
    let olderProcess = ActivityStep(id: "call-3", tool: "start_process", detail: "执行命令", startedAt: now, startedUptime: 15, duration: nil)
    overlapping.steps.append(olderProcess)
    precondition(currentCallStep(overlapping)?.id == "call-2")
    precondition(callState(overlapping) == "等待返回")
    overlapping.active = ["start_process": 1]
    precondition(currentCallStep(overlapping)?.id == "call-3")
    overlapping.steps = [ActivityStep(id: "call-4", tool: "read_file", detail: "读取文件", startedAt: now, startedUptime: 22, duration: 2), olderProcess]
    precondition(currentCallStep(overlapping)?.id == "call-3" && callState(overlapping) == "等待返回")
    let safeID = "123e4567-e89b-12d3-a456-426614174000"
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): read_file {".utf8))?.2 == "received")
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): write_file {\"file_path\":\"/tmp/TODO.md\",\"content\":\"private\"}".utf8))?.3 == "更新 /tmp/TODO.md")
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): edit_block {\"file_path\":\"/tmp/engine.swift\",\"old_string\":\"secret\"}".utf8))?.3 == "编辑 /tmp/engine.swift")
    let pathDetail = CommanderActivity.parse(Data("🔧 Received tool call \(safeID): read_file {\"content\":\"ignored\",\"file_path\":\"project/src/main.swift\"}".utf8))!.3
    precondition(pathDetail == "读取 project/src/main.swift" && CommanderActivity.menuDetail(pathDetail) == "读取 project/src/main.swift")
    precondition(CommanderActivity.menuDetail("更新 /Volumes/ExtSSD/Projects/CommanderGuard/Sources/main.swift") == "更新 CommanderGuard/Sources/main.swift")
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): write_file {\"file_path\":\"private-token/main.swift\"}".utf8))?.3 == "更新 main.swift")
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): write_file {\"file_path\":\"project/0123456789abcdef0123456789abcdef/main.swift\"}".utf8))?.3 == "更新 main.swift")
    precondition(CommanderActivity.menuDetail("更新 ./relative/main.swift") == "更新 ./relative/main.swift")
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): read_process_output {\"pid\":12345,\"length\":100}".utf8))?.3 == "读取进程 12345 输出")
    func preview(_ command: String) -> String {
        let args = try! JSONSerialization.data(withJSONObject: ["command": command])
        let line = Data("🔧 Received tool call \(safeID): start_process ".utf8) + args
        return CommanderActivity.parse(line)!.3
    }
    precondition(preview("grep -nE 'foo|bar' path") == "grep -nE 'foo|bar' path")
    precondition(preview(#"rg 'foo\|bar' file"#) == #"rg 'foo\|bar' file"#)
    precondition(preview("custom-tool --mode quick") == "custom-tool --mode quick")
    precondition(preview("npm test -- --runInBand") == "npm test -- --runInBand")
    precondition(preview("npm run test:token-refresh -- --verbose") == "npm run test:token-refresh -- --verbose")
    precondition(preview("cd '/tmp/project with spaces' && grep -nE 'foo|bar' path | sed -n '1,2p' > out") == "cd '/tmp/project with spaces' && grep -nE 'foo|bar' path | sed -n '1,2p' > out")
    let cwdMenu = CommanderActivity.menuDetail(preview("cd '/tmp/project with spaces' && grep -n foo file.txt"))
    precondition(cwdMenu == "目录 project with spaces · grep -n foo file.txt")
    precondition(CommanderActivity.menuDetail(preview("grep -n foo file.txt")) == "grep -n foo file.txt")
    precondition(CommanderActivity.menuDetail("cd /tmp/[已隐藏] && grep foo file") == "cd /tmp/[已隐藏] && grep foo file")
    precondition(preview("sed -i '' 's/foo;bar/baz/g' report.txt") == "sed -i '' 's/foo;bar/baz/g' report.txt")
    precondition(preview("python3 script.py --token 'private value' --mode quick") == "python3 script.py --token [已隐藏] --mode quick")
    precondition(preview("python3 script.py --password -abc123") == "python3 script.py --password [已隐藏]")
    precondition(preview("TOKEN='private value' custom-tool --api-key=also-private --mode quick") == "TOKEN=[已隐藏] custom-tool --api-key=[已隐藏] --mode quick")
    precondition(preview("curl -H 'Authorization: Bearer very-private' https://example.com") == "curl -H Authorization: [已隐藏] https://example.com")
    precondition(preview("curl -H 'Cookie: session=private' https://example.com") == "curl -H Cookie: [已隐藏] https://example.com")
    precondition(preview("curl -H 'X-Token: short-secret' https://example.com") == "curl -H X-Token: [已隐藏] https://example.com")
    precondition(preview("curl --header='Authorization: Bearer very-private' https://example.com") == "curl --header=[敏感请求头已隐藏] https://example.com")
    precondition(preview(#"curl --data '{"password":"private"}' https://example.com"#) == "curl --data [含敏感字段的内容已隐藏] https://example.com")
    precondition(preview(#"curl --data '{"accessToken":"short-secret"}' https://example.com"#) == "curl --data [含敏感字段的内容已隐藏] https://example.com")
    precondition(preview("curl -u ab:cd --oauth2-bearer short-secret") == "curl -u [已隐藏] --oauth2-bearer [已隐藏]")
    precondition(preview("curl -Uab:cd --user=ef:gh") == "curl -U[已隐藏] --user=[已隐藏]")
    precondition(preview("curl -H Authorization: Bearer short-secret https://example.com && echo done") == "curl -H Authorization: [已隐藏] && echo done")
    precondition(preview("custom-tool --accessToken=short-secret --mode quick") == "custom-tool --accessToken=[已隐藏] --mode quick")
    precondition(preview("ls /Volumes/ExtSSD/Projects/CommanderGuard/a-very-long-ordinary-folder-name-for-work") == "ls /Volumes/ExtSSD/Projects/CommanderGuard/a-very-long-ordinary-folder-name-for-work")
    precondition(preview("cat /tmp/123e4567-e89b-12d3-a456-426614174000/report.txt") == "cat [已隐藏]")
    precondition(preview("custom-tool eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc123 --mode quick") == "custom-tool [已隐藏] --mode quick")
    precondition(preview("printf 'ok\u{0007}secret'") == "命令含控制字符（内容已隐藏）")
    precondition(preview("python3 script.py https://user:pass@example.com/?token=private --mode quick") == "python3 script.py [网址已隐藏] --mode quick")
    precondition(preview("custom-tool --token 'unfinished private") == "命令格式未闭合（内容已隐藏）")
    precondition(preview("npm run $(private)") == "命令包含动态展开（内容已隐藏）")
    precondition(preview("node -e 'console.log(1)' && npm test") == "node -e [内联脚本已隐藏] && npm test")
    precondition(preview("python3 - <<'PY'\nPRIVATE_SCRIPT_BODY\nPY") == "python3 - <<'PY' [内联脚本已隐藏]")
    precondition(preview("grep foo path > output.txt && custom-tool --mode quick") == "grep foo path > output.txt && custom-tool --mode quick")
    precondition(preview("echo ok 2>&1") == "echo ok 2>&1")
    precondition(preview("echo ok 2>>out.log") == "echo ok 2>>out.log")
    precondition(preview("echo ok &>out.log") == "echo ok &>out.log")
    precondition(preview("echo 2 > file") == "echo 2 > file")
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): start_process {\"timeout_ms\":1000,\"command\":\"grep -n foo a.txt\"} metadata {\"command\":\"ignored\"}".utf8))?.3 == "grep -n foo a.txt")
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): start_process {\"timeout_ms\":1000,\"cmd\":\"rg foo a.txt\"}".utf8))?.3 == "rg foo a.txt")
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): start_process {\"metadata\":{\"command\":\"fake\"},\"command\":\"grep foo a.txt\"}".utf8))?.3 == "grep foo a.txt")
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): start_process {\"metadata\":{\"command\":\"fake\"},\"timeout_ms\":1000}".utf8))?.3 == "启动进程")
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): start_process {\"timeout_ms\":1000} metadata {\"command\":\"fake\"}".utf8))?.3 == "启动进程")
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): start_process {\"timeout_ms\":1000,\"command\":\"grep foo a.txt\"".utf8))?.3 == "命令未完整读取")
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): start_process {\"command\":\"grep foo a.txt\"".utf8))?.3 == "grep foo a.txt")
    let longPreview = preview("custom-tool " + String(repeating: "file ", count: 300))
    precondition(longPreview.count <= 1010 && longPreview.hasSuffix("（预览已截断）"))
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): start_process {\"command\":\"unterminated".utf8))?.3 == "命令未完整读取")
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): read_process_output {\"pid\":123xyz,\"length\":100}".utf8))?.3 == "读取进程输出")
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): write_file {\"file_path\":\"/tmp/sk-secret-token-0123456789abcdef0123456789abcdef\",\"content\":\"private\"}".utf8))?.3 == "更新文件")
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): read_file {\"content\":\"fake path /tmp/DO_NOT_SHOW.md\"}".utf8))?.3 == "读取文件")
    precondition(CommanderActivity.parse(Data("prefix 🔧 Received tool call \(safeID): read_file {".utf8)) == nil)
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): read_file_extra {".utf8))?.3 == "read_file_extra")
    precondition(ToolHistoryRecord(fingerprint: "", timestamp: now, tool: "safe_tool_42", duration: nil, returned: true, failed: false).label == "safe_tool_42")
    precondition(ToolHistoryRecord(fingerprint: "", timestamp: now, tool: "tool\nsecret", duration: nil, returned: true, failed: false).label == "未知工具")
    precondition(ToolHistoryRecord(fingerprint: "", timestamp: now, tool: "a" + String(repeating: "b", count: 64), duration: nil, returned: true, failed: false).label == "未知工具")
    precondition(ToolHistoryRecord(fingerprint: "", timestamp: now, tool: "sk-ABCDEFGHIJKLMNOPQRSTUV123456", duration: nil, returned: true, failed: false).label == "未知工具")
    selfTestSessionAttributionParser()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    selfTestActiveProbeBudget(dir: dir, now: now)
    let ledgerFile = dir.appendingPathComponent("recovery.json")
    precondition(ledgerTest.save(to: ledgerFile))
    precondition(!ChannelRecoveryLedger.load(from: ledgerFile).canAttempt(at: now.addingTimeInterval(299)))
    var disabledLedger = ledgerTest; disabledLedger.autoRecoveryEnabled = false
    precondition(disabledLedger.save(to: ledgerFile) && !ChannelRecoveryLedger.load(from: ledgerFile).autoRecoveryEnabled)
    try! Data("invalid".utf8).write(to: ledgerFile)
    precondition(!ChannelRecoveryLedger.load(from: ledgerFile).autoRecoveryEnabled)

    let genericIncidentEvent = TimelineEvent(source: "commander", event: "Commander错误: 通道关闭", sourceAt: nil, observedAt: ISO8601DateFormatter.flex.string(from: now))
    let capacityIncidentEvent = TimelineEvent(source: "commander", event: "Commander错误: 云端实时服务连接池异常", sourceAt: nil, observedAt: ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(1)))
    precondition(channelIncidentCategory(for: genericIncidentEvent) == .channelDisruption)
    precondition(channelIncidentCategory(for: capacityIncidentEvent) == .cloudRealtimeCapacity)
    precondition(localRestartSuppressed(for: .cloudRealtimeCapacity) && !localRestartSuppressed(for: .channelDisruption) && !localRestartSuppressed(for: nil))

    var incidentTest = ChannelIncidentState(now: now.addingTimeInterval(-1))
    precondition(incidentTest.observe(.channelDisruption, at: now))
    precondition(incidentTest.activeCategory == .channelDisruption && incidentTest.eventCount == 1)
    incidentTest.scheduleAfterCheck(now: now)
    precondition(incidentTest.nextRecheck == now.addingTimeInterval(10) && incidentTest.recheckAttempt == 1)
    incidentTest.scheduleAfterCheck(now: now.addingTimeInterval(10))
    precondition(incidentTest.nextRecheck == now.addingTimeInterval(30) && incidentTest.recheckAttempt == 2)
    incidentTest.scheduleAfterCheck(now: now.addingTimeInterval(30))
    precondition(incidentTest.nextRecheck == now.addingTimeInterval(70) && incidentTest.recheckAttempt == 3)
    incidentTest.scheduleAfterCheck(now: now.addingTimeInterval(70))
    precondition(incidentTest.nextRecheck == now.addingTimeInterval(150) && incidentTest.recheckAttempt == 4)
    incidentTest.scheduleAfterCheck(now: now.addingTimeInterval(150))
    precondition(incidentTest.nextRecheck == now.addingTimeInterval(270) && incidentTest.recheckAttempt == 5)
    incidentTest.scheduleAfterCheck(now: now.addingTimeInterval(270))
    precondition(incidentTest.nextRecheck == now.addingTimeInterval(390) && incidentTest.recheckAttempt == 6, "Backoff must cap at 120 seconds")
    precondition(!incidentTest.observe(.cloudRealtimeCapacity, at: now.addingTimeInterval(2)))
    precondition(incidentTest.activeCategory == .cloudRealtimeCapacity && incidentTest.eventCount == 2)
    precondition(incidentTest.consumeCapacityAlert() && !incidentTest.consumeCapacityAlert(), "Capacity alert must be issued once per active incident")
    precondition(!incidentTest.canDeclareRecovered(afterHealthyProbeAt: now.addingTimeInterval(61)))
    precondition(incidentTest.canDeclareRecovered(afterHealthyProbeAt: now.addingTimeInterval(63)))
    let incidentFile = dir.appendingPathComponent("channel-incident.json")
    precondition(incidentTest.save(to: incidentFile))
    let loadedIncident = ChannelIncidentState.load(from: incidentFile, now: now)
    precondition(loadedIncident.activeCategory == .cloudRealtimeCapacity && loadedIncident.alertIssued)
    var recoveredIncident = loadedIncident
    recoveredIncident.markRecovered(at: now.addingTimeInterval(64))
    precondition(recoveredIncident.activeCategory == nil && recoveredIncident.recentCategory == .cloudRealtimeCapacity && recoveredIncident.recoveredAt == now.addingTimeInterval(64))

    let decisionFile = dir.appendingPathComponent("channel-decisions.jsonl")
    let decisionJournal = ChannelDecisionJournal(url: decisionFile, maxBytes: 4096)
    for index in 0..<80 {
        precondition(decisionJournal.append(ChannelDecisionRecord(at: now.addingTimeInterval(Double(index)), kind: "probe", result: index % 3 == 0 ? "healthy" : "network_or_service_unknown", category: ChannelIncidentCategory.cloudRealtimeCapacity.rawValue, explicitDisconnects: index % 3, action: "incident_recheck")))
    }
    let decisionBackup = decisionFile.appendingPathExtension("bak")
    let currentDecisionSize = ((try? FileManager.default.attributesOfItem(atPath: decisionFile.path)[.size] as? NSNumber)?.intValue) ?? 0
    let backupDecisionSize = ((try? FileManager.default.attributesOfItem(atPath: decisionBackup.path)[.size] as? NSNumber)?.intValue) ?? 0
    let decisionMode = ((try? FileManager.default.attributesOfItem(atPath: decisionFile.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
    precondition(currentDecisionSize <= 4096 && backupDecisionSize > 0 && backupDecisionSize <= 4096 && decisionMode == 0o600, "Channel decision journal must stay bounded and private")
    precondition(!decisionJournal.readRecent(limit: 20).isEmpty && decisionJournal.readRecent(limit: 20).count <= 20)

    let missingHistory = ToolHistoryReader(url: dir.appendingPathComponent("missing-history.jsonl")); missingHistory.poll()
    precondition(!missingHistory.summary.sourceAvailable && missingHistory.summary.state == "结构化历史不可用")
    let historyFile = dir.appendingPathComponent("tool-history.jsonl")
    func historyLine(time: String, tool: String, duration: Any, output: Any = ["content": [["type": "text", "text": "private result"]]]) -> Data {
        let object: [String: Any] = ["timestamp": time, "toolName": tool, "arguments": ["command": "private command"], "duration": duration, "output": output]
        return try! JSONSerialization.data(withJSONObject: object) + Data([10])
    }
    let firstHistoryTime = "2026-10-05T01:02:03.000Z", secondHistoryTime = "2026-10-05T01:02:04.000Z"
    var historyData = historyLine(time: firstHistoryTime, tool: "start_process", duration: 1500)
    historyData.append(historyLine(time: secondHistoryTime, tool: "read_file", duration: 25))
    try! historyData.write(to: historyFile)
    let historyReader = ToolHistoryReader(url: historyFile); historyReader.poll()
    precondition(historyReader.summary.sourceAvailable && historyReader.summary.recent.count == 2 && !historyReader.summary.coverageGap)
    precondition(historyReader.summary.latest?.tool == "read_file" && historyReader.summary.latest?.duration == 0.025 && historyReader.summary.latest?.resultLabel == "工具调用已返回")
    precondition(historyReader.summary.recent.first(where: { $0.tool == "start_process" })?.processCaveat == "调用已返回；后台进程仍可能运行")
    let partialLine = historyLine(time: "2026-10-05T01:02:05.000Z", tool: "list_directory", duration: 7).dropLast()
    let partialHandle = try! FileHandle(forWritingTo: historyFile); try! partialHandle.seekToEnd(); try! partialHandle.write(contentsOf: partialLine); try! partialHandle.close()
    historyReader.poll(); precondition(historyReader.summary.recent.count == 2)
    let finishPartial = try! FileHandle(forWritingTo: historyFile); try! finishPartial.seekToEnd(); try! finishPartial.write(contentsOf: Data([10])); try! finishPartial.close()
    historyReader.poll(); precondition(historyReader.summary.latest?.tool == "list_directory" && historyReader.summary.recent.count == 3)
    let malformedHandle = try! FileHandle(forWritingTo: historyFile); try! malformedHandle.seekToEnd(); try! malformedHandle.write(contentsOf: Data("{broken json}\n".utf8)); try! malformedHandle.close()
    historyReader.poll(); precondition(historyReader.summary.coverageGap && historyReader.summary.malformedLines == 1 && historyReader.summary.recent.count == 3)
    let rotatedHistory = dir.appendingPathComponent("tool-history.old.jsonl")
    try! FileManager.default.moveItem(at: historyFile, to: rotatedHistory)
    let rotatedLine = historyLine(time: "2026-10-05T01:02:06.000Z", tool: "get_config", duration: 3)
    try! rotatedLine.write(to: historyFile)
    historyReader.poll(); precondition(historyReader.summary.coverageGap && historyReader.summary.gapReason == "结构化历史已轮换" && historyReader.summary.latest?.tool == "get_config")
    let duplicateLine = rotatedLine
    let duplicateHandle = try! FileHandle(forWritingTo: historyFile); try! duplicateHandle.seekToEnd(); try! duplicateHandle.write(contentsOf: duplicateLine); try! duplicateHandle.close()
    let countBeforeDuplicate = historyReader.summary.recent.count; historyReader.poll(); precondition(historyReader.summary.recent.count == countBeforeDuplicate)
    let failedHistoryFile = dir.appendingPathComponent("tool-history-failed.jsonl")
    try! historyLine(time: "2026-10-05T01:02:07.000Z", tool: "read_file", duration: 11, output: ["content": [["type": "text", "text": "private error"]], "isError": true]).write(to: failedHistoryFile)
    let failedHistoryReader = ToolHistoryReader(url: failedHistoryFile); failedHistoryReader.poll()
    precondition(failedHistoryReader.summary.latest?.failed == true && failedHistoryReader.summary.latest?.resultLabel == "工具调用返回错误")
    try! Data().write(to: historyFile)
    historyReader.poll(); precondition(historyReader.summary.coverageGap && historyReader.summary.gapReason == "结构化历史已截断")

    let log = dir.appendingPathComponent("stdout.log")
    FileManager.default.createFile(atPath: log.path, contents: Data("🚀 Starting MCP Device...\n".utf8))
    let reader = ActivityLogReader(url: log)
    reader.poll(); reader.poll(); precondition(reader.summary.state == "未观察到新调用" && !reader.summary.coverageGap && reader.summary.idleProven)
    func append(_ s: String) { let f = try! FileHandle(forWritingTo: log); try! f.seekToEnd(); try! f.write(contentsOf: Data(s.utf8)); try! f.close() }
    append("🔧 Received tool call \(safeID): read_file {\n")
    reader.poll(now: now, uptime: 10); precondition(reader.summary.active["read_file"] == 1 && reader.summary.steps.first?.startedAt == now)
    append("🔧 Received tool call \(safeID): read_file {\"file_path\":\"/tmp/first.swift\"}\n")
    reader.poll(now: now.addingTimeInterval(1), uptime: 11)
    precondition(reader.summary.active["read_file"] == 1 && reader.summary.steps.count == 1 && reader.summary.steps.first?.detail == "读取 /tmp/first.swift" && reader.summary.steps.first?.elapsed(at: 11) == 1 && !reader.summary.error)
    append("🔧 Received tool call \(safeID): read_file {duplicate}\n🔧 Received tool call 223e4567-e89b-12d3-a456-426614174000: read_file {parallel}\n")
    reader.poll(now: now.addingTimeInterval(2), uptime: 12); precondition(reader.summary.active["read_file"] == 2 && reader.summary.steps.filter { $0.tool == "read_file" }.count == 2 && reader.summary.latestReceivedID == "223e4567-e89b-12d3-a456-426614174000")
    append("🔧 Received tool call \(safeID): read_file {\"file_path\":\"/tmp/stale.swift\"}\n")
    reader.poll(now: now.addingTimeInterval(3), uptime: 13)
    precondition(reader.summary.latestReceivedID == "223e4567-e89b-12d3-a456-426614174000" && reader.summary.steps.first?.id == "223e4567-e89b-12d3-a456-426614174000")
    append("✅ Tool call read_file completed: private result must not appear\n")
    reader.poll(now: now.addingTimeInterval(4), uptime: 14); precondition(reader.summary.active["read_file"] == 1 && reader.summary.steps.filter { $0.tool == "read_file" }.allSatisfy(\.uncertain) && !reader.summary.recent.joined().contains("private"))
    append("❌ Tool call read_file failed: private error must not appear\n")
    reader.poll(); precondition(reader.summary.active.isEmpty && reader.summary.state.contains("异常"))
    append("🔧 Received tool call 623e4567-e89b-12d3-a456-426614174000: list_directory {}\n")
    reader.poll(now: now.addingTimeInterval(10), uptime: 20); let uniqueStart = reader.summary.steps.first!.startedAt
    append("✅ Tool call list_directory completed: private result\n")
    reader.poll(now: now.addingTimeInterval(13), uptime: 23)
    precondition(reader.summary.steps.first?.startedAt == uniqueStart && reader.summary.steps.first?.duration == 3 && callState(reader.summary) == "未观察到新调用")
    let capLog = dir.appendingPathComponent("cap.log")
    FileManager.default.createFile(atPath: capLog.path, contents: Data("🚀 Starting MCP Device...\n".utf8))
    let capReader = ActivityLogReader(url: capLog); capReader.poll(); capReader.poll()
    func appendCap(_ s: String) { let f = try! FileHandle(forWritingTo: capLog); try! f.seekToEnd(); try! f.write(contentsOf: Data(s.utf8)); try! f.close() }
    for index in 0...100 {
        appendCap("🔧 Received tool call 00000000-0000-4000-8000-\(String(format: "%012d", index)): read_file {}\n")
    }
    capReader.poll(now: now, uptime: 30)
    appendCap("✅ Tool call read_file completed: uncorrelated completion\n")
    capReader.poll(now: now.addingTimeInterval(1), uptime: 31)
    precondition(capReader.summary.steps.count == 100 && capReader.summary.active["read_file"] == 100 && capReader.summary.steps.first?.id == "00000000-0000-4000-8000-000000000100" && capReader.summary.steps.first?.uncertain == true && capReader.summary.steps.first?.duration == nil)
    let returnLog = dir.appendingPathComponent("return.log")
    FileManager.default.createFile(atPath: returnLog.path, contents: Data("🚀 Starting MCP Device...\n".utf8))
    let returnReader = ActivityLogReader(url: returnLog); returnReader.poll(); returnReader.poll()
    func appendReturn(_ s: String) { let f = try! FileHandle(forWritingTo: returnLog); try! f.seekToEnd(); try! f.write(contentsOf: Data(s.utf8)); try! f.close() }
    appendReturn("🔧 Received tool call a23e4567-e89b-12d3-a456-426614174000: list_directory {}\n✅ Tool call list_directory completed: result\n")
    returnReader.poll(now: now, uptime: 40)
    precondition(recentlyReturnedCall(returnReader.summary, uptime: 40)?.id == "a23e4567-e89b-12d3-a456-426614174000")
    precondition(recentlyReturnedCall(returnReader.summary, uptime: 43) == nil)
    appendReturn("🔧 Received tool call b23e4567-e89b-12d3-a456-426614174000: list_directory {}\n✅ Tool call list_directory completed: result\n✅ Tool call list_sessions completed: unmatched\n")
    returnReader.poll(now: now.addingTimeInterval(1), uptime: 41)
    precondition(returnReader.summary.active.isEmpty && returnReader.summary.state == "本机已返回（云端结果未知）" && returnReader.summary.returnedStepID == nil && recentlyReturnedCall(returnReader.summary, uptime: 41) == nil)
    let backlogLog = dir.appendingPathComponent("backlog.log")
    FileManager.default.createFile(atPath: backlogLog.path, contents: Data("🚀 Starting MCP Device...\n".utf8))
    let backlogReader = ActivityLogReader(url: backlogLog); backlogReader.poll(); backlogReader.poll()
    let backlogHandle = try! FileHandle(forWritingTo: backlogLog)
    try! backlogHandle.seekToEnd()
    try! backlogHandle.write(contentsOf: Data("🔧 Received tool call c23e4567-e89b-12d3-a456-426614174000: list_directory {}\n".utf8))
    try! backlogHandle.write(contentsOf: Data(String(repeating: "ordinary log line\n", count: 5_000).utf8))
    try! backlogHandle.write(contentsOf: Data("✅ Tool call list_directory completed: done\n".utf8)); try! backlogHandle.close()
    backlogReader.poll(); precondition(backlogReader.summary.activeCount == 1 && backlogReader.summary.catchingUp && !backlogReader.summary.coverageGap && !activitySafeForRecovery(backlogReader.summary))
    backlogReader.poll(); precondition(backlogReader.summary.activeCount == 0 && !backlogReader.summary.catchingUp && !backlogReader.summary.coverageGap && activitySafeForRecovery(backlogReader.summary))
    let utf8Log = dir.appendingPathComponent("utf8-prefix.log")
    FileManager.default.createFile(atPath: utf8Log.path, contents: Data("🚀 Starting MCP Device...\n".utf8))
    let utf8Reader = ActivityLogReader(url: utf8Log); utf8Reader.poll(); utf8Reader.poll()
    let receiptHead = "🔧 Received tool call e23e4567-e89b-12d3-a456-426614174000: read_file {\"padding\":\""
    let crossingLine = receiptHead + String(repeating: "x", count: 4095 - receiptHead.utf8.count) + "中\"}\n"
    precondition(String(data: Data(crossingLine.utf8.prefix(4096)), encoding: .utf8) == nil)
    let utf8Handle = try! FileHandle(forWritingTo: utf8Log); try! utf8Handle.seekToEnd()
    try! utf8Handle.write(contentsOf: Data(crossingLine.utf8)); utf8Reader.poll()
    precondition(utf8Reader.summary.active["read_file"] == 1 && !utf8Reader.summary.coverageGap)
    try! utf8Handle.write(contentsOf: Data("✅ Tool call read_file completed: done\n".utf8)); try! utf8Handle.close()
    utf8Reader.poll(); precondition(utf8Reader.summary.activeCount == 0 && !utf8Reader.summary.coverageGap && activitySafeForRecovery(utf8Reader.summary))

    selfTestSessionAttributionReader(dir: dir, now: now)

    let emptyLog = dir.appendingPathComponent("empty-start.log")
    FileManager.default.createFile(atPath: emptyLog.path, contents: Data())
    let emptyReader = ActivityLogReader(url: emptyLog); emptyReader.poll()
    let emptyHandle = try! FileHandle(forWritingTo: emptyLog)
    try! emptyHandle.write(contentsOf: Data("🚀 Sta".utf8)); emptyReader.poll()
    precondition(!emptyReader.summary.idleProven && !emptyReader.summary.coverageGap)
    try! emptyHandle.write(contentsOf: Data("rting MCP Device...\n".utf8)); try! emptyHandle.close()
    emptyReader.poll(); precondition(emptyReader.summary.idleProven && activitySafeForRecovery(emptyReader.summary))
    let pairedOut = dir.appendingPathComponent("paired-stdout.log")
    let pairedErr = dir.appendingPathComponent("paired-stderr.log")
    FileManager.default.createFile(atPath: pairedOut.path, contents: Data("🚀 Starting MCP Device...\n".utf8))
    FileManager.default.createFile(atPath: pairedErr.path, contents: Data())
    let pairedReader = ActivityLogReader(url: pairedOut, errorURL: pairedErr)
    pairedReader.poll(); pairedReader.poll()
    let outHandle = try! FileHandle(forWritingTo: pairedOut); try! outHandle.seekToEnd()
    try! outHandle.write(contentsOf: Data("🔧 Received tool call d23e4567-e89b-12d3-a456-426614174000: other_tool {}\n".utf8)); try! outHandle.close()
    pairedReader.poll(); precondition(pairedReader.summary.activeCount == 1 && !activitySafeForRecovery(pairedReader.summary))
    let errHandle = try! FileHandle(forWritingTo: pairedErr)
    try! errHandle.write(contentsOf: Data("❌ Tool call other_tool failed: private error\n".utf8)); try! errHandle.close()
    pairedReader.poll(); precondition(pairedReader.summary.activeCount == 0 && pairedReader.summary.state == "本机异常（云端结果未知）" && !pairedReader.summary.coverageGap && activitySafeForRecovery(pairedReader.summary))
    append("🔧 Received tool call 323e4567-e89b-12d3-a456-426614174000: read_file {" + String(repeating: "x", count: 30_000))
    reader.poll(); precondition(reader.summary.active["read_file"] == 1)
    append(String(repeating: "z", count: 300_000) + "\n")
    reader.poll(); precondition(reader.summary.active["read_file"] == 1 && reader.summary.catchingUp && !activitySafeForRecovery(reader.summary))
    for _ in 0..<6 where reader.summary.catchingUp { reader.poll() }
    precondition(reader.summary.active["read_file"] == 1 && !reader.summary.catchingUp && !reader.summary.coverageGap)
    append("🚀 Starting MCP Device...\n🔧 Received tool call 523e4567-e89b-12d3-a456-426614174000: read_file {live}\n")
    reader.poll(); precondition(reader.summary.active["read_file"] == 1)
    append("🛑 Shutting down device...\n")
    reader.poll(); precondition(reader.summary.active.isEmpty && reader.summary.state.contains("未确认"))
    // Truncation clears inferred activity and never calls an old start live.
    try! Data("✅ Tool call read_file completed: old\n".utf8).write(to: log)
    reader.poll(); precondition(reader.summary.active.isEmpty && reader.summary.state == "调用状态未确认")
    append("🔧 Received tool call 723e4567-e89b-12d3-a456-426614174000: list_directory {}\n✅ Tool call list_directory completed: result\n")
    reader.poll(); precondition(reader.summary.active.isEmpty && reader.summary.coverageGap && !activitySafeForRecovery(reader.summary))
    let oldLog = dir.appendingPathComponent("old.log")
    try! FileManager.default.moveItem(at: log, to: oldLog)
    FileManager.default.createFile(atPath: log.path, contents: Data("🔧 Received tool call 423e4567-e89b-12d3-a456-426614174000: read_file {old start}\n".utf8))
    reader.poll(); precondition(reader.summary.active.isEmpty && reader.summary.state == "调用状态未确认")
    let bootstrap = ActivityLogReader(url: log); bootstrap.poll()
    bootstrap.poll(); precondition(bootstrap.summary.active.isEmpty && !bootstrap.summary.idleProven)
    precondition(!reader.confirmedProcessRestart(oldPID: 1, newPID: 1, oldProcessExited: true))
    try! Data("🚀 Starting MCP Device...\n".utf8).write(to: log)
    precondition(reader.confirmedProcessRestart(oldPID: 1, newPID: 2, oldProcessExited: true))
    reader.poll(); reader.poll(); precondition(activitySafeForRecovery(reader.summary))
    let appRoot = dir.appendingPathComponent("app-logs", isDirectory: true)
    let day = appRoot.appendingPathComponent("2026/10/01", isDirectory: true)
    try! FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let syntheticConversationID = "123e4567-e89b-12d3-a456-426614174000"
    let syntheticTitle = "审计评估与回归测试"
    let syntheticHash = ConversationLabelCatalog.digest(for: syntheticConversationID)
    precondition(syntheticHash == "986c0dc956dc822b5d8f698661b9eb1ef880786ff9043c16744d2a420e99e9bb")
    let labelCatalogURL = dir.appendingPathComponent("conversation-labels.json")
    func writeCatalog(title: String, verifiedAt: String = "2026-10-01T13:39:03Z") {
        let object: [String: Any] = ["verified_at": verifiedAt, "labels": [syntheticHash: title]]
        try! JSONSerialization.data(withJSONObject: object).write(to: labelCatalogURL)
    }
    writeCatalog(title: syntheticTitle)
    let labelCatalog = ConversationLabelCatalog(fileURL: labelCatalogURL)
    precondition(labelCatalog.title(in: "conversationId=\(syntheticConversationID.uppercased())") == syntheticTitle)
    precondition(labelCatalog.title(in: "conversationId=not-a-uuid") == nil)
    precondition(labelCatalog.title(in: "conversationId=\(syntheticConversationID) conversationId=\(syntheticConversationID)") == nil)
    precondition(ConversationLabelCatalog(fileURL: dir.appendingPathComponent("missing-labels.json")).title(in: "conversationId=\(syntheticConversationID)") == nil)
    writeCatalog(title: "bad\nlabel")
    precondition(ConversationLabelCatalog(fileURL: labelCatalogURL).title(in: "conversationId=\(syntheticConversationID)") == nil)
    writeCatalog(title: syntheticTitle, verifiedAt: "bad timestamp")
    precondition(ConversationLabelCatalog(fileURL: labelCatalogURL).verifiedAt == nil)
    let oldEventJSON = #"{"source":"chatgpt_app","event":"chatgpt_pubsub_transport_opened","sourceAt":"2026-10-01T03:33:01.055Z","observedAt":"2026-10-01T03:33:01.055Z"}"#
    precondition((try? JSONDecoder().decode(TimelineEvent.self, from: Data(oldEventJSON.utf8)))?.conversationTitle == nil)
    let appLog = day.appendingPathComponent("main.log")
    let journal = dir.appendingPathComponent("timeline.jsonl")
    let sourceStamp = "2026-10-01T03:33:01.055Z"
    writeCatalog(title: syntheticTitle)
    let validApp = "\(sourceStamp) warning [electron-message-handler] chatgpt_conversation_refetch_completed statusAfter=idle conversationId=\(syntheticConversationID)"
    try! Data((validApp + "\n").utf8).write(to: appLog)
    let timeline = TimelineReader(appRoot: appRoot, commanderLog: dir.appendingPathComponent("stdout.log"), commanderErrorLog: nil, journal: journal, conversationLabelsURL: labelCatalogURL)
    timeline.poll(now: now)
    precondition(timeline.summary.events.count == 1 && timeline.summary.events[0].sourceAt == sourceStamp && timeline.summary.coverage.contains("Commander 调用归属未确认")) // Retained App history keeps its original event time.
    let appHandle = try! FileHandle(forWritingTo: appLog); try! appHandle.seekToEnd()
    try! appHandle.write(contentsOf: Data("\(sourceStamp) warning [electron-message-handler] chatgpt_pubsub_transport_closed private body=DO_NOT_STORE\n".utf8))
    try! appHandle.write(contentsOf: Data("transcript chatgpt_pubsub_transport_opened\n".utf8))
    try! appHandle.write(contentsOf: Data("\(sourceStamp) warning [electron-message-handler] chatgpt_conversation_refetch_completed statusAfter=private_token\n".utf8))
    try! appHandle.write(contentsOf: Data("\(sourceStamp) error [electron-message-handler] chatgpt_completion_transport_recovery_started partial".utf8)); try! appHandle.close()
    timeline.poll(now: now.addingTimeInterval(1)); precondition(timeline.summary.events.count == 2 && timeline.summary.events[1].event == "chatgpt_pubsub_transport_closed")
    let appHandle2 = try! FileHandle(forWritingTo: appLog); try! appHandle2.seekToEnd()
    try! appHandle2.write(contentsOf: Data("\n\(sourceStamp) info [electron-message-handler] chatgpt_pubsub_transport_opened\n\(sourceStamp) info [electron-message-handler] chatgpt_pubsub_reconnect_scheduled\n".utf8)); try! appHandle2.close()
    timeline.poll(now: now.addingTimeInterval(2)); timeline.poll(now: now.addingTimeInterval(3))
    precondition(timeline.summary.events.suffix(3).map(\.event) == ["chatgpt_completion_transport_recovery_started", "chatgpt_pubsub_transport_opened", "chatgpt_pubsub_reconnect_scheduled"])
    precondition(timeline.summary.events.last?.sourceAt == sourceStamp)
    let namedRoot = dir.appendingPathComponent("named-app-logs")
    let namedDay = namedRoot.appendingPathComponent("2026/10/01")
    try! FileManager.default.createDirectory(at: namedDay, withIntermediateDirectories: true)
    let labeledLog = namedDay.appendingPathComponent("labeled.log")
    FileManager.default.createFile(atPath: labeledLog.path, contents: Data())
    let labeledJournal = dir.appendingPathComponent("labeled.jsonl")
    let labeledTimeline = TimelineReader(appRoot: namedRoot, commanderLog: dir.appendingPathComponent("no-commander.log"), commanderErrorLog: nil, journal: labeledJournal, conversationLabelsURL: labelCatalogURL)
    labeledTimeline.poll(now: now)
    let namedLines = [
        "chatgpt_conversation_refetch_started conversationId=\(syntheticConversationID)",
        "chatgpt_conversation_refetch_completed statusAfter=idle conversationId=\(syntheticConversationID)",
        "chatgpt_completion_transport_recovery_started conversationId=\(syntheticConversationID)",
        "chatgpt_completion_transport_recovery_started",
        "chatgpt_conversation_refetch_completed statusAfter=idle",
        "chatgpt_pubsub_transport_closed conversationId=\(syntheticConversationID)"
    ]
    let labeledHandle = try! FileHandle(forWritingTo: labeledLog); try! labeledHandle.seekToEnd()
    try! labeledHandle.write(contentsOf: Data(namedLines.map { "\(sourceStamp) info [electron-message-handler] \($0)\n" }.joined().utf8)); try! labeledHandle.close()
    labeledTimeline.poll(now: now.addingTimeInterval(1))
    let namedEvents = labeledTimeline.summary.events
    precondition(namedEvents.count == 6 && namedEvents.prefix(3).allSatisfy { $0.conversationTitle == syntheticTitle })
    precondition(namedEvents[3].conversationTitle == nil && namedEvents[4].conversationTitle == nil && namedEvents[5].conversationTitle == nil)
    precondition(appEventLabel(namedEvents[0]) == "\(syntheticTitle) · 对话状态开始刷新")
    precondition(appEventLabel(namedEvents[4]) == "对话名称未识别 · 对话状态刷新（界面空闲）")
    precondition(appEventLabel(namedEvents[5]) == "更新连接已关闭")
    precondition(labeledTimeline.summary.conversationLabelsVerifiedAt == "2026-10-01T13:39:03Z")
    let globalTitleJournal = dir.appendingPathComponent("global-title.jsonl")
    let invalidGlobal = TimelineEvent(source: "chatgpt_app", event: "chatgpt_pubsub_transport_closed", sourceAt: sourceStamp, observedAt: sourceStamp, conversationTitle: syntheticTitle)
    let invalidCommanderTitle = TimelineEvent(source: "commander", event: "调用receipt: 读取文件", sourceAt: nil, observedAt: sourceStamp, conversationTitle: syntheticTitle)
    try! (JSONEncoder().encode(invalidGlobal) + Data([10]) + JSONEncoder().encode(invalidCommanderTitle) + Data([10])).write(to: globalTitleJournal)
    let rejectsGlobalTitle = TimelineReader(appRoot: dir.appendingPathComponent("missing-app"), commanderLog: dir.appendingPathComponent("missing-commander"), commanderErrorLog: nil, journal: globalTitleJournal, conversationLabelsURL: labelCatalogURL)
    precondition(rejectsGlobalTitle.summary.events.isEmpty)
    let longPrefix = "2026-10-01T03:33:02.055Z info [electron-message-handler] chatgpt_pubsub_transport_closed "
    let longHandle = try! FileHandle(forWritingTo: appLog); try! longHandle.seekToEnd(); try! longHandle.write(contentsOf: Data((longPrefix + String(repeating: "x", count: 9000) + " DO_NOT_KEEP\n").utf8)); try! longHandle.close()
    timeline.poll(now: now.addingTimeInterval(3.5)); precondition(timeline.summary.latestAppEvent?.event == "chatgpt_pubsub_transport_closed")
    let savedTimeline = String(data: try! Data(contentsOf: journal), encoding: .utf8)!
    precondition(!savedTimeline.contains("DO_NOT_STORE") && !savedTimeline.contains("private body") && !savedTimeline.contains("conversationId"))
    let restored = TimelineReader(appRoot: appRoot, commanderLog: dir.appendingPathComponent("stdout.log"), commanderErrorLog: nil, journal: journal, conversationLabelsURL: labelCatalogURL)
    precondition(restored.summary.events.count >= 3)
    let movedAppLog = dir.appendingPathComponent("rotated-app.log"); try! FileManager.default.moveItem(at: appLog, to: movedAppLog)
    try! Data("historical event\n".utf8).write(to: appLog); timeline.poll(now: now.addingTimeInterval(4))
    precondition(timeline.summary.coverage.contains("轮换") && timeline.summary.events.count == 6)
    try! Data("small\n".utf8).write(to: appLog); timeline.poll(now: now.addingTimeInterval(4)); precondition(timeline.summary.coverage.contains("截断"))
    let missingTimeline = TimelineReader(appRoot: dir.appendingPathComponent("missing"), commanderLog: dir.appendingPathComponent("missing.log"), commanderErrorLog: nil, journal: dir.appendingPathComponent("missing.jsonl"))
    missingTimeline.poll(); precondition(missingTimeline.summary.coverage.contains("缺失"))
    let liveCommander = dir.appendingPathComponent("live-stdout.log"); try! Data("historical\n".utf8).write(to: liveCommander)
    let commanderErrorLog = dir.appendingPathComponent("live-stderr.log"); try! Data("historic error\n".utf8).write(to: commanderErrorLog)
    let commanderTimeline = TimelineReader(appRoot: dir.appendingPathComponent("empty"), commanderLog: liveCommander, commanderErrorLog: commanderErrorLog, journal: dir.appendingPathComponent("commander.jsonl")); commanderTimeline.poll()
    let cf = try! FileHandle(forWritingTo: liveCommander); try! cf.seekToEnd(); try! cf.write(contentsOf: Data("🔧 Received tool call \(safeID): read_file {secret argument}\n✅ Tool call read_file completed: private result\n".utf8)); try! cf.close()
    let ef = try! FileHandle(forWritingTo: commanderErrorLog); try! ef.seekToEnd()
    try! ef.write(contentsOf: Data("[DEBUG] Heartbeat update failed: secret details\n".utf8))
    try! ef.write(contentsOf: Data("❌ Channel error: IncreaseConnectionPool: Please increase your connection pool size PRIVATE_CAPACITY_DETAIL\n".utf8))
    try! ef.close()
    commanderTimeline.poll(now: now); commanderTimeline.poll(now: now.addingTimeInterval(1))
    precondition(commanderTimeline.summary.events.contains(where: { $0.event == "Commander错误: 云端实时服务连接池异常" }))
    let longCommanderLine = "🔧 Received tool call 123e4567-e89b-12d3-a456-426614174001: read_file {\"padding\":\"" + String(repeating: "敏", count: 5000) + "\"}\n"
    let longCommanderFile = try! FileHandle(forWritingTo: liveCommander); try! longCommanderFile.seekToEnd(); try! longCommanderFile.write(contentsOf: Data(longCommanderLine.utf8)); try! longCommanderFile.close()
    commanderTimeline.poll(now: now.addingTimeInterval(2))
    precondition(commanderTimeline.summary.events.count == 5 && commanderTimeline.summary.events[0].source == "commander" && commanderTimeline.summary.commanderErrors == 2)
    let commanderJSON = String(data: try! Data(contentsOf: dir.appendingPathComponent("commander.jsonl")), encoding: .utf8)!
    precondition(!commanderJSON.contains("secret argument") && !commanderJSON.contains("private result") && !commanderJSON.contains(safeID) && !commanderJSON.contains("敏") && !commanderJSON.contains("IncreaseConnectionPool") && !commanderJSON.contains("PRIVATE_CAPACITY_DETAIL"))
    let boundedRoot = dir.appendingPathComponent("bounded-app", isDirectory: true)
    let boundedDay = boundedRoot.appendingPathComponent("2026/10/01", isDirectory: true)
    try! FileManager.default.createDirectory(at: boundedDay, withIntermediateDirectories: true)
    let boundedAppLog = boundedDay.appendingPathComponent("app.log"); FileManager.default.createFile(atPath: boundedAppLog.path, contents: Data())
    let boundedJournal = dir.appendingPathComponent("bounded-timeline.jsonl")
    let boundedTimeline = TimelineReader(appRoot: boundedRoot, commanderLog: dir.appendingPathComponent("no-commander.log"), commanderErrorLog: nil, journal: boundedJournal)
    boundedTimeline.poll(now: now)
    let manyEvents = (0..<18000).map { index in "\(ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(Double(index)))) warning [electron-message-handler] chatgpt_pubsub_transport_closed\n" }.joined()
    let boundedHandle = try! FileHandle(forWritingTo: boundedAppLog); try! boundedHandle.seekToEnd(); try! boundedHandle.write(contentsOf: Data(manyEvents.utf8)); try! boundedHandle.close()
    for index in 0..<30 { boundedTimeline.poll(now: now.addingTimeInterval(Double(index + 1))) }
    precondition(boundedTimeline.summary.events.count == 12 && boundedTimeline.summary.history.count == 500)
    let journalSize = (try! FileManager.default.attributesOfItem(atPath: boundedJournal.path)[.size] as! NSNumber).intValue
    let backupJournal = boundedJournal.appendingPathExtension("bak")
    let backupSize = ((try? FileManager.default.attributesOfItem(atPath: backupJournal.path)[.size] as? NSNumber)?.intValue ?? 0)
    let rowCount = ((try? Data(contentsOf: boundedJournal).split(separator: 10).count) ?? 0) + ((try? Data(contentsOf: backupJournal).split(separator: 10).count) ?? 0)
    let journalMode = (try! FileManager.default.attributesOfItem(atPath: boundedJournal.path)[.posixPermissions] as! NSNumber).intValue & 0o777
    precondition(journalSize <= 1024 * 1024 && backupSize <= 1024 * 1024 && rowCount > 5000 && journalMode == 0o600)
    let invalidJournal = dir.appendingPathComponent("invalid.jsonl")
    let invalidRow = TimelineEvent(source: "chatgpt_app", event: "chatgpt_pubsub_transport_opened · secret", sourceAt: sourceStamp, observedAt: ISO8601DateFormatter.flex.string(from: now))
    try! (JSONEncoder().encode(invalidRow) + Data([10])).write(to: invalidJournal)
    let rejectsUnlisted = TimelineReader(appRoot: dir.appendingPathComponent("missing"), commanderLog: dir.appendingPathComponent("none"), commanderErrorLog: nil, journal: invalidJournal)
    precondition(rejectsUnlisted.summary.events.isEmpty)
    // A public connection opening or idle UI never proves the interrupted answer recovered.
    let issueTime = "2026-10-04T11:40:53.677Z"
    let issue = TimelineEvent(source: "chatgpt_app", event: "chatgpt_completion_transport_recovery_started", sourceAt: issueTime, observedAt: issueTime, failureKind: "resume_unavailable")
    let laterOpen = TimelineEvent(source: "chatgpt_app", event: "chatgpt_pubsub_transport_opened", sourceAt: "2026-10-04T11:41:00.000Z", observedAt: "2026-10-04T11:41:00.000Z")
    let laterIdle = TimelineEvent(source: "chatgpt_app", event: "chatgpt_conversation_refetch_completed · idle", sourceAt: "2026-10-04T11:42:00.000Z", observedAt: "2026-10-04T11:42:00.000Z")
    let outOfOrderJournal = dir.appendingPathComponent("chat-out-of-order.jsonl")
    let olderClosed = TimelineEvent(source: "chatgpt_app", event: "chatgpt_pubsub_transport_closed", sourceAt: "2026-10-04T11:39:00.000Z", observedAt: "2026-10-04T11:43:00.000Z")
    let outOfOrderData = [laterOpen, olderClosed].map { try! JSONEncoder().encode($0) + Data([10]) }.reduce(into: Data()) { $0.append($1) }
    try! outOfOrderData.write(to: outOfOrderJournal)
    let outOfOrderReader = TimelineReader(appRoot: dir.appendingPathComponent("missing-order"), commanderLog: dir.appendingPathComponent("none-order"), commanderErrorLog: nil, journal: outOfOrderJournal)
    precondition(outOfOrderReader.summary.latestAppEvent?.sourceAt == laterOpen.sourceAt, "Latest App event must follow source time, not journal append order")
    let chatResult = chatMonitorSummary(TimelineSummary(coverage: "已覆盖当前日志", history: [issue, laterOpen, laterIdle]))
    precondition(chatResult.answer == "当前连接正常" && chatResult.connection.contains("更新连接已建立"))
    precondition(chatResult.history?.contains("原中断回答是否完整恢复无法从日志确认") == true)
    let issueOnly = chatMonitorSummary(TimelineSummary(coverage: "已覆盖当前日志", history: [issue]))
    precondition(issueOnly.answer == "回答异常（恢复未确认）" && issueOnly.history == "恢复情况未确认")
    let laterStreaming = TimelineEvent(source: "chatgpt_app", event: "chatgpt_conversation_refetch_completed · streaming", sourceAt: "2026-10-04T11:42:30.000Z", observedAt: "2026-10-04T11:42:30.000Z")
    let streamingResult = chatMonitorSummary(TimelineSummary(coverage: "已覆盖当前日志", history: [issue, laterStreaming]))
    precondition(streamingResult.answer == "当前连接正常" && streamingResult.history?.contains("原中断回答是否完整恢复无法从日志确认") == true)
    precondition(appEventLabel(TimelineEvent(source: "chatgpt_app", event: "chatgpt_conversation_refetch_completed · error", sourceAt: issueTime, observedAt: issueTime)).contains("对话状态刷新失败"))
    let repeated = TimelineEvent(source: "chatgpt_app", event: "chatgpt_pubsub_transport_opened", sourceAt: "2026-10-04T11:41:00.100Z", observedAt: "2026-10-04T11:41:00.100Z")
    let repeated2 = TimelineEvent(source: "chatgpt_app", event: "chatgpt_pubsub_transport_opened", sourceAt: "2026-10-04T11:41:00.800Z", observedAt: "2026-10-04T11:41:00.800Z")
    let separate = TimelineEvent(source: "chatgpt_app", event: "chatgpt_pubsub_transport_opened", sourceAt: "2026-10-04T11:41:03.000Z", observedAt: "2026-10-04T11:41:03.000Z")
    let grouped = groupedTimelineEvents([repeated, repeated2, separate])
    precondition(grouped.count == 2 && grouped[0].1 == 2 && grouped[1].1 == 1)
    precondition(groupedTimelineEvents([issue, TimelineEvent(source: issue.source, event: issue.event, sourceAt: issue.sourceAt, observedAt: issue.observedAt)]).count == 2, "Different failure classifications must remain separate")
    precondition(chatResult.menuLine.count < 100 && chatResult.deliveryLimit.contains("没有可读"))
    precondition(chatMonitorSummary(TimelineSummary(coverage: "App 日志缺失")).answer.contains("未知"))
    precondition(chatMonitorSummary(TimelineSummary(coverage: "已覆盖当前日志")).answer == "当前未见异常")
    let retainedIssue = chatMonitorSummary(TimelineSummary(coverage: "已覆盖当前日志", history: [laterOpen, laterIdle], latestAppIssue: issue))
    precondition(retainedIssue.answer == "当前连接正常" && retainedIssue.history?.contains("原中断回答是否完整恢复无法从日志确认") == true)
    let chatRoot = dir.appendingPathComponent("chat-monitor/2026/10/04"); try! FileManager.default.createDirectory(at: chatRoot, withIntermediateDirectories: true)
    let chatLog = chatRoot.appendingPathComponent("app.log")
    let chatJournal = dir.appendingPathComponent("chat-monitor.jsonl")
    let chatRecord = "\(issueTime) warning [electron-message-handler] chatgpt_completion_transport_recovery_started conversationId=00000000-0000-4000-8000-000000000001 error={\"type\":\"fetch-stream-error\",\"responseStatus\":404,\"error\":\"{\\\"detail\\\":\\\"Resume stream unavailable\\\"}\"}\n"
    precondition(appRecoveryFailure("note=Resume stream unavailable error={\"type\":\"other\"}") == nil)
    precondition(appRecoveryFailure("error={\"type\":\"fetch-stream-error\",\"responseStatus\":500,\"error\":\"Resume stream unavailable\"}") == nil)
    try! Data(chatRecord.utf8).write(to: chatLog)
    let chatReader = TimelineReader(appRoot: dir.appendingPathComponent("chat-monitor"), commanderLog: dir.appendingPathComponent("none"), commanderErrorLog: nil, journal: chatJournal)
    chatReader.poll(now: now)
    precondition(chatReader.summary.latestAppIssue?.failureKind == "resume_unavailable")
    let restoredChatReader = TimelineReader(appRoot: dir.appendingPathComponent("missing"), commanderLog: dir.appendingPathComponent("none"), commanderErrorLog: nil, journal: chatJournal)
    precondition(restoredChatReader.summary.latestAppIssue?.failureKind == "resume_unavailable")
    let serializedChat = String(decoding: try! Data(contentsOf: chatJournal), as: UTF8.self)
    precondition(!serializedChat.contains("conversationId") && !serializedChat.contains("errorType") && !serializedChat.contains("Resume stream unavailable"))
    let extraEvents = ["chatgpt_completion_transport_recovery_completed", "chatgpt_completion_transport_recovery_poll_failed", "chatgpt_pubsub_reconnect_exhausted"]
    let extraLines = extraEvents.enumerated().map { offset, event in
        "2026-10-04T11:43:0\(offset).000Z warning [electron-message-handler] \(event) conversationId=00000000-0000-4000-8000-000000000001 error=PRIVATE_TEST_PAYLOAD"
    }.joined(separator: "\n") + "\n"
    let extraHandle = try! FileHandle(forWritingTo: chatLog); try! extraHandle.seekToEnd(); try! extraHandle.write(contentsOf: Data(extraLines.utf8)); try! extraHandle.close()
    chatReader.poll(now: now)
    precondition(chatReader.summary.history.suffix(3).map(\.event) == extraEvents)
    precondition(chatMonitorSummary(chatReader.summary).answer == "连接异常" && chatMonitorSummary(chatReader.summary).history == "恢复情况未确认")
    precondition(chatMonitorSummary(chatReader.summary).connection.contains("重连已耗尽"))
    let recoveredEvent = chatReader.summary.history.first { $0.event == extraEvents[0] }!
    precondition(appEventLabel(recoveredEvent).contains("恢复完成"))
    let recoveredSummary = chatMonitorSummary(TimelineSummary(coverage: "已覆盖当前日志", history: [issue, recoveredEvent]))
    precondition(recoveredSummary.answer == "回答恢复已记录" && recoveredSummary.history == "后续已记录回答恢复完成")
    let restoredExtra = TimelineReader(appRoot: dir.appendingPathComponent("missing"), commanderLog: dir.appendingPathComponent("none"), commanderErrorLog: nil, journal: chatJournal)
    precondition(restoredExtra.summary.history.suffix(3).map(\.event) == extraEvents)
    precondition(!String(decoding: try! Data(contentsOf: chatJournal), as: UTF8.self).contains("PRIVATE_TEST_PAYLOAD"))
    let freshRoot = dir.appendingPathComponent("fresh-log/2026/10/04")
    try! FileManager.default.createDirectory(at: freshRoot, withIntermediateDirectories: true)
    let freshCommander = dir.appendingPathComponent("fresh-commander.log"); try! Data().write(to: freshCommander)
    let freshReader = TimelineReader(appRoot: dir.appendingPathComponent("fresh-log"), commanderLog: freshCommander, commanderErrorLog: nil, journal: dir.appendingPathComponent("fresh-journal.jsonl"))
    freshReader.poll(now: now)
    try! Data("\(issueTime) info [electron-message-handler] chatgpt_pubsub_transport_opened\n".utf8).write(to: freshRoot.appendingPathComponent("new.log"))
    freshReader.poll(now: now)
    precondition(freshReader.summary.coverage.contains("已覆盖当前日志") && freshReader.summary.history.count == 1, "A new App log read from byte zero has no coverage gap")
    try! Data(repeating: 32, count: 2 * 1024 * 1024 + 1).write(to: freshRoot.appendingPathComponent("too-large.log"))
    freshReader.poll(now: now)
    precondition(freshReader.summary.coverage.contains("覆盖有缺口"), "Skipping old bytes in a new path must still report a gap")
    precondition(NSImage(systemSymbolName: "shield", accessibilityDescription: nil) != nil && NSImage(systemSymbolName: "link", accessibilityDescription: nil) != nil)
    let safeIdle = ActivitySummary(state: "未观察到新调用", idleProven: true)
    let recoveredAnswerDiagnosis = IncidentDiagnosis.make(
        timeline: TimelineSummary(coverage: "已覆盖当前日志", history: [issue, laterOpen, laterIdle], latestAppIssue: issue),
        activity: safeIdle,
        now: now
    )
    precondition(!recoveredAnswerDiagnosis.title.contains("回答异常") && !recoveredAnswerDiagnosis.title.contains("较早"), "Recovered current ChatGPT state must not be replaced by retained history")
    let eventTime = ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-50))
    let appClose = TimelineEvent(source: "chatgpt_app", event: "chatgpt_pubsub_transport_closed", sourceAt: eventTime, observedAt: eventTime)
    let commanderChannel = TimelineEvent(source: "commander", event: "Commander错误: 通道错误", sourceAt: nil, observedAt: ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-45)))
    let joint = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志", history: [appClose, commanderChannel]), activity: safeIdle, service: "运行中", channelState: "通道畅通", now: now)
    precondition(joint.title.contains("同时异常") && joint.evidence.contains("不证明"), "Near-time cross-service evidence must remain tentative")
    precondition(joint.startedAt == ISO8601DateFormatter.parse(eventTime) && joint.lastSeenAt == ISO8601DateFormatter.parse(commanderChannel.observedAt), "Cross-service timing must use the actual observed events")
    let appOnly = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志", history: [appClose]), activity: safeIdle, now: now)
    precondition(appOnly.title.contains("连接近期中断") && appOnly.evidence.contains("不等同于 Commander ping"))
    let opened = TimelineEvent(source: "chatgpt_app", event: "chatgpt_pubsub_transport_opened", sourceAt: ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-10)), observedAt: eventTime)
    let duplicateClose = TimelineEvent(source: "chatgpt_app", event: appClose.event, sourceAt: eventTime, observedAt: ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-49)))
    let interrupted = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志", history: [appClose, duplicateClose, opened]), activity: safeIdle, now: now)
    precondition(interrupted.title.contains("之后观察到重新连接") && !interrupted.title.contains("次"), "Co-temporal close records should collapse into one incident")
    let repeatClose = TimelineEvent(source: "chatgpt_app", event: appClose.event, sourceAt: ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-20)), observedAt: ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-19)))
    let repeatedDiagnosis = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志", history: [appClose, duplicateClose, repeatClose]), activity: safeIdle, now: now)
    precondition(repeatedDiagnosis.title.contains("近15分钟 2 个关闭时段"), "Distinct close groups should report the repeat count")
    let oldIssue = TimelineEvent(source: "chatgpt_app", event: "chatgpt_completion_transport_recovery_started", sourceAt: ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-1800)), observedAt: eventTime, failureKind: "resume_unavailable")
    let oldTimeline = TimelineSummary(coverage: "已覆盖当前日志", history: [oldIssue], latestAppIssue: oldIssue)
    let oldDiagnosis = IncidentDiagnosis.make(timeline: oldTimeline, activity: safeIdle, now: now)
    precondition(oldDiagnosis.title.contains("较早") && chatMonitorSummary(oldTimeline).answer == "回答异常（恢复未确认）", "Old unresolved answer incidents must persist separately")
    let oldPlusClose = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志", history: [oldIssue, appClose], latestAppIssue: oldIssue), activity: safeIdle, now: now)
    precondition(oldPlusClose.title.contains("更新连接近期中断"), "An old answer issue must not hide a new connection interruption")
    let stopped = IncidentDiagnosis.make(timeline: oldTimeline, activity: safeIdle, service: "未运行", channelState: "未知", now: now)
    precondition(stopped.title.contains("服务当前未运行"), "Current service state must outrank old answer history")
    let expired = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志", history: [TimelineEvent(source: "chatgpt_app", event: appClose.event, sourceAt: ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-901)), observedAt: eventTime)]), activity: safeIdle, now: now)
    precondition(expired.title.contains("没有可操作") && expired.startedAt == nil, "Expired incidents must not remain current")
    let earlierCommander = TimelineEvent(source: "commander", event: "Commander错误: 通道关闭", sourceAt: nil, observedAt: ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-600)))
    let exactJoint = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志", history: [earlierCommander, appClose, commanderChannel]), activity: safeIdle, now: now)
    precondition(exactJoint.startedAt == ISO8601DateFormatter.parse(eventTime) && exactJoint.lastSeenAt == ISO8601DateFormatter.parse(commanderChannel.observedAt), "Unrelated older Commander events must not change incident times")
    let unknownActivity = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志"), activity: ActivitySummary(state: "状态未确认"), now: now)
    precondition(unknownActivity.title.contains("未确认") && unknownActivity.nextAction.contains("当前不建议重启或重试"))
    let busyDiagnosis = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志"), activity: ActivitySummary(state: "收到调用（处理中）", active: ["read_file": 1]), now: now)
    precondition(busyDiagnosis.title.contains("进行中") && busyDiagnosis.nextAction.contains("等待当前调用返回"))
    let missingCoverage = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "读取失败"), activity: ActivitySummary(state: "未观察到新调用", observed: now.addingTimeInterval(-600)), now: now)
    precondition(missingCoverage.title.contains("覆盖") && missingCoverage.startedAt == nil, "An unrelated call timestamp cannot become a diagnostic gap start")
    precondition(IncidentDiagnosis.make(timeline: oldTimeline, activity: safeIdle, now: now).title.contains("较早"), "A successful probe must not clear an answer issue")
    print("CommanderGuard self-test passed")
}

final class PanelBackgroundView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    }
}

final class PanelCardView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.blended(withFraction: 0.06, of: .labelColor)?.cgColor
        }
    }
}

final class TopAlignedPanelDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private var channelTimer: Timer?
    private var assertion: IOPMAssertionID = 0
    private var paused = !(UserDefaults.standard.object(forKey: "keepAwakeEnabled") as? Bool ?? true)
    private var snapshot = Snapshot()
    private var summaryLines: [NSMenuItem] = []
    private var statusMenu: NSMenu?
    private var guardItem: NSMenuItem!
    private var recoveryItem: NSMenuItem!
    private let recoveryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CommanderGuard/channel-recovery.json")
    private var recoveryLedger = ChannelRecoveryLedger.load(from: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CommanderGuard/channel-recovery.json"))
    private let channelIncidentURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CommanderGuard/channel-incident.json")
    private let channelDecisionURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CommanderGuard/channel-decisions.jsonl")
    private lazy var channelIncident = previewMode ? ChannelIncidentState(now: Date()) : ChannelIncidentState.load(from: channelIncidentURL, now: Date())
    private lazy var channelDecisionJournal = ChannelDecisionJournal(url: channelDecisionURL)
    private var watchdog = ChannelWatchdogState(startedAt: Date())
    private var channelBusy = false
    private var lastPingAt: Date?
    private var lastPingResult = "尚无实际检查结果"
    private var deferredReason = "等待首次检查"
    private var lastRecoveryOutcome: String?
    private var manualNotice: String?
    private var manualPingBusy = false
    private var toolProbeDeferredReason = "等待首次工具检查"
    private var lastActivityPoll = Date.distantPast
    private var recoveryLaunched = false
    private let previewMode: Bool
    private var panelWindow: NSWindow?
    private var panelPage = 0
    private var panelScroll: NSScrollView?
    private var panelNav: NSSegmentedControl?
    private var panelSectionCount = 0
    private var panelSectionWidths: [NSLayoutConstraint] = []
    private var panelHeading: NSStackView?
    private var panelHeroes: NSStackView?
    private var panelControlCard: NSView?
    private var panelManualCheckStatus: NSTextField?
    private var panelHeroMinimum: NSLayoutConstraint?
    private var panelConnection: NSTextField?
    private var panelConnectionTime: NSTextField?
    private var panelConnectionDetail: NSTextField?
    private var panelToolExecution: NSTextField?
    private var panelToolExecutionTime: NSTextField?
    private var panelToolExecutionDetail: NSTextField?
    private var panelChat: NSTextField?
    private var panelChatTime: NSTextField?
    private var panelChatDetail: NSTextField?
    private var panelProbeToggle: NSButton?
    private var panelProbeBudget: NSTextField?
    private var panelProbeIntervalPicker: NSPopUpButton?
    private var probeIntervalMenuOpen = false
    private var panelManualCheck: NSButton?
    private var panelRecoveryToggle: NSButton?
    private var panelRecoveryStatus: NSTextField?
    private var panelWakeStatus: NSTextField?
    private var panelWakeToggle: NSButton?
    private var recordSearch: NSSearchField?
    private var recordFilter: NSPopUpButton?
    private var recordTable: NSTableView?
    private var recordTableScroll: NSScrollView?
    private var recordDocument: NSView?
    private var recordDetail: NSTextField?
    private var recordSteps: [ActivityStep] = []
    private var selectedRecordID: String?
    private var historicalRecordsExpanded = false
    private var historicalRecordsToggle: NSButton?
    private let activityReader = ActivityLogReader(errorURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RemoteDesktopCommander/stderr.log"))
    private let toolHistoryReader = ToolHistoryReader()
    private var lastToolHistoryPoll = Date.distantPast
    private var verifiedRestart: (old: Int32, new: Int32)?
    private var pendingRecoveryVerification: (old: Int32, new: Int32)?
    private let timelineReader = TimelineReader()
    private var activityBusy = false
    private var activityTimer: Timer?
    private var quotaTimer: Timer?
    private var quota = UsageQuota()
    private let quotaBrowser = HeadlessQuotaBrowser()
    private var quotaFailureReason: String?
    private var quotaButton: NSButton?
    private var quotaPauseButton: NSButton?
    private var quotaValue: NSTextField?
    private var quotaStatus: NSTextField?
    private var quotaSynced: NSTextField?
    private var quotaProgress: NSProgressIndicator?
    private var quotaRefreshButton: NSButton?
    private var quotaIntervalPicker: NSPopUpButton?
    private var quotaIntervalMenuOpen = false
    private var quotaRefreshAfterLogin = false
    private var quotaRequestInFlight = false
    private var quotaCancelRequested = false
    private var quotaTerminateWhenIdle = false
    private var quotaEnabled: Bool { UserDefaults.standard.bool(forKey: "quotaConnectionEnabled") }
    private var quotaRefreshSeconds: Int { sanitizedQuotaRefreshSeconds(UserDefaults.standard.object(forKey: "quotaRefreshSeconds") as? Int) }

    init(previewMode: Bool = false) { self.previewMode = previewMode; super.init() }

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSImage(systemSymbolName: "shield", accessibilityDescription: nil)?.draw(in: NSRect(x: 1, y: 0, width: 16, height: 18))
            NSImage(systemSymbolName: "link", accessibilityDescription: nil)?.draw(in: NSRect(x: 5, y: 6, width: 8, height: 7))
            return true
        }
        image.isTemplate = true
        item.button?.image = image; item.button?.imagePosition = .imageLeading
        rebuild()
        if previewMode {
            loadPreviewSnapshot(); openPanel()
            if CommandLine.arguments.contains("--verify-ui") { verifyPanelLayout(); exit(0) }
            return
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(openPanel), name: NSNotification.Name("com.wuwendi.commander-guard.open-panel"), object: nil)
        poll()
        quotaBrowser.onLoginClosed = { [weak self] in
            guard let self, self.quotaEnabled, !self.quotaTerminateWhenIdle else { return }
            if self.quotaRequestInFlight { self.quotaRefreshAfterLogin = true; return }
            self.quota.state = .loginRequired
            self.refreshQuota()
        }
        UserDefaults.standard.set(quotaRefreshSeconds, forKey: "quotaRefreshSeconds")
        if quotaEnabled && quotaRefreshSeconds > 0 { refreshQuota() }
        resetQuotaTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in self.poll() }
        channelTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in self.pollChannel(); self.pollToolExecution() }
        activityTimer = Timer(timeInterval: 1, repeats: true) { _ in self.pollActivity() }
        RunLoop.main.add(activityTimer!, forMode: .common)
        pollActivity()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard quotaRequestInFlight else { return .terminateNow }
        quotaTerminateWhenIdle = true; quotaBrowser.cancel()
        return .terminateLater
    }
    func applicationWillTerminate(_ n: Notification) { timer?.invalidate(); channelTimer?.invalidate(); activityTimer?.invalidate(); quotaTimer?.invalidate(); quotaBrowser.cancel(); releaseAssertion() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { openPanel(); return true }
    private func rebuild() {
        let m = NSMenu()
        summaryLines = (0..<5).map { _ in NSMenuItem(title: "", action: nil, keyEquivalent: "") }
        recoveryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        guardItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let open = NSMenuItem(title: "打开 CommanderGuard", action: #selector(openPanel), keyEquivalent: ""); open.target = self; m.addItem(open)
        m.addItem(.separator())
        let quit = NSMenuItem(title: "退出 CommanderGuard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); quit.target = NSApplication.shared; m.addItem(quit)
        statusMenu = m
        item.button?.target = self
        item.button?.action = #selector(statusBarClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    private func poll() {
        DispatchQueue.global(qos: .utility).async {
            let running = self.serviceRunning()
            DispatchQueue.main.async { self.snapshot.service = running ? "运行中" : "未运行"; self.updateGuard(); self.render() }
        }
        snapshot.checked = Date()
        Monitor.shared.check { state, seen, error in
            DispatchQueue.main.async {
                self.snapshot.checked = Date()
                if let error { self.snapshot.errorCount += 1; self.snapshot.message = error; if self.snapshot.errorCount >= 2 { self.snapshot.cloud = state } }
                else { self.snapshot.errorCount = 0; self.snapshot.message = ""; self.snapshot.cloud = state; self.snapshot.lastSeen = seen }
                self.updateGuard(); self.render()
            }
        }
        render()
    }
    private func auditChannel(kind: String, result: String, action: String? = nil, at: Date = Date()) {
        guard !previewMode else { return }
        let record = ChannelDecisionRecord(at: at, kind: kind, result: result,
                                           category: channelIncident.activeCategory?.rawValue ?? channelIncident.recentCategory?.rawValue,
                                           explicitDisconnects: watchdog.failures, action: action)
        _ = channelDecisionJournal.append(record)
    }

    private func saveChannelIncident() {
        guard !previewMode else { return }
        _ = channelIncident.save(to: channelIncidentURL)
    }

    private func probeAuditResult(_ result: ChannelProbeResult) -> String {
        switch result {
        case .healthy: return "healthy"
        case .noLiveConnection: return "device_disconnected"
        case .unknown: return "network_or_service_unknown"
        }
    }

    private func channelIncidentHandling(now: Date = Date()) -> String {
        guard let category = channelIncident.activeCategory else {
            if let recoveredAt = channelIncident.recoveredAt, let recent = channelIncident.recentCategory {
                return "近期故障已恢复 · \(recent.title) · \(prominentStamp(recoveredAt))"
            }
            return "无活动故障"
        }
        if let reason = activeProbeStatus.blockReason { return "复查已暂停 · \(reason)" }
        if channelBusy || manualPingBusy { return "正在复查 · \(category.title)" }
        if let next = channelIncident.nextRecheck, next > now {
            let seconds = max(1, Int(next.timeIntervalSince(now).rounded(.up)))
            return category == .cloudRealtimeCapacity ? "等待云端恢复 · \(seconds) 秒后只读复查" : "等待复查 · \(seconds) 秒后只读检查"
        }
        return category == .cloudRealtimeCapacity ? "等待云端恢复 · 即将只读复查" : "持续异常 · 即将只读复查"
    }

    private func recentChannelIncidentSummary() -> String {
        guard let category = channelIncident.recentCategory else { return "暂无" }
        if channelIncident.activeCategory != nil {
            return "\(category.title) · 已观察 \(channelIncident.eventCount) 次"
        }
        return "\(category.title) · 已恢复"
    }

    private func markChannelIncidentRecovered(at date: Date, result: String) {
        guard channelIncident.activeCategory != nil else { return }
        channelIncident.markRecovered(at: date)
        watchdog.failures = 0
        auditChannel(kind: "incident", result: result, action: "fault_history_retained", at: date)
        saveChannelIncident()
    }

    private func processChannelTimeline(_ timeline: TimelineSummary, now: Date) {
        let cursor = channelIncident.lastProcessedTimelineAt
        let rows: [(TimelineEvent, Date)] = timeline.history.compactMap { event in
            guard let date = ISO8601DateFormatter.parse(event.observedAt), date > cursor else { return nil }
            return (event, date)
        }.sorted { $0.1 < $1.1 }
        guard !rows.isEmpty else { return }
        var latest = cursor
        var changed = false
        for (event, date) in rows {
            latest = max(latest, date)
            if let category = channelIncidentCategory(for: event) {
                _ = channelIncident.observe(category, at: date)
                let signal = category == .cloudRealtimeCapacity ? "cloud_realtime_capacity" : "channel_disruption"
                auditChannel(kind: "signal", result: signal, action: activeProbeStatus.blockReason == nil ? "read_only_recheck_scheduled" : "observed_without_active_probe", at: date)
                if channelIncident.consumeCapacityAlert() {
                    auditChannel(kind: "alert", result: "cloud_capacity_alerted_once", action: "wait_for_cloud_recovery", at: date)
                }
                changed = true
            } else if isCommanderRemoteCallReceipt(event),
                      channelIncident.activeCategory != nil,
                      let lastSeen = channelIncident.lastSeen,
                      date.timeIntervalSince(lastSeen) >= 60 {
                markChannelIncidentRecovered(at: date, result: "recovered_by_remote_call")
                changed = true
            }
        }
        channelIncident.lastProcessedTimelineAt = latest
        if changed || latest > cursor { saveChannelIncident() }
        if changed { render() }
    }

    private var activeProbeStatus: ActiveProbeBudget.Status {
        previewMode ? ActiveProbeBudget.Status(enabled: false, intervalSeconds: ActiveProbeBudget.defaultIntervalSeconds, lastSubmittedAt: nil, now: Date(), error: nil) : ActiveProbeBudget.shared.status()
    }
    private func pollChannel() {
        let now = Date()
        if let reason = activeProbeStatus.blockReason {
            deferredReason = reason
            if snapshot.channelChecked == nil {
                snapshot.channelState = "未主动验证"
                snapshot.channelDetail = "\(reason)；继续观察本机日志与设备登记"
            }
            return
        }
        guard !channelBusy, !manualPingBusy, !watchdog.recovering else { return }
        let due = channelIncident.activeCategory != nil ? channelIncident.recheckDue(now: now) : watchdog.isDue(now: now, intervalSeconds: activeProbeStatus.intervalSeconds)
        guard due else { return }
        watchdog.lastProbe = now
        guard snapshot.service == "运行中" else { recordDeferred("Commander 服务未运行"); return }
        channelBusy = true
        deferredReason = channelIncident.activeCategory == nil ? "正在检查" : "正在复查持续通道异常"
        render()
        let probe = MCPChannelProbe()
        probe.run { result in
            DispatchQueue.main.async {
                self.channelBusy = false
                let checkedAt = Date()
                self.recordProbe(result, now: checkedAt, submitted: probe.submitted)
                if case .noLiveConnection = result, self.watchdog.failures >= 3 {
                    if localRestartSuppressed(for: self.channelIncident.activeCategory) {
                        self.auditChannel(kind: "recovery_decision", result: "restart_suppressed_cloud_capacity",
                                          action: "wait_for_cloud_recovery", at: checkedAt)
                        self.snapshot.channelDetail = "云端容量异常不通过重启本机 Commander 修复；继续退避复查"
                        self.render()
                    } else {
                        self.considerRecovery()
                    }
                }
            }
        }
    }

    private func recordProbe(_ result: ChannelProbeResult, now: Date, manual: Bool = false, submitted: Bool = true) {
        guard submitted else {
            recordDeferred(probeDescription(result)); return
        }
        if case .healthy = result, let pending = pendingRecoveryVerification {
            verifyPendingRecovery(now: now, currentPID: servicePID(), oldProcessExited: kill(pending.old, 0) == -1 && errno == ESRCH)
        }
        lastPingAt = now; lastPingResult = probeDescription(result); deferredReason = "未延后"
        manualNotice = nil
        if manual { watchdog.observedManual(result, now: now) }
        else { watchdog.observed(result, now: now) }
        snapshot.channelState = watchdog.status; snapshot.channelDetail = watchdog.detail
        snapshot.channelFailures = watchdog.failures; snapshot.channelChecked = now

        if case .noLiveConnection = result {
            _ = channelIncident.observe(.channelDisruption, at: now)
        }
        channelIncident.lastProbeAt = now
        channelIncident.lastProbeResult = probeAuditResult(result)
        auditChannel(kind: manual ? "manual_probe" : "probe", result: probeAuditResult(result),
                     action: channelIncident.activeCategory == nil ? "routine_check" : "incident_recheck", at: now)
        if channelIncident.activeCategory != nil {
            if case .healthy = result, channelIncident.canDeclareRecovered(afterHealthyProbeAt: now) {
                markChannelIncidentRecovered(at: now, result: "recovered_after_quiet_healthy_probe")
            } else {
                channelIncident.scheduleAfterCheck(now: now)
                saveChannelIncident()
            }
        } else {
            saveChannelIncident()
        }
        render()
    }

    private func verifyPendingRecovery(now: Date, currentPID: Int32?, oldProcessExited: Bool) {
        guard let pending = pendingRecoveryVerification else { return }
        if recoveryConfirmed(oldPID: pending.old, newPID: pending.new, currentPID: currentPID, oldProcessExited: oldProcessExited, probe: .healthy) {
            lastRecoveryOutcome = "服务 PID 已变化，后续实际 ping 成功"
            verifiedRestart = pending
            pendingRecoveryVerification = nil
            auditChannel(kind: "recovery", result: "restart_confirmed", action: "channel_recovered", at: now)
            if !previewMode { pollActivity() }
        } else if let currentPID, currentPID != pending.new {
            pendingRecoveryVerification = nil
        }
    }
    private func recordDeferred(_ reason: String) {
        let now = Date()
        deferredReason = reason; manualNotice = nil
        watchdog.observed(.unknown(reason), now: now)
        snapshot.channelState = watchdog.status
        snapshot.channelFailures = watchdog.failures
        snapshot.channelDetail = "检查暂缓：\(reason)"
        if channelIncident.activeCategory != nil {
            channelIncident.deferRecheck(now: now)
            saveChannelIncident()
        }
        auditChannel(kind: "probe_deferred", result: reason == "Commander 服务未运行" ? "service_not_running" : "safety_deferred",
                     action: "retry_later", at: now)
        render()
    }
    private func refreshToolExecutionFromActivity(_ activity: ActivitySummary, now: Date = Date()) {
        guard let evidence = recentSuccessfulToolExecution(activity, now: now) else { return }
        guard snapshot.toolExecutionChecked.map({ evidence > $0 }) ?? true else { return }
        snapshot.toolExecutionState = "已验证"
        snapshot.toolExecutionDetail = "复用最近真实工具调用成功记录"
        snapshot.toolExecutionChecked = evidence
        toolProbeDeferredReason = "无需额外探测"
    }
    private func pollToolExecution() {
        guard !previewMode else { return }
        refreshToolExecutionFromActivity(snapshot.activity)
        if !toolExecutionFresh(snapshot, now: Date()) { toolProbeDeferredReason = "等待真实工具调用成功记录；不自动发送额外工具请求" }
    }
    private func toolExecutionSummary(now: Date) -> String {
        if snapshot.toolExecutionState == "已验证" && !toolExecutionFresh(snapshot, now: now) { return "工具执行待复查" }
        return snapshot.toolExecutionState == "已验证" ? "工具执行已验证" : "工具执行\(snapshot.toolExecutionState)"
    }
    private func activityDeferralReason(_ activity: ActivitySummary) -> String {
        if activity.activeCount > 0 { return "检测到本机调用进行中" }
        if activity.error { return "调用日志暂时不可读，无法确认空闲" }
        if activity.catchingUp { return "调用日志追赶中（剩余 \(activity.backlogBytes) 字节）" }
        if activity.pendingLine { return "等待调用日志当前行写完" }
        if activity.coverageGap { return "日志覆盖缺口：\(activity.gapReason)；无法确认空闲" }
        return "调用状态尚未确认"
    }
    @objc private func manualCheck() {
        if let reason = activeProbeStatus.blockReason { manualCheckBlocked(reason); return }
        guard !watchdog.recovering else { manualCheckBlocked("自动恢复处理中，暂不能手动检查"); return }
        guard !channelBusy, !manualPingBusy else { manualCheckBlocked("已有连接检查进行中"); return }
        guard channelIncident.activeCategory != nil || Date().timeIntervalSince(watchdog.startedAt) >= 90 else { manualCheckBlocked("启动等待中，暂不能手动检查"); return }
        guard snapshot.service == "运行中" else { manualCheckBlocked("Commander 服务未运行"); return }
        manualNotice = nil; manualPingBusy = true; deferredReason = "手动检查进行中"; render()
        let probe = MCPChannelProbe()
        probe.run { result in
            DispatchQueue.main.async {
                self.manualPingBusy = false
                self.recordProbe(result, now: Date(), manual: true, submitted: probe.submitted)
                self.manualNotice = probe.submitted ? "手动检查已完成：一次 ping；\(self.probeDescription(result))" : "未发送 ping：\(self.probeDescription(result))"; self.render()
            }
        }
    }
    private func manualCheckBlocked(_ reason: String) { manualNotice = reason; render() }
    private func considerRecovery() {
        let now = Date()
        if let reason = activeProbeStatus.permissionBlockReason { snapshot.channelDetail = "自动恢复已暂停：\(reason)"; render(); return }
        if localRestartSuppressed(for: channelIncident.activeCategory) {
            snapshot.channelDetail = "云端实时服务连接池异常；本机重启不会修复该容量问题"
            auditChannel(kind: "recovery_decision", result: "restart_suppressed_cloud_capacity",
                         action: "wait_for_cloud_recovery", at: now)
            render()
            return
        }
        guard recoveryLedger.autoRecoveryEnabled else {
            snapshot.channelDetail = "自动恢复已关闭"
            auditChannel(kind: "recovery_decision", result: "deferred_auto_recovery_disabled", action: "no_restart", at: now)
            render(); return
        }
        guard recoveryLedger.canAttempt(at: now) else {
            snapshot.channelDetail = "处于持久化冷却期"
            auditChannel(kind: "recovery_decision", result: "deferred_cooldown", action: "retry_later", at: now)
            render(); return
        }
        guard activitySafeForRecovery(snapshot.activity) else {
            snapshot.channelDetail = "本机调用或日志状态阻止恢复"
            auditChannel(kind: "recovery_decision", result: "deferred_activity_or_log", action: "no_restart", at: now)
            render(); return
        }
        watchdog.recovering = true
        recoveryLaunched = false
        auditChannel(kind: "recovery_decision", result: "safety_checks_started", action: "evaluate_restart", at: now)
        DispatchQueue.global(qos: .utility).async {
            guard let pid = self.servicePID(), CommanderProcessTree.safe(servicePID: pid) else {
                DispatchQueue.main.async { self.abortRecovery("进程树未知或含其他子进程；未重启", auditCode: "deferred_process_tree") }
                return
            }
            DispatchQueue.main.async {
                guard self.recoveryGateOpen(oldPID: pid) else { self.abortRecovery("本机调用状态或自动恢复设置已变化；未重启", auditCode: "deferred_gate_changed"); return }
                Monitor.shared.checkOutstandingCalls { idle, error in
                    guard idle == true else { self.abortRecovery(error ?? "云端待执行调用状态未知；未重启", auditCode: "deferred_outstanding_calls_unknown_or_busy"); return }
                    guard self.recoveryGateOpen(oldPID: pid) else { self.abortRecovery("本机调用状态或自动恢复设置已变化；未重启", auditCode: "deferred_gate_changed"); return }
                    DispatchQueue.global(qos: .utility).async {
                        let safe = self.servicePID() == pid && CommanderProcessTree.safe(servicePID: pid)
                        DispatchQueue.main.async {
                            guard safe, self.recoveryGateOpen(oldPID: pid) else { self.abortRecovery("服务进程或本机调用状态已变化；未重启", auditCode: "deferred_process_or_activity_changed"); return }
                            self.startRecovery(oldPID: pid)
                        }
                    }
                }
            }
        }
    }
    private func recoveryGateOpen(oldPID: Int32) -> Bool {
        activeProbeStatus.permissionBlockReason == nil && watchdog.recovering && recoveryLedger.autoRecoveryEnabled && recoveryLedger.canAttempt(at: Date()) &&
        snapshot.service == "运行中" && activitySafeForRecovery(snapshot.activity) && !activityBusy &&
        Date().timeIntervalSince(lastActivityPoll) < 3
    }
    private func abortRecovery(_ detail: String, auditCode: String = "deferred_unspecified") {
        watchdog.recovering = false
        recoveryLaunched = false
        snapshot.channelDetail = detail
        auditChannel(kind: "recovery_decision", result: auditCode, action: "no_restart")
        render()
    }
    private func startRecovery(oldPID: Int32) {
        guard recoveryGateOpen(oldPID: oldPID) else { abortRecovery("恢复前状态已变化；未重启", auditCode: "deferred_gate_changed"); return }
        guard servicePID() == oldPID else { abortRecovery("Commander 进程已变化；未重启", auditCode: "deferred_pid_changed"); return }
        let attemptAt = Date()
        recoveryLedger.recordAttempt(at: attemptAt)
        guard recoveryLedger.save(to: recoveryURL) else { abortRecovery("无法安全保存冷却记录；未重启", auditCode: "deferred_cooldown_persist_failed"); return }
        auditChannel(kind: "recovery", result: "restart_started", action: "local_commander_restart", at: attemptAt)
        lastRecoveryOutcome = "恢复进行中"
        snapshot.channelState = "正在恢复通道"; snapshot.channelDetail = "冷却已保存，正在重启固定的 Commander 服务"; render()
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "gui/\(getuid())/com.wuwendi.remote-desktop-commander"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { recoveryFinished(oldPID: oldPID, newPID: nil, result: .unknown("launchctl 无法启动")); return }
        recoveryLaunched = true
        DispatchQueue.global(qos: .utility).async {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { DispatchQueue.main.async { self.recoveryFinished(oldPID: oldPID, newPID: nil, result: .unknown("launchctl 重启失败")) }; return }
            var newPID: Int32?
            for _ in 0..<10 {
                Thread.sleep(forTimeInterval: 1)
                if let current = self.servicePID(), current != oldPID { newPID = current; break }
            }
            guard let newPID else { DispatchQueue.main.async { self.recoveryFinished(oldPID: oldPID, newPID: nil, result: .unknown("重启后服务 PID 未变化")) }; return }
            let probe = MCPChannelProbe()
            probe.run { result in DispatchQueue.main.async { self.recoveryFinished(oldPID: oldPID, newPID: newPID, result: result, submitted: probe.submitted) } }
        }
    }
    private func recoveryFinished(oldPID: Int32, newPID: Int32?, result: ChannelProbeResult, submitted: Bool = false) {
        let finishedAt = Date()
        watchdog.recovering = false; recoveryLaunched = false
        if submitted { lastPingAt = finishedAt; lastPingResult = probeDescription(result); snapshot.channelChecked = lastPingAt }
        if let newPID, newPID != oldPID { pendingRecoveryVerification = (oldPID, newPID) }
        lastRecoveryOutcome = newPID == nil ? resultMessageForMissingRecoveryProbe(result) : probeDescription(result)
        if submitted && recoveryConfirmed(oldPID: oldPID, newPID: newPID, currentPID: servicePID(), oldProcessExited: kill(oldPID, 0) == -1 && errno == ESRCH, probe: result) {
            pendingRecoveryVerification = nil
            watchdog.failures = 0; snapshot.channelState = "通道已恢复"; snapshot.channelDetail = "服务 PID 已变化，后续 MCP ping 成功"
            auditChannel(kind: "recovery", result: "restart_confirmed", action: "channel_recovered", at: finishedAt)
            markChannelIncidentRecovered(at: finishedAt, result: "recovered_after_guarded_restart")
            if let newPID {
                verifiedRestart = (oldPID, newPID)
                pollActivity()
            }
        } else {
            snapshot.channelState = "恢复尚未确认"; snapshot.channelDetail = newPID == nil ? (watchdog.detail + "；" + probeDescription(result)) : submitted ? "服务已重启，但后续 MCP ping 未成功（\(probeDescription(result))）" : "服务已重启，等待下次实际 ping 确认（\(probeDescription(result))）"
            auditChannel(kind: "recovery", result: "restart_unconfirmed", action: "retain_fault_history", at: finishedAt)
            if channelIncident.activeCategory != nil { channelIncident.scheduleAfterCheck(now: finishedAt); saveChannelIncident() }
        }
        snapshot.channelFailures = watchdog.failures; render()
    }
    private func probeDescription(_ result: ChannelProbeResult) -> String {
        switch result { case .healthy: return "ping 成功"; case .noLiveConnection: return "设备连接仍不可用"; case .unknown(let message): return message }
    }
    private func resultMessageForMissingRecoveryProbe(_ result: ChannelProbeResult) -> String {
        switch result { case .healthy, .noLiveConnection: return "本次运行未观察到恢复后 ping 结果"; case .unknown(let message): return message }
    }
    private func servicePID() -> Int32? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = ["print", "gui/\(getuid())/com.wuwendi.remote-desktop-commander"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8), text.contains("state = running"),
              let match = text.range(of: #"(?m)^\s*pid = ([0-9]+)\s*$"#, options: .regularExpression),
              let pidRange = text[match].range(of: #"[0-9]+"#, options: .regularExpression) else { return nil }
        return Int32(text[pidRange])
    }
    private func pollActivity() {
        guard !activityBusy else { return }
        let restart = verifiedRestart; verifiedRestart = nil
        let now = Date(), pollHistory = now.timeIntervalSince(lastToolHistoryPoll) >= 5
        if pollHistory { lastToolHistoryPoll = now }
        activityBusy = true
        DispatchQueue.global(qos: .utility).async {
            if let restart { self.activityReader.confirmedProcessRestart(oldPID: restart.old, newPID: restart.new, oldProcessExited: true) }
            self.activityReader.poll()
            if pollHistory { self.toolHistoryReader.poll() }
            self.timelineReader.poll()
            let value = self.activityReader.summary
            let history = self.toolHistoryReader.summary
            let timeline = self.timelineReader.summary
            DispatchQueue.main.async {
                self.snapshot.activity = value; self.snapshot.toolHistory = history; self.snapshot.timeline = timeline; self.lastActivityPoll = Date(); self.activityBusy = false
                self.processChannelTimeline(timeline, now: Date())
                self.refreshToolExecutionFromActivity(value)
                self.render()
            }
        }
    }
    private func serviceRunning() -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = ["print", "gui/\(getuid())/com.wuwendi.remote-desktop-commander"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return false }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 && String(data: data, encoding: .utf8)?.contains("state = running") == true && String(data: data, encoding: .utf8)?.contains("pid = ") == true
    }
    private func updateGuard() {
        if !paused && snapshot.service == "运行中" && assertion == 0 {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Commander service guardian" as CFString, &assertion)
            if result != kIOReturnSuccess { assertion = 0 }
        } else if (paused || snapshot.service != "运行中") && assertion != 0 { releaseAssertion() }
        guardItem.state = paused ? .off : .on
    }
    private func releaseAssertion() { if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 } }
    private func render() {
        guard summaryLines.count == 5 else { return }
        let activity = snapshot.activity
        let clockText: (Date) -> String = { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) }
        let now = Date()
        let activeIncident = channelIncident.activeCategory
        let connection = activeIncident == nil ? channelIndicator(service: snapshot.service, state: snapshot.channelState, checked: snapshot.channelChecked, now: now) : "!"
        let channelLiveSummary = channelSummary(snapshot, now: now)
        let channelHeadline = activeIncident?.title ?? channelLiveSummary
        let menuChannel: String
        if activeIncident != nil {
            menuChannel = "! 通道故障"
        } else if snapshot.service == "未运行" {
            menuChannel = "! 服务未运行"
        } else if snapshot.channelState == "通道异常" || snapshot.channelState == "通道不可用" {
            menuChannel = "! 通道异常"
        } else if snapshot.channelState == "通道畅通" || snapshot.channelState == "通道已恢复" {
            menuChannel = connection == "●" ? "● 通道正常" : "? 上次成功 \(snapshot.channelChecked.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "时间未知")"
        } else {
            menuChannel = "? 通道未确认"
        }
        let connectionText = "Commander 服务\(snapshot.service == "运行中" ? "运行中" : (snapshot.service == "未运行" ? "未运行" : "状态未知"))"
        summaryLines[0].title = activeIncident.map { "消息通道：\($0.title) · \(channelIncidentHandling(now: now))" } ?? "消息通道：\(channelLiveSummary)"
        summaryLines[1].title = "工具执行：\(toolExecutionSummary(now: now))"
        let uptime = ProcessInfo.processInfo.systemUptime
        if let step = currentCallStep(activity) {
            let elapsed = durationText(step.elapsed(at: ProcessInfo.processInfo.systemUptime))
            let timing = step.uncertain ? "耗时未确认" : "等待返回 \(elapsed)"
            summaryLines[2].title = "活动：\(middleTruncate(CommanderActivity.menuDetail(step.detail), limit: 80)) · \(step.historical ? "开始时间未知" : clockText(step.startedAt)) · \(timing)"
        } else if let step = recentlyReturnedCall(activity, uptime: uptime) {
            summaryLines[2].title = "活动：\(middleTruncate(CommanderActivity.menuDetail(step.detail), limit: 80)) · 调用耗时 \(durationText(step.duration))"
        } else {
            summaryLines[2].title = "活动：\(activity.catchingUp ? "日志追赶中；暂不能确认空闲" : (activity.error || activity.coverageGap ? "日志不完整；暂不能确认空闲" : callState(activity)))"
        }
        summaryLines[3].title = "自动恢复：\(recoveryAvailability())"
        summaryLines[4].title = chatMonitorSummary(snapshot.timeline).menuLine
        let activeStep = currentCallStep(activity)
        let callStatus = callState(activity)
        let barTimer = activeStep.map { barCallClock($0, uptime: uptime) } ?? ""
        let returnedStep = activeStep == nil ? recentlyReturnedCall(activity, uptime: uptime) : nil
        let barAction = activeStep.map(\.detail) ?? returnedStep.map(\.detail) ?? callStatus
        let barDuration = returnedStep.map { durationText($0.duration) }
        item.button?.title = "\(menuChannel)\(barTimer.isEmpty ? (barDuration.map { " · \($0)" } ?? "") : " · \(barTimer)")"
        item.button?.setAccessibilityLabel("CommanderGuard，\(channelHeadline)")
        item.button?.setAccessibilityValue("消息通道当前健康：\(channelLiveSummary)；处置：\(channelIncidentHandling(now: now))；本机操作：\(barAction)；\(callStatus)")
        item.button?.setAccessibilityHelp("点击打开运行概览；右键可查看菜单")
        let origin = "消息通道与本机工具执行分别验证；任一层成功都不代表 ChatGPT 原回答完成。\(conversationLabelNote(snapshot.timeline.conversationLabelsVerifiedAt)) 无新事件不表示空闲或完成。"
        let age = activity.observed.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "未知"
        let incidentTooltip = activeIncident.map { "\n当前故障：\($0.title)\n处置：\(channelIncidentHandling(now: now))\n首次发现：\(prominentStamp(channelIncident.firstSeen)) · 最近发生：\(prominentStamp(channelIncident.lastSeen))" } ?? (channelIncident.recentCategory.map { "\n最近故障：\($0.title) · \(channelIncident.recoveredAt == nil ? "恢复未确认" : "已恢复 \(prominentStamp(channelIncident.recoveredAt))")" } ?? "")
        item.button?.toolTip = "\(connectionText)\n消息通道当前健康：\(channelLiveSummary) · \(displayPingResult(snapshot.channelDetail))\(incidentTooltip)\n工具执行：\(toolExecutionSummary(now: now)) · \(snapshot.toolExecutionDetail)\n\(returnedStep == nil ? "" : "本机调用已返回 · ")\(barAction)\(barDuration.map { " · 调用耗时 \($0)" } ?? "") · \(callStatus) · \(age)\n\(manualNotice.map { "手动检查：\(displayPingResult($0))\n" } ?? "")\(origin)"
        if !previewMode { writeStatus() }
        if panelWindow?.isVisible == true { renderPanel() }
    }
    private func recoveryAvailability() -> String {
        guard recoveryLedger.autoRecoveryEnabled else { return "已关闭" }
        if let reason = activeProbeStatus.permissionBlockReason { return "已暂停 · \(reason)" }
        if localRestartSuppressed(for: channelIncident.activeCategory) {
            return "云端容量异常 · 不重启本机 · 退避复查"
        }
        if watchdog.recovering { return "恢复中" }
        guard recoveryLedger.canAttempt(at: Date()) else { return "已开启 · 冷却中" }
        guard snapshot.service == "运行中" else { return "已开启 · 等待 Commander 服务" }
        if !activitySafeForRecovery(snapshot.activity) { return "已开启 · 暂缓：\(activityDeferralReason(snapshot.activity))" }
        if channelIncident.activeCategory != nil { return "已开启 · \(channelIncidentHandling())" }
        return channelIndicator(service: snapshot.service, state: snapshot.channelState, checked: snapshot.channelChecked, now: Date()) == "●"
            ? "已开启 · 监测中，当前无需恢复" : "已开启 · 等待下一次通道检查"
    }
    private func durationText(_ value: TimeInterval?) -> String {
        guard let value else { return "未确认" }
        return value < 1 ? "<1 秒" : "\(Int(value)) 秒"
    }
    private func toolHistoryLatestSummary() -> String {
        guard let record = snapshot.toolHistory.latest else { return "暂无结构化记录" }
        let duration = record.duration.map(durationText) ?? "耗时未确认"
        let caveat = record.processCaveat.map { " · \($0)" } ?? ""
        return "\(prominentStamp(record.timestamp)) · \(record.label) · \(record.resultLabel) · \(duration)\(caveat) · \(record.cloudReceiptLabel)"
    }
    private func quotaDisplay() -> String {
        if quota.total == nil, let used = quota.used, !quota.plan.isEmpty { return "\(used) 次 · \(quota.plan.lowercased() == "pro" ? "Pro" : quota.plan) 无限制" }
        guard let used = quota.used, let total = quota.total else { return quota.state == .connecting ? "正在连接…" : quota.state == .refreshing ? "正在读取…" : "暂无额度数据" }
        return "\(used) / \(total) 次 · 剩余 \(quota.remaining ?? 0) 次"
    }
    private func ageQuota() {
        if quotaIsStale(quota, now: Date(), refreshSeconds: quotaRefreshSeconds), quota.state == .fresh || quota.state == .unlimited { quota.state = .stale }
    }
    private func quotaStateText() -> String {
        ageQuota()
        let old = quotaIsStale(quota, now: Date(), refreshSeconds: quotaRefreshSeconds) ? " · 上次数据已过期" : ""
        switch quota.state {
        case .disconnected: return "未连接 · 连接后读取官方用量"
        case .connecting: return quotaBrowser.hasOwnedLogin ? "登录后点击“完成登录并同步”" : "登录窗口仍打开；退出后再刷新"
        case .refreshing: return "正在刷新" + (quota.used == nil ? "" : " · 保留上次数据") + old
        case .loginRequired: return "需要登录 · 点击连接账户" + old
        case .unavailable: return (quotaFailureReason.map { "同步失败：\($0)" } ?? "额度暂不可用") + (quota.used == nil ? " · 可稍后刷新" : " · 保留上次成功数据") + old
        case .fresh: return "当前周期：\(quota.month) · \(quota.plan)" + old
        case .stale: return "数据已过期 · 保留上次成功读取（\(quota.month)）" + (quotaFailureReason.map { " · \($0)" } ?? "")
        case .unlimited: return "当前周期：\(quota.month) · \(quota.plan) · 无限制" + old
        }
    }
    private func renderQuota() {
        ageQuota()
        quotaValue?.stringValue = quotaDisplay()
        quotaValue?.textColor = quotaIsStale(quota, now: Date(), refreshSeconds: quotaRefreshSeconds) ? .systemOrange : .labelColor
        quotaStatus?.stringValue = quotaStateText()
        quotaSynced?.stringValue = "上次成功同步：\(displayEvidenceTime(quota.syncedAt))"
        quotaButton?.title = quotaEnabled ? "登录" : "连接"
        quotaButton?.isEnabled = !previewMode && !quotaRequestInFlight && quota.state != .refreshing
        quotaRefreshButton?.title = quotaBrowser.hasOwnedLogin ? "完成登录" : "刷新"
        quotaRefreshButton?.isEnabled = !previewMode && !quotaRequestInFlight && quota.state != .refreshing
        quotaPauseButton?.isEnabled = !previewMode && quotaEnabled
        if !quotaIntervalMenuOpen { quotaIntervalPicker?.selectItem(at: quotaRefreshOptions.firstIndex(of: quotaRefreshSeconds) ?? 3) }
        if let progress = quotaProgress {
            let finite = quota.total.flatMap { total in quota.used.map { (total, $0) } }
            progress.isHidden = finite == nil
            if let (total, used) = finite { progress.doubleValue = total == 0 ? 0 : min(1, Double(used) / Double(total)) }
        }
        if item != nil { render() }
    }
    private func quotaSection() -> NSView {
        let connect = NSButton(title: quotaEnabled ? "登录" : "连接", target: self, action: #selector(connectQuota)); connect.bezelStyle = .rounded; connect.isEnabled = !previewMode && !quotaRequestInFlight && quota.state != .refreshing
        let refresh = NSButton(title: quotaBrowser.hasOwnedLogin ? "完成登录" : "刷新", target: self, action: #selector(manualQuotaRefresh)); refresh.bezelStyle = .rounded; refresh.isEnabled = !previewMode && !quotaRequestInFlight && quota.state != .refreshing
        let pause = NSButton(title: "暂停", target: self, action: #selector(pauseQuota)); pause.bezelStyle = .rounded; pause.isEnabled = !previewMode && quotaEnabled
        let intervalLabel = label("自动同步", size: 12, color: .secondaryLabelColor)
        let interval = NSPopUpButton()
        interval.addItems(withTitles: ["手动", "每分钟", "每 2 分钟", "每 5 分钟", "每 10 分钟", "每 30 分钟", "每小时"])
        interval.selectItem(at: quotaRefreshOptions.firstIndex(of: quotaRefreshSeconds) ?? 3)
        interval.target = self; interval.action = #selector(quotaRefreshIntervalChanged(_:)); interval.isEnabled = !previewMode
        interval.menu?.delegate = self
        interval.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let title = label("额度", size: 12, weight: .semibold, color: .secondaryLabelColor)
        let actions = NSStackView(views: [title, NSView(), pause, refresh, connect]); actions.orientation = .horizontal; actions.alignment = .centerY; actions.spacing = 8
        let intervalRow = NSStackView(views: [intervalLabel, interval, NSView()]); intervalRow.orientation = .horizontal; intervalRow.alignment = .centerY; intervalRow.spacing = 8
        let value = label(quotaDisplay(), size: 17, weight: .semibold)
        let progress = NSProgressIndicator(); progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1; progress.style = .bar; progress.heightAnchor.constraint(equalToConstant: 5).isActive = true
        if let total = quota.total, let used = quota.used { progress.doubleValue = total == 0 ? 0 : min(1, Double(used) / Double(total)) } else { progress.isHidden = true }
        let status = label(quotaStateText(), size: 12, color: .secondaryLabelColor)
        let synced = label("上次成功同步：\(displayEvidenceTime(quota.syncedAt))", size: 17, weight: .semibold)
        synced.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        synced.textColor = .labelColor
        if quotaIsStale(quota, now: Date(), refreshSeconds: quotaRefreshSeconds) { value.textColor = .systemOrange }
        let stack = vertical(7)
        [actions, intervalRow, value, progress, status, synced].forEach { stack.addArrangedSubview($0); $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        quotaButton = connect; quotaPauseButton = pause; quotaRefreshButton = refresh; quotaIntervalPicker = interval; quotaValue = value; quotaStatus = status; quotaSynced = synced; quotaProgress = progress
        return card(stack, padding: 12)
    }
    private func quotaAndTaskSection(_ taskRows: [(String, String)]) -> NSView {
        let row = NSStackView(views: [quotaSection(), section("当前任务", rows: taskRows)])
        row.orientation = .horizontal; row.alignment = .top; row.distribution = .fillEqually; row.spacing = 9
        return row
    }
    private func clearQuota(_ state: UsageQuota.State) {
        quotaFailureReason = nil
        quota = UsageQuota(state: state)
        renderQuota()
    }
    func menuWillOpen(_ menu: NSMenu) {
        if menu === quotaIntervalPicker?.menu { quotaIntervalMenuOpen = true }
        if menu === panelProbeIntervalPicker?.menu { probeIntervalMenuOpen = true }
    }
    func menuDidClose(_ menu: NSMenu) {
        if menu === quotaIntervalPicker?.menu { quotaIntervalMenuOpen = false }
        if menu === panelProbeIntervalPicker?.menu { probeIntervalMenuOpen = false }
    }
    @objc private func probeRefreshIntervalChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard !previewMode, ActiveProbeBudget.intervalOptions.indices.contains(index) else { return }
        guard ActiveProbeBudget.shared.setIntervalSeconds(ActiveProbeBudget.intervalOptions[index]) else {
            manualCheckBlocked("探测频率无法安全保存；设置未改变"); return
        }
        manualNotice = "探测频率已保存；计费关系未确认，开关状态不变"
        render()
    }
    @objc private func quotaRefreshIntervalChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard quotaRefreshOptions.indices.contains(index) else { return }
        UserDefaults.standard.set(quotaRefreshOptions[index], forKey: "quotaRefreshSeconds")
        resetQuotaTimer()
        renderQuota()
    }
    private func resetQuotaTimer() {
        quotaTimer?.invalidate(); quotaTimer = nil
        guard !previewMode, quotaEnabled, quotaRefreshSeconds > 0 else { return }
        quotaTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(quotaRefreshSeconds), repeats: true) { _ in self.refreshQuota() }
    }
    private func chromeExecutableURL() -> URL? {
        let candidates = [URL(fileURLWithPath: "/Applications/Google Chrome.app"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Google Chrome.app")]
        return candidates.first(where: { Bundle(url: $0)?.bundleIdentifier == "com.google.Chrome" })?.appendingPathComponent("Contents/MacOS/Google Chrome")
    }
    @objc private func connectQuota() {
        guard !previewMode, !quotaRequestInFlight, !quotaTerminateWhenIdle else { return }
        guard let executable = chromeExecutableURL() else { quotaFailureReason = "未找到 Google Chrome，请先安装"; quota.state = .unavailable; renderQuota(); return }
        do {
            _ = try quotaBrowser.openLogin(chromeExecutable: executable)
            UserDefaults.standard.set(true, forKey: "quotaConnectionEnabled")
            quotaFailureReason = nil; quota.state = .connecting
            resetQuotaTimer(); renderQuota()
        } catch {
            quotaFailureReason = (error as? HeadlessQuotaBrowser.Failure)?.errorDescription ?? "专用登录窗口无法打开"
            quota.state = .unavailable; renderQuota()
        }
    }
    @objc private func manualQuotaRefresh() {
        guard !previewMode, !quotaRequestInFlight, !quotaTerminateWhenIdle else { return }
        guard quotaEnabled else { connectQuota(); return }
        if quotaBrowser.finishOwnedLogin() { quota.state = .connecting; renderQuota(); return }
        refreshQuota()
    }
    @objc private func pauseQuota() {
        UserDefaults.standard.set(false, forKey: "quotaConnectionEnabled")
        resetQuotaTimer()
        quotaCancelRequested = quotaRequestInFlight
        quotaBrowser.cancel()
        clearQuota(.disconnected)
    }
    @objc private func refreshQuota() {
        guard !previewMode, quotaEnabled, !quotaRequestInFlight, !quotaTerminateWhenIdle else { return }
        guard let executable = chromeExecutableURL() else { quotaFailureReason = "未找到 Google Chrome，请先安装"; quota.state = .unavailable; renderQuota(); return }
        quotaRequestInFlight = true
        quotaFailureReason = nil; quota.state = .refreshing; renderQuota()
        quotaBrowser.read(chromeExecutable: executable) { [weak self] result in
            guard let self else { return }
            self.quotaRequestInFlight = false
            if self.quotaCancelRequested || self.quotaTerminateWhenIdle || !self.quotaEnabled {
                self.clearQuota(.disconnected)
            } else {
                switch result {
                case .success(let value): self.quota = value; self.quotaFailureReason = nil
                case .loginRequired: self.quota = UsageQuota(state: .loginRequired); self.quotaFailureReason = nil
                case .loginOpen: self.quota.state = .connecting; self.quotaFailureReason = nil
                case .unavailable(let reason): self.quota.state = .unavailable; self.quotaFailureReason = reason
                case .cancelled: self.quota.state = .disconnected; self.quotaFailureReason = nil
                }
                self.renderQuota()
            }
            self.quotaCancelRequested = false
            if self.quotaTerminateWhenIdle {
                self.quotaTerminateWhenIdle = false
                NSApp.reply(toApplicationShouldTerminate: true)
            } else if self.quotaRefreshAfterLogin {
                self.quotaRefreshAfterLogin = false
                if self.quotaEnabled { self.refreshQuota() }
            }
        }
    }
    private func middleTruncate(_ value: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard value.count > limit else { return value }
        guard limit > 1 else { return "…" }
        let budget = limit - 1
        let prefixCount = max(1, (budget + 1) / 2)
        let suffixCount = max(0, budget - prefixCount)
        let prefix = String(value.prefix(prefixCount))
        let suffix = String(value.suffix(suffixCount))
        return "\(prefix)…\(suffix)"
    }
    private func writeStatus() {
        ageQuota()
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CommanderGuard", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { fputs("CommanderGuard: unable to create status directory\n", stderr); return }
        let rows = activityStepRows(snapshot.activity.steps, uptime: ProcessInfo.processInfo.systemUptime)
        let safeSteps: [[String: Any]] = snapshot.activity.steps.map { step in ["tool": CommanderActivity.safeToolIdentifier(step.tool), "detail": step.detail, "started_at": step.historical ? NSNull() : ISO8601DateFormatter.flex.string(from: step.startedAt) as Any, "elapsed_seconds": step.elapsed(at: ProcessInfo.processInfo.systemUptime) as Any? ?? NSNull(), "duration_seconds": step.duration as Any? ?? NSNull(), "uncertain": step.uncertain, "failed": step.failed, "historical": step.historical, "finished": step.finished, "session": CommanderActivity.sessionDisplay(step.sessionKey) as Any? ?? NSNull(), "session_source": step.sessionSource as Any? ?? NSNull(), "session_attribution_conflict": step.sessionAttributionConflict] }
        let latestStep = currentCallStep(snapshot.activity)
        let callElapsed = latestStep?.elapsed(at: ProcessInfo.processInfo.systemUptime)
        let currentState = callState(snapshot.activity)
        let timelineRows: [[String: Any]] = snapshot.timeline.events.map { ["source": $0.source, "event": $0.event, "conversation_title": $0.conversationTitle as Any? ?? NSNull(), "failure_kind": $0.failureKind as Any? ?? NSNull(), "source_timestamp": $0.sourceAt as Any? ?? NSNull(), "observed_at": $0.observedAt] }
        let lastAppEvent: [String: Any] = snapshot.timeline.latestAppEvent.map { ["event": $0.event, "conversation_title": $0.conversationTitle as Any? ?? NSNull(), "failure_kind": $0.failureKind as Any? ?? NSNull(), "source_timestamp": $0.sourceAt as Any? ?? NSNull(), "observed_at": $0.observedAt] } ?? [:]
        let chat = chatMonitorSummary(snapshot.timeline)
        let diagnosis = currentDiagnosis()
        var object: [String: Any] = ["chatgpt": ["answer": chat.answer, "update_connection": chat.connection, "recent_issue": chat.history as Any? ?? NSNull(), "coverage": snapshot.timeline.coverage, "delivery_timeout_directly_observable": false, "limitation": chat.deliveryLimit], "service": snapshot.service, "cloud": snapshot.cloud, "last_seen": snapshot.lastSeen.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "checked_at": ISO8601DateFormatter.flex.string(from: snapshot.checked), "error_count": snapshot.errorCount, "paused": paused, "idle_prevention": assertion != 0, "message": snapshot.message, "channel": ["state": snapshot.channelState, "detail": snapshot.channelDetail, "consecutive_no_live": snapshot.channelFailures, "checked_at": snapshot.channelChecked.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "auto_recovery_enabled": recoveryLedger.autoRecoveryEnabled, "last_recovery_attempt": recoveryLedger.lastAttempt.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "last_ping_at": lastPingAt.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "last_ping_result": lastPingResult, "check_deferred_reason": deferredReason, "recovery_status": recoveryAvailability(), "last_recovery_result": lastRecoveryOutcome as Any? ?? NSNull()], "menu": ["menubar_title": item.button?.title ?? "", "menubar_has_icon": item.button?.image != nil, "connection": summaryLines[0].title, "channel": summaryLines[0].title, "tool_execution": summaryLines[1].title, "action": summaryLines[2].title, "recovery": summaryLines[3].title, "chatgpt": summaryLines[4].title, "execution_step_rows": rows, "execution_steps": safeSteps, "tool_call_elapsed_seconds": callElapsed as Any? ?? NSNull(), "tool_call_state": currentState, "recent_actions": snapshot.activity.recent], "activity": ["state": snapshot.activity.state, "tool": CommanderActivity.safeToolIdentifier(snapshot.activity.tool), "active_count": snapshot.activity.activeCount, "observed_at": snapshot.activity.observed.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "recent": snapshot.activity.recent, "error": snapshot.activity.error, "coverage_gap": snapshot.activity.coverageGap, "gap_reason": snapshot.activity.gapReason, "gap_first_at": snapshot.activity.gapFirstAt.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "gap_last_at": snapshot.activity.gapLastAt.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "backlog_bytes": snapshot.activity.backlogBytes, "catching_up": snapshot.activity.catchingUp, "pending_line": snapshot.activity.pendingLine, "idle_proven": snapshot.activity.idleProven], "timeline": ["coverage": snapshot.timeline.coverage, "commander_errors_this_run": snapshot.timeline.commanderErrors, "conversation_labels_verified_at": snapshot.timeline.conversationLabelsVerifiedAt as Any? ?? NSNull(), "last_chatgpt_app_event": lastAppEvent, "events": timelineRows]]
        let probeBudget = activeProbeStatus
        object["active_probing"] = ["enabled": probeBudget.enabled, "interval_seconds": probeBudget.intervalSeconds, "estimated_calls_per_day": probeBudget.dailyEstimate, "last_submitted_at": probeBudget.lastSubmittedAt.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "next_allowed_at": probeBudget.nextAllowedAt.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "blocked_reason": probeBudget.blockReason as Any? ?? NSNull(), "billing_confirmed_free": false]
        object["tool_execution"] = ["state": snapshot.toolExecutionState, "detail": snapshot.toolExecutionDetail, "checked_at": snapshot.toolExecutionChecked.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "fresh": toolExecutionFresh(snapshot, now: Date()), "evidence_ttl_seconds": Int(toolExecutionEvidenceTTL), "probe_deferred_reason": toolProbeDeferredReason]
        object["usage_quota"] = ["state": quota.state.rawValue, "used": quota.used as Any? ?? NSNull(), "total": quota.total as Any? ?? NSNull(), "remaining": quota.remaining as Any? ?? NSNull(), "plan": quota.plan.isEmpty ? NSNull() : quota.plan as Any, "month": quota.month.isEmpty ? NSNull() : quota.month as Any, "last_successful_sync": quota.syncedAt.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "last_error": quotaFailureReason as Any? ?? NSNull(), "refresh_interval_seconds": quotaRefreshSeconds, "backend": "chrome_headless_private_profile"]
        object["channel_incident"] = [
            "active": channelIncident.activeCategory != nil,
            "category": channelIncident.activeCategory?.rawValue as Any? ?? NSNull(),
            "recent_category": channelIncident.recentCategory?.rawValue as Any? ?? NSNull(),
            "first_seen": channelIncident.firstSeen.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(),
            "last_seen": channelIncident.lastSeen.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(),
            "recovered_at": channelIncident.recoveredAt.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(),
            "event_count": channelIncident.eventCount,
            "capacity_alert_issued": channelIncident.alertIssued,
            "handling": channelIncidentHandling(),
            "next_recheck": channelIncident.nextRecheck.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(),
            "recheck_attempt": channelIncident.recheckAttempt,
            "last_probe_at": channelIncident.lastProbeAt.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(),
            "last_probe_result": channelIncident.lastProbeResult as Any? ?? NSNull(),
            "decision_log": "channel-decisions.jsonl"
        ]
        let latestHistory: [String: Any] = snapshot.toolHistory.latest.map { record in ["tool": CommanderActivity.safeToolIdentifier(record.tool), "label": record.label, "timestamp": ISO8601DateFormatter.flex.string(from: record.timestamp), "duration_seconds": record.duration as Any? ?? NSNull(), "result": record.resultLabel, "cloud_receipt": record.cloudReceiptLabel, "process_caveat": record.processCaveat as Any? ?? NSNull()] } ?? [:]
        object["tool_history"] = ["state": snapshot.toolHistory.state, "source_available": snapshot.toolHistory.sourceAvailable, "bootstrap_limited": snapshot.toolHistory.bootstrapLimited, "coverage_gap": snapshot.toolHistory.coverageGap, "gap_reason": snapshot.toolHistory.gapReason, "malformed_lines": snapshot.toolHistory.malformedLines, "backlog_bytes": snapshot.toolHistory.backlogBytes, "latest": latestHistory, "limitation": "结构化历史无可靠调用编号，不按时间与会话或 stdout 记录合并"]
        object["diagnosis"] = ["title": diagnosis.title, "started_at": diagnosis.startedAt.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "last_seen_at": diagnosis.lastSeenAt.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "next_action": diagnosis.nextAction, "evidence": diagnosis.evidence]
        guard let d = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        do { try d.write(to: dir.appendingPathComponent("status.json"), options: .atomic) }
        catch { fputs("CommanderGuard: unable to write sanitized status file\n", stderr) }
    }
    @objc private func togglePause() { paused.toggle(); UserDefaults.standard.set(!paused, forKey: "keepAwakeEnabled"); updateGuard(); render() }
    @objc private func toggleActiveProbing() {
        let enabled = !activeProbeStatus.enabled
        guard ActiveProbeBudget.shared.setEnabled(enabled) else { manualCheckBlocked("主动探测设置无法安全保存；设置未改变，不会发送探测"); return }
        manualNotice = enabled ? "主动探测已开启：自动、手动与恢复后探测共用所选间隔，可能消耗额度" : "主动探测已关闭；已提交的请求可能仍会计费，本机观察与额度同步继续"
        if !enabled && watchdog.recovering && !recoveryLaunched { abortRecovery("主动探测已关闭；自动恢复已暂停，未开始重启") }
        else { render() }
    }
    @objc private func toggleAutoRecovery() {
        var next = recoveryLedger; next.autoRecoveryEnabled.toggle()
        guard next.save(to: recoveryURL) else { manualNotice = "自动恢复设置无法保存；设置未改变"; snapshot.channelDetail = manualNotice!; render(); return }
        manualNotice = nil
        recoveryLedger = next; recoveryItem.state = next.autoRecoveryEnabled ? .on : .off
        if !next.autoRecoveryEnabled && watchdog.recovering && !recoveryLaunched { abortRecovery("自动恢复已关闭；未开始重启") }
        else { render() }
    }
    @objc private func statusBarClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let menu = statusMenu, let button = item.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        } else { openPanel() }
    }

    @objc private func openPanel() {
        if panelWindow == nil { buildPanel() }
        renderPanel()
        panelWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openLogWindow() { panelPage = 1; openPanel(); panelNav?.selectedSegment = 1; renderPanelPage() }
    @objc private func openDiagnosticWindow() { panelPage = 2; openPanel(); panelNav?.selectedSegment = 2; renderPanelPage() }
    @objc private func panelPageChanged(_ sender: NSSegmentedControl) { panelPage = sender.selectedSegment; renderPanelPage() }

    private func label(_ value: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    private func vertical(_ spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }
    private func card(_ content: NSView, padding: CGFloat = 18) -> NSView {
        let card = PanelCardView()
        card.wantsLayer = true; card.layer?.cornerRadius = 16; card.layer?.masksToBounds = true
        card.layer?.borderColor = NSColor.separatorColor.cgColor; card.layer?.borderWidth = 1
        card.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -padding),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -padding)
        ])
        return card
    }
    private func heroCard(_ eyebrow: String, value: NSTextField, time: NSTextField, detail: NSTextField) -> NSView {
        let stack = vertical(2)
        stack.addArrangedSubview(label(eyebrow, size: 10, weight: .semibold, color: .secondaryLabelColor))
        stack.addArrangedSubview(value); stack.addArrangedSubview(time)
        stack.addArrangedSubview(detail)
        value.font = .systemFont(ofSize: 14, weight: .semibold)
        value.maximumNumberOfLines = 1
        time.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        time.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 12, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        return card(stack, padding: 8)
    }
    private func buildPanel() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = previewMode ? "CommanderGuard · 界面预览" : "CommanderGuard"
        if previewMode && CommandLine.arguments.contains("--preview-dark") { window.appearance = NSAppearance(named: .darkAqua) }
        if previewMode && CommandLine.arguments.contains("--preview-light") { window.appearance = NSAppearance(named: .aqua) }
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 760, height: 560); window.center()
        let root = PanelBackgroundView(); root.wantsLayer = true; window.contentView = root
        let layout = vertical(9); layout.edgeInsets = NSEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
        root.addSubview(layout); layout.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([layout.leadingAnchor.constraint(equalTo: root.leadingAnchor), layout.trailingAnchor.constraint(equalTo: root.trailingAnchor), layout.topAnchor.constraint(equalTo: root.topAnchor), layout.bottomAnchor.constraint(equalTo: root.bottomAnchor)])

        let title = vertical(4)
        title.addArrangedSubview(label("COMMANDERGUARD", size: 11, weight: .bold, color: .secondaryLabelColor))
        title.addArrangedSubview(label("运行概览", size: 21, weight: .bold))
        if previewMode { title.addArrangedSubview(label("设计预览 · 固定示例数据", size: 12, color: .secondaryLabelColor)) }
        layout.addArrangedSubview(title)
        panelHeading = title

        let commandValue = label("等待观察"); let commandTime = label("检查：暂无"); let commandDetail = label("")
        let toolValue = label("未验证"); let toolTime = label("检查：暂无"); let toolDetail = label("")
        let chatValue = label("等待读取"); let chatTime = label("问题：暂无"); let chatDetail = label("")
        panelConnection = commandValue; panelConnectionTime = commandTime; panelConnectionDetail = commandDetail
        panelToolExecution = toolValue; panelToolExecutionTime = toolTime; panelToolExecutionDetail = toolDetail
        panelChat = chatValue; panelChatTime = chatTime; panelChatDetail = chatDetail
        let heroes = NSStackView(); heroes.orientation = .horizontal; heroes.spacing = 10; heroes.distribution = .fillEqually
        panelHeroes = heroes
        let commandCard = heroCard("消息通道", value: commandValue, time: commandTime, detail: commandDetail)
        let toolCard = heroCard("工具执行", value: toolValue, time: toolTime, detail: toolDetail)
        let chatCard = heroCard("ChatGPT 观察", value: chatValue, time: chatTime, detail: chatDetail)
        [commandCard, toolCard, chatCard].forEach { heroes.addArrangedSubview($0) }
        toolCard.heightAnchor.constraint(equalTo: commandCard.heightAnchor).isActive = true
        chatCard.heightAnchor.constraint(equalTo: commandCard.heightAnchor).isActive = true
        panelHeroMinimum = heroes.heightAnchor.constraint(greaterThanOrEqualToConstant: 56)
        panelHeroMinimum?.isActive = true
        layout.addArrangedSubview(heroes)
        heroes.widthAnchor.constraint(equalTo: layout.widthAnchor, constant: -56).isActive = true

        let controls = NSStackView(); controls.orientation = .horizontal; controls.alignment = .centerY; controls.spacing = 22
        let recovery = NSButton(checkboxWithTitle: "自动恢复本机 Commander", target: self, action: #selector(toggleAutoRecovery))
        recovery.toolTip = "云端主动探测关闭时自动恢复暂停；开启后自动探测累计 3 次明确断链，且日志完整并确认没有本机任务时，才重启本机 Commander。恢复后确认需等待所选探测间隔；不会重试原任务或修复云端问题。"
        let wake = NSButton(checkboxWithTitle: "防止闲置睡眠（Guard）", target: self, action: #selector(togglePause))
        wake.toolTip = "仅防止系统因闲置而睡眠，不阻止手动睡眠、屏幕息屏或重启。关闭只撤销 Guard 的请求；其他程序仍可能保持唤醒。"
        let check = NSButton(title: "手动 ping（1次）", target: self, action: #selector(manualCheck)); check.bezelStyle = .rounded
        check.toolTip = "需要开启云端主动探测且所选间隔已到；此按钮只发送一次 ping，可能消耗一次额度，与自动和恢复后检查共用间隔。"
        panelManualCheck = check
        [recovery, wake, check].forEach { $0.isEnabled = !previewMode }
        panelRecoveryToggle = recovery; panelWakeToggle = wake
        controls.addArrangedSubview(recovery); controls.addArrangedSubview(wake)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal); controls.addArrangedSubview(spacer)
        controls.addArrangedSubview(check)
        let controlContent = vertical(5)
        let probeToggle = NSButton(checkboxWithTitle: "云端主动探测（可能消耗额度）", target: self, action: #selector(toggleActiveProbing))
        probeToggle.toolTip = "默认关闭，计费关系未确认。开启后按所选间隔发送一次 ping；自动、手动、命令行及恢复后检查共用持久间隔，失败也开始计时，不自动附加工具检查。关闭阻止新的云端工具请求并暂停自动恢复；已提交请求可能仍计费。本机观察、设备状态与额度同步继续。"
        probeToggle.isEnabled = !previewMode
        panelProbeToggle = probeToggle
        let probeBudget = label(activeProbeStatus.display, size: 12, weight: .semibold)
        let probeInterval = NSPopUpButton()
        probeInterval.addItems(withTitles: ActiveProbeBudget.intervalTitles)
        probeInterval.selectItem(at: ActiveProbeBudget.intervalOptions.firstIndex(of: activeProbeStatus.intervalSeconds) ?? ActiveProbeBudget.defaultIntervalIndex)
        probeInterval.target = self; probeInterval.action = #selector(probeRefreshIntervalChanged(_:))
        probeInterval.isEnabled = !previewMode; probeInterval.menu?.delegate = self
        probeInterval.widthAnchor.constraint(equalToConstant: 112).isActive = true
        panelProbeIntervalPicker = probeInterval
        let probeIntervalRow = NSStackView(views: [probeToggle, NSView(), label("探测频率", size: 12), probeInterval])
        probeIntervalRow.orientation = .horizontal; probeIntervalRow.alignment = .centerY; probeIntervalRow.spacing = 8
        panelProbeBudget = probeBudget
        controlContent.addArrangedSubview(probeIntervalRow)
        controlContent.addArrangedSubview(probeBudget)
        controlContent.addArrangedSubview(controls)
        controls.widthAnchor.constraint(equalTo: controlContent.widthAnchor).isActive = true
        let manualCheckStatus = label("", size: 11, color: .secondaryLabelColor)
        panelManualCheckStatus = manualCheckStatus
        controlContent.addArrangedSubview(manualCheckStatus)
        let recoveryStatus = label("自动恢复：等待检查", size: 12, weight: .semibold)
        panelRecoveryStatus = recoveryStatus
        controlContent.addArrangedSubview(recoveryStatus)
        let wakeStatus = label("保持唤醒：等待检查", size: 12, weight: .semibold)
        panelWakeStatus = wakeStatus
        controlContent.addArrangedSubview(wakeStatus)
        let controlCard = card(controlContent, padding: 12)
        panelControlCard = controlCard

        let nav = NSSegmentedControl(labels: ["概览", "操作记录", "故障与恢复"], trackingMode: .selectOne, target: self, action: #selector(panelPageChanged(_:)))
        nav.selectedSegment = panelPage; nav.segmentStyle = .rounded; nav.heightAnchor.constraint(equalToConstant: 30).isActive = true
        panelNav = nav; layout.addArrangedSubview(nav)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical); scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        panelScroll = scroll; layout.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: layout.widthAnchor, constant: -56).isActive = true
        panelWindow = window
        renderQuota()
        renderPanelPage()
    }
    private func stamp(_ date: Date?) -> String { date.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .medium) } ?? "暂无" }
    private func displayPingResult(_ value: String) -> String { value.replacingOccurrences(of: "ping 成功", with: "命令连接检查成功") }
    private func currentDiagnosis(now: Date = Date()) -> IncidentDiagnosis {
        if let category = channelIncident.activeCategory {
            let action: String
            let evidence: String
            switch category {
            case .cloudRealtimeCapacity:
                action = "Guard 正在退避执行只读复查并等待云端实时服务恢复；本机重启不能修复云端连接池容量问题。"
                evidence = "Commander stderr 命中固定脱敏类别 IncreaseConnectionPool；这里只保存类别和时间，不保存原始响应。"
            case .channelDisruption:
                action = channelIncidentHandling(now: now)
                evidence = "Commander 日志持续出现通道错误、关闭或订阅超时；Guard 只读复查，并仅在明确设备断链达到阈值且安全条件满足时考虑本机恢复。"
            }
            return IncidentDiagnosis(title: category.title,
                                     startedAt: channelIncident.firstSeen,
                                     lastSeenAt: channelIncident.lastSeen,
                                     nextAction: action,
                                     evidence: evidence)
        }
        let base = IncidentDiagnosis.make(timeline: snapshot.timeline, activity: snapshot.activity,
                                          service: snapshot.service, channelState: snapshot.channelState, now: now)
        if channelIncident.recoveredAt != nil,
           ["通道畅通", "通道已恢复"].contains(snapshot.channelState),
           base.title.contains("Commander 连接近期出现异常") {
            return IncidentDiagnosis(title: "当前消息通道已恢复",
                                     startedAt: nil,
                                     lastSeenAt: snapshot.channelChecked,
                                     nextAction: "无需因最近故障记录重复重启；继续观察当前通道和工具执行状态。",
                                     evidence: "当前健康状态与最近故障记录分开保存；故障和恢复时间可在“故障与恢复”中查看。")
        }
        return base
    }
    private func renderPanel() {
        guard panelWindow != nil else { return }
        let now = Date()
        let channelLive = channelSummary(snapshot, now: now)
        if let category = channelIncident.activeCategory {
            panelConnection?.stringValue = category.title
            panelConnection?.textColor = category == .cloudRealtimeCapacity ? .systemOrange : .systemRed
            panelConnectionTime?.stringValue = displayEvidenceTime(lastPingAt)
            panelConnectionDetail?.stringValue = middleTruncate(channelIncidentHandling(now: now), limit: 56)
        } else {
            panelConnection?.stringValue = channelLive
            let marker = channelIndicator(service: snapshot.service, state: snapshot.channelState, checked: snapshot.channelChecked, now: now)
            panelConnection?.textColor = marker == "●" ? .systemGreen : (marker == "!" ? .systemRed : .labelColor)
            panelConnectionTime?.stringValue = displayEvidenceTime(lastPingAt)
            let channelDetail = displayPingResult(manualNotice ?? (manualPingBusy || channelBusy ? deferredReason : snapshot.channelDetail))
            panelConnectionDetail?.stringValue = middleTruncate(channelDetail, limit: 56)
        }

        let toolState = toolExecutionSummary(now: now)
        panelToolExecution?.stringValue = toolState
        panelToolExecution?.textColor = snapshot.toolExecutionState == "失败" ? .systemRed : (toolExecutionFresh(snapshot, now: now) ? .systemGreen : .labelColor)
        panelToolExecutionTime?.stringValue = displayEvidenceTime(snapshot.toolExecutionChecked)
        panelToolExecutionDetail?.stringValue = middleTruncate(snapshot.toolExecutionDetail, limit: 56)

        let chat = chatMonitorSummary(snapshot.timeline)
        panelChat?.stringValue = chatOverviewTitle(chat)
        if panelChat?.stringValue == "回答异常" || panelChat?.stringValue == "连接异常" {
            panelChat?.textColor = .systemOrange
        } else if panelChat?.stringValue == "连接正常" {
            panelChat?.textColor = .systemGreen
        } else {
            panelChat?.textColor = .secondaryLabelColor
        }
        let latestAppAt = snapshot.timeline.latestAppEvent.flatMap { ISO8601DateFormatter.parse($0.sourceAt ?? $0.observedAt) }
        panelChatTime?.stringValue = displayEvidenceTime(latestAppAt)
        panelChatDetail?.stringValue = chatOverviewDetail(chat)


        let probeStatus = activeProbeStatus
        panelProbeToggle?.state = probeStatus.enabled ? .on : .off
        panelProbeBudget?.stringValue = probeStatus.display
        if !probeIntervalMenuOpen { panelProbeIntervalPicker?.selectItem(at: ActiveProbeBudget.intervalOptions.firstIndex(of: probeStatus.intervalSeconds) ?? ActiveProbeBudget.defaultIntervalIndex) }
        panelManualCheck?.isEnabled = !previewMode && probeStatus.blockReason == nil && !manualPingBusy && !channelBusy && !watchdog.recovering
        let manualReason = (previewMode ? "预览中，按钮不会发送请求" : nil)
            ?? probeStatus.blockReason
            ?? (watchdog.recovering ? "自动恢复处理中，暂不能检查" : nil)
            ?? (channelBusy || manualPingBusy ? "已有检查进行中" : nil)
            ?? (snapshot.service != "运行中" ? "Commander 服务未运行" : nil)
            ?? (channelIncident.activeCategory == nil && Date().timeIntervalSince(watchdog.startedAt) < 90 ? "启动等待中，暂不能检查" : nil)
        panelManualCheckStatus?.stringValue = manualReason.map { "暂不可检查：\($0)" } ?? "手动 ping 会占用一次所选检查间隔"
        panelManualCheckStatus?.textColor = manualReason == nil ? .secondaryLabelColor : .systemOrange
        panelRecoveryToggle?.state = recoveryLedger.autoRecoveryEnabled ? .on : .off
        panelWakeToggle?.state = paused ? .off : .on
        let recoveryState = recoveryAvailability()
        let recoveryBlocked = recoveryState.hasPrefix("已暂停") || recoveryState.hasPrefix("云端容量") || recoveryState.contains("暂缓")
        let effectiveRecovery = recoveryState.hasPrefix("已开启 · ") ? String(recoveryState.dropFirst("已开启 · ".count)) : recoveryState
        panelRecoveryStatus?.stringValue = recoveryLedger.autoRecoveryEnabled ? "自动恢复：开 · \(middleTruncate(effectiveRecovery, limit: 78))" : "自动恢复：关"
        panelRecoveryStatus?.font = .systemFont(ofSize: 13, weight: .bold)
        panelRecoveryStatus?.textColor = recoveryBlocked ? .systemOrange : .secondaryLabelColor
        panelWakeStatus?.stringValue = "保持唤醒：\(wakePreventionSummary(enabled: !paused, serviceRunning: snapshot.service == "运行中", assertionActive: assertion != 0))"
        renderPanelPage()
    }
    private func row(_ title: String, _ value: String, color: NSColor = .labelColor) -> NSView {
        let h = NSStackView(); h.orientation = .horizontal; h.alignment = .top; h.spacing = 14
        let key = label(title, size: 12, weight: .medium, color: .secondaryLabelColor)
        key.widthAnchor.constraint(equalToConstant: 128).isActive = true
        let content = label(value, size: 13, color: color)
        if ["首次", "最近", "发生", "恢复", "最近探测"].contains(title) { content.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold) }
        h.addArrangedSubview(key); h.addArrangedSubview(content)
        return h
    }
    private func section(_ title: String, subtitle: String? = nil, rows: [(String, String)]) -> NSView {
        let stack = vertical(11)
        stack.addArrangedSubview(label(title, size: 16, weight: .semibold))
        if let subtitle { stack.addArrangedSubview(label(subtitle, size: 12, color: .secondaryLabelColor)) }
        for (key, value) in rows { let item = row(key, value); stack.addArrangedSubview(item); item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return card(stack)
    }
    private func setSections(_ sections: [NSView]) {
        guard let scroll = panelScroll else { return }
        panelSectionCount = sections.count
        let oldY = scroll.contentView.bounds.origin.y
        let viewport = scroll.contentView.bounds

        let root = TopAlignedPanelDocumentView(frame: NSRect(origin: .zero, size: viewport.size))
        root.autoresizingMask = [.width]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.deactivate(panelSectionWidths)
        panelSectionWidths = []
        for section in sections {
            stack.addArrangedSubview(section)
            let width = section.widthAnchor.constraint(equalTo: stack.widthAnchor)
            width.isActive = true
            panelSectionWidths.append(width)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor)
        ])

        scroll.documentView = root
        root.layoutSubtreeIfNeeded()
        let contentHeight = max(viewport.height, stack.fittingSize.height)
        root.setFrameSize(NSSize(width: viewport.width, height: contentHeight))
        root.layoutSubtreeIfNeeded()

        let maxY = max(0, contentHeight - viewport.height)
        let restoredY = min(max(0, oldY), maxY)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: restoredY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func renderPanelPage() {
        guard panelWindow != nil, !quotaIntervalMenuOpen, !probeIntervalMenuOpen else { return }
        let recordsPage = panelPage == 1
        panelHeading?.isHidden = panelPage != 0
        panelHeroes?.isHidden = false
        panelControlCard?.isHidden = true
        panelConnectionDetail?.isHidden = panelPage != 0
        panelToolExecutionDetail?.isHidden = panelPage != 0
        panelChatDetail?.isHidden = panelPage != 0
        panelHeroMinimum?.constant = 56
        panelScroll?.hasVerticalScroller = !recordsPage
        if recordsPage { renderLogPage(); return }

        if panelPage == 0 {
            panelControlCard?.isHidden = false
            let activity = snapshot.activity
            let diagnosis = currentDiagnosis()
            var activityRows: [(String, String)] = []
            if let active = currentCallStep(activity) {
                activityRows.append(("状态", activityOverviewText(activity)))
                activityRows.append(("操作", active.detail))
                activityRows.append(("已运行", durationText(active.elapsed(at: ProcessInfo.processInfo.systemUptime))))
            } else {
                activityRows.append(("状态", activityOverviewText(activity)))
            }
            if activity.error {
                activityRows.append(("注意", "本机操作日志暂时不可读；Guard 不会据此判断空闲或自动重启"))
            } else if activity.coverageGap {
                activityRows.append(("注意", "本机操作日志存在覆盖缺口；Guard 会保持保守，不自动重启"))
            } else if activity.catchingUp || activity.pendingLine {
                activityRows.append(("注意", "本机操作日志仍在追赶；Guard 暂不判断为空闲"))
            }
            var statusRows = [("当前结论", diagnosis.title), ("下一步", diagnosis.nextAction)]
            if let notice = manualNotice { statusRows.append(("操作提示", displayPingResult(notice))) }
            else if manualPingBusy || channelBusy { statusRows.append(("链路检查", "正在检查消息通道…")) }
            setSections([
                section("当前状态", rows: statusRows),
                panelControlCard!,
                quotaAndTaskSection(activityRows)
            ])
            return
        }

        var datedSections: [(Date, NSView)] = []

        if let recentCategory = channelIncident.recentCategory {
            let result = channelIncident.activeCategory == nil ? "已恢复" : "恢复尚未确认"
            var issueRows: [(String, String)] = [
                ("问题", recentCategory.title),
                ("状态", result),
                ("首次", displayEvidenceTime(channelIncident.firstSeen)),
                ("最近", displayEvidenceTime(channelIncident.lastSeen))
            ]
            if channelIncident.activeCategory == nil {
                issueRows.append(("恢复", displayEvidenceTime(channelIncident.recoveredAt)))
            }
            if let lastPingAt { issueRows.append(("最近探测", "\(displayEvidenceTime(lastPingAt)) · \(displayPingResult(lastPingResult))")) }
            if let lastRecoveryOutcome { issueRows.append(("恢复结果", lastRecoveryOutcome)) }
            datedSections.append((channelIncident.lastSeen ?? channelIncident.firstSeen ?? .distantPast, section("Commander 连接", rows: issueRows)))
        }

        let chat = chatMonitorSummary(snapshot.timeline)
        if let issue = snapshot.timeline.latestAppIssue,
           let issueAt = ISO8601DateFormatter.parse(issue.sourceAt ?? issue.observedAt) {
            let issueName: String
            if issue.event == "chatgpt_completion_transport_recovery_poll_failed" {
                issueName = "回答恢复检查失败"
            } else if issue.event == "chatgpt_completion_transport_recovery_started" {
                issueName = issue.failureKind == "resume_unavailable" ? "恢复流不可用" : "响应恢复尝试"
            } else {
                issueName = "对话状态刷新失败"
            }
            datedSections.append((issueAt, section("ChatGPT 异常", rows: [
                ("问题", issueName),
                ("发生", displayEvidenceTime(issueAt)),
                ("当前情况", chat.history ?? "恢复情况未确认")
            ])))
        }

        if datedSections.isEmpty {
            datedSections.append((.distantPast, section("故障记录", rows: [("状态", "近期未记录到故障")])) )
        }
        setSections(datedSections.sorted { $0.0 > $1.0 }.map(\.1))
    }
    private func renderLogPage() {
        guard let scroll = panelScroll else { return }
        let doc: NSView
        if let document = recordDocument {
            doc = document
        } else {
            let root = NSView(frame: scroll.contentView.bounds)
            root.autoresizingMask = [.width, .height]
            doc = root
            scroll.documentView = doc
            recordDocument = doc

            let title = label("本机操作记录", size: 16, weight: .semibold)
            let hint = label("默认隐藏连接检查；选择记录可查看脱敏后的操作详情。", size: 12, color: .secondaryLabelColor)
            title.translatesAutoresizingMaskIntoConstraints = false
            hint.translatesAutoresizingMaskIntoConstraints = false

            let search = NSSearchField()
            search.placeholderString = "搜索命令、工具、路径或已有会话"
            (search.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = true
            search.target = self
            search.action = #selector(recordSearchChanged(_:))
            search.setContentHuggingPriority(.defaultLow, for: .horizontal)
            recordSearch = search

            let filter = NSPopUpButton()
            filter.addItems(withTitles: ["常规操作", "进行中", "异常与未确认", "全部（含连接检查）"])
            filter.target = self
            filter.action = #selector(recordFilterChanged(_:))
            filter.widthAnchor.constraint(equalToConstant: 180).isActive = true
            recordFilter = filter

            let historicalToggle = NSButton(title: "较早记录（时间不详，0条）", target: self, action: #selector(toggleHistoricalRecords(_:)))
            historicalToggle.bezelStyle = .rounded
            historicalToggle.setContentHuggingPriority(.required, for: .horizontal)
            historicalRecordsToggle = historicalToggle
            let controls = NSStackView(views: [search, filter, historicalToggle])
            controls.orientation = .horizontal
            controls.spacing = 10
            controls.translatesAutoresizingMaskIntoConstraints = false

            let detail = label("选择一条记录查看详情", size: 13)
            detail.isSelectable = true
            recordDetail = detail
            let detailCard = card(detail, padding: 14)
            detailCard.translatesAutoresizingMaskIntoConstraints = false

            let table = NSTableView()
            table.rowHeight = 40
            table.delegate = self
            table.dataSource = self
            table.usesAlternatingRowBackgroundColors = true
            table.style = .plain
            table.intercellSpacing = NSSize(width: 0, height: 4)
            table.columnAutoresizingStyle = .noColumnAutoresizing
            for (name, title, width) in [("time", "时间", CGFloat(104)), ("action", "操作", CGFloat(240)), ("result", "结果", CGFloat(82)), ("duration", "耗时", CGFloat(92)), ("session", "会话", CGFloat(144))] {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
                column.title = title
                column.minWidth = width
                column.width = width
                table.addTableColumn(column)
            }

            let tableScroll = NSScrollView()
            tableScroll.hasVerticalScroller = true
            tableScroll.hasHorizontalScroller = true
            tableScroll.autohidesScrollers = true
            tableScroll.documentView = table
            tableScroll.translatesAutoresizingMaskIntoConstraints = false
            recordTable = table
            recordTableScroll = tableScroll

            [title, hint, controls, detailCard, tableScroll].forEach { root.addSubview($0) }
            NSLayoutConstraint.activate([
                title.topAnchor.constraint(equalTo: root.topAnchor),
                title.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                title.trailingAnchor.constraint(equalTo: root.trailingAnchor),

                hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
                hint.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                hint.trailingAnchor.constraint(equalTo: root.trailingAnchor),

                controls.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
                controls.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                controls.trailingAnchor.constraint(equalTo: root.trailingAnchor),

                detailCard.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
                detailCard.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                detailCard.trailingAnchor.constraint(equalTo: root.trailingAnchor),

                tableScroll.topAnchor.constraint(equalTo: detailCard.bottomAnchor, constant: 12),
                tableScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                tableScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                tableScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ])
        }

        if scroll.documentView !== doc { scroll.documentView = doc }
        doc.frame = scroll.contentView.bounds
        let oldOrigin = scroll.contentView.bounds.origin
        let oldTableOrigin = recordTableScroll?.contentView.bounds.origin ?? .zero
        let query = recordSearch?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let mode = recordFilter?.indexOfSelectedItem ?? 0

        let allSteps = snapshot.activity.steps
        let historicalCount = allSteps.filter(\.historical).count
        historicalRecordsToggle?.title = "\(historicalRecordsExpanded ? "收起" : "较早")记录（时间不详，\(historicalCount)条）"
        historicalRecordsToggle?.isHidden = historicalCount == 0
        recordSteps = allSteps.filter { step in
            let owner = step.sessionAttributionConflict ? "" : (CommanderActivity.sessionDisplay(step.sessionKey) ?? "")
            let text = "\(CommanderActivity.safeToolIdentifier(step.tool)) \(step.detail) \(owner)".lowercased()
            let matchesQuery = query.isEmpty || text.contains(query)
            let matchesMode = mode == 1 ? (!step.finished && !step.failed && !step.uncertain) : (mode == 2 ? (step.failed || step.uncertain) : true)
            let includeHistorical = !step.historical || historicalRecordsExpanded || !query.isEmpty || mode == 3
            return matchesQuery && matchesMode && includeHistorical && (mode == 3 || step.tool != "ping")
        }

        if !recordSteps.contains(where: { $0.id == selectedRecordID }) { selectedRecordID = recordSteps.first?.id }
        recordTable?.reloadData()
        if let selectedRecordID, let index = recordSteps.firstIndex(where: { $0.id == selectedRecordID }) {
            recordTable?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        updateRecordDetail()

        scroll.layoutSubtreeIfNeeded()
        doc.layoutSubtreeIfNeeded()
        if let table = recordTable, let tableScroll = recordTableScroll {
            tableScroll.layoutSubtreeIfNeeded()
            let spacing = table.intercellSpacing.width * CGFloat(max(0, table.tableColumns.count - 1))
            let minimumColumnsWidth = table.tableColumns.reduce(0) { $0 + $1.minWidth }
            let width = max(minimumColumnsWidth + spacing, tableScroll.contentView.bounds.width)
            let extra = max(0, width - spacing - minimumColumnsWidth)
            for (index, column) in table.tableColumns.enumerated() {
                column.width = [CGFloat(104), CGFloat(240) + extra, CGFloat(82), CGFloat(92), CGFloat(144)][index]
            }
            table.setFrameSize(NSSize(width: width, height: max(tableScroll.contentView.bounds.height, CGFloat(recordSteps.count) * table.rowHeight)))
        }

        scroll.contentView.scroll(to: oldOrigin)
        scroll.reflectScrolledClipView(scroll.contentView)
        if let tableScroll = recordTableScroll {
            tableScroll.contentView.scroll(to: oldTableOrigin)
            tableScroll.reflectScrolledClipView(tableScroll.contentView)
        }
    }
    @objc private func recordSearchChanged(_ sender: NSSearchField) { renderLogPage() }
    @objc private func recordFilterChanged(_ sender: NSPopUpButton) { renderLogPage() }
    @objc private func toggleHistoricalRecords(_ sender: NSButton) { historicalRecordsExpanded.toggle(); renderLogPage() }
    func numberOfRows(in tableView: NSTableView) -> Int { recordSteps.count }
    private func recordTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "MM-dd\nHH:mm:ss"
        return formatter.string(from: date)
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let step = recordSteps[row]
        guard let identifier = tableColumn?.identifier.rawValue else { return nil }
        let field = NSTextField(wrappingLabelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: 13)
        field.cell?.truncatesLastVisibleLine = true
        switch identifier {
        case "time":
            field.stringValue = step.historical ? "时间未知" : recordTime(step.startedAt)
            field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            field.textColor = step.historical ? .secondaryLabelColor : .labelColor
        case "action":
            field.stringValue = step.detail
            field.textColor = step.historical ? .secondaryLabelColor : .labelColor
        case "result":
            field.stringValue = step.failed ? "异常" : step.uncertain || step.historical ? "未确认" : step.finished ? "已返回" : "进行中"
            field.textColor = step.failed ? .systemRed : step.uncertain || step.historical ? .secondaryLabelColor : .labelColor
        case "duration":
            field.stringValue = step.historical ? "耗时未知" : step.uncertain ? "未确认" : step.duration.map(durationText) ?? barCallClock(step, uptime: ProcessInfo.processInfo.systemUptime)
            field.textColor = step.historical || step.uncertain ? .secondaryLabelColor : .labelColor
        case "session":
            guard let session = step.sessionAttributionConflict ? nil : CommanderActivity.sessionDisplay(step.sessionKey) else { return field }
            guard let key = step.sessionKey else { return field }
            let bytes = Array(SHA256.hash(data: Data(key.utf8)))
            let container = NSView()
            let badge = NSView()
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 4
            badge.layer?.backgroundColor = NSColor(calibratedRed: CGFloat(bytes[0]) / 510 + 0.5, green: CGFloat(bytes[1]) / 510 + 0.5, blue: CGFloat(bytes[2]) / 510 + 0.5, alpha: 0.18).cgColor
            let text = NSTextField(labelWithString: session)
            let accentColors: [NSColor] = [.systemBlue, .systemPurple, .systemTeal, .systemGreen, .systemIndigo, .systemPink]
            text.stringValue = "● \(session)"
            text.textColor = accentColors[Int(bytes[0]) % accentColors.count]
            text.font = .systemFont(ofSize: 13)
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            badge.addSubview(text)
            container.addSubview(badge)
            badge.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 6), text.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -6), text.centerYAnchor.constraint(equalTo: badge.centerYAnchor)])
            NSLayoutConstraint.activate([badge.leadingAnchor.constraint(equalTo: container.leadingAnchor), badge.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor), badge.centerYAnchor.constraint(equalTo: container.centerYAnchor), badge.heightAnchor.constraint(equalToConstant: 24)])
            return container
        default: return nil
        }
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = recordTable, table.selectedRow >= 0, recordSteps.indices.contains(table.selectedRow) else { return }
        selectedRecordID = recordSteps[table.selectedRow].id; updateRecordDetail()
    }
    private func updateRecordDetail() {
        guard let step = recordSteps.first(where: { $0.id == selectedRecordID }) else {
            let query = recordSearch?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasFoldedHistory = snapshot.activity.steps.contains(where: \.historical) && !historicalRecordsExpanded && query.isEmpty && (recordFilter?.indexOfSelectedItem ?? 0) != 3
            recordDetail?.stringValue = hasFoldedHistory ? "本次启动后暂无新操作；较早记录可展开查看（时间不详）" : "当前筛选下没有匹配记录"
            return
        }
        let time = step.historical ? "时间未知" : prominentStamp(step.startedAt)
        let state = step.failed ? "异常" : step.uncertain ? "未确认" : step.finished ? "已返回" : "进行中"
        let duration = step.historical ? "耗时未知" : step.uncertain ? "耗时未确认" : step.duration.map(durationText) ?? barCallClock(step, uptime: ProcessInfo.processInfo.systemUptime)
        let attribution = step.sessionAttributionConflict ? nil : CommanderActivity.sessionDisplay(step.sessionKey).map { "归属：\($0)（\(step.sessionSource ?? "上游会话字段")）" }
        let source = step.historical ? "来源：历史记录（时间不详）\n" : ""
        let value = "\(time)  ·  \(state)  ·  \(duration)\n工具：\(CommanderActivity.safeToolIdentifier(step.tool))\n\(source)\(attribution.map { $0 + "\n" } ?? "")\(step.detail)"
        if recordDetail?.currentEditor() == nil, recordDetail?.stringValue != value { recordDetail?.stringValue = value }
    }
    private func loadPreviewSnapshot() {
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        quota = UsageQuota(state: .fresh, used: 4200, total: 10000, plan: "free", month: "2026-10", syncedAt: now.addingTimeInterval(-35))
        snapshot.service = "运行中"; snapshot.cloud = "已连接"
        snapshot.channelState = "通道畅通"; snapshot.channelDetail = "最近一次检查通过 · 示例"
        snapshot.channelChecked = now.addingTimeInterval(-38)
        snapshot.toolExecutionState = "已验证"; snapshot.toolExecutionDetail = "复用最近真实工具调用成功记录 · 示例"; snapshot.toolExecutionChecked = now.addingTimeInterval(-26)
        lastPingAt = snapshot.channelChecked; lastPingResult = "ping 成功 · 示例"
        deferredReason = "未延后"
        snapshot.activity.state = "有本机调用进行中"
        snapshot.activity.active = ["执行命令": 1]
        let previewSession = CommanderActivity.sessionAttribution(Data(" metadata: {\"openai/session\":\"preview-session-alpha\"}".utf8))!.key
        snapshot.activity.steps = [
            ActivityStep(id: "preview-1", tool: "read_file", detail: "读取文件 · /Projects/example/README.md", startedAt: now.addingTimeInterval(-95), startedUptime: uptime - 95, duration: 2, finished: true, sessionKey: previewSession, sessionSource: "openai/session"),
            ActivityStep(id: "preview-2", tool: "start_process", detail: "执行命令 · swift test --filter ConnectionTests", startedAt: now.addingTimeInterval(-34), startedUptime: uptime - 34, duration: nil, sessionKey: previewSession, sessionSource: "openai/session"),
            ActivityStep(id: "preview-3", tool: "start_search", detail: "搜索 · rg -n 'connection' Sources", startedAt: now.addingTimeInterval(-240), startedUptime: uptime - 240, duration: 1, finished: true),
            ActivityStep(id: "preview-4", tool: "read_file", detail: "读取文件 · /Projects/example/error.log", startedAt: now.addingTimeInterval(-18), startedUptime: uptime - 18, duration: 0.4, failed: true, finished: true),
            ActivityStep(id: "preview-5", tool: "ping", detail: "连接检查（ping）", startedAt: now.addingTimeInterval(-20), startedUptime: uptime - 20, duration: 0.1, finished: true),
            ActivityStep(id: "preview-6", tool: "read_file", detail: "历史记录 · /Projects/example/archive.log", startedAt: .distantPast, startedUptime: 0, uncertain: true, failed: true, historical: true, finished: true)
        ]
        snapshot.activity.steps[2].sessionAttributionConflict = true
        let makeTime: (TimeInterval) -> String = { ISO8601DateFormatter.flex.string(from: now.addingTimeInterval($0)) }
        let issue = TimelineEvent(source: "chatgpt_app", event: "chatgpt_completion_transport_recovery_started", sourceAt: makeTime(-65), observedAt: makeTime(-64), conversationTitle: "设计讨论", failureKind: "resume_unavailable")
        let app = TimelineEvent(source: "chatgpt_app", event: "chatgpt_conversation_refetch_completed · error", sourceAt: makeTime(-58), observedAt: makeTime(-57), conversationTitle: "功能排查")
        let closed = TimelineEvent(source: "chatgpt_app", event: "chatgpt_pubsub_transport_closed", sourceAt: makeTime(-70), observedAt: makeTime(-69))
        let reopened = TimelineEvent(source: "chatgpt_app", event: "chatgpt_pubsub_transport_opened", sourceAt: makeTime(-30), observedAt: makeTime(-29))
        let idle = TimelineEvent(source: "chatgpt_app", event: "chatgpt_conversation_refetch_completed · idle", sourceAt: makeTime(-20), observedAt: makeTime(-19), conversationTitle: "功能排查")
        snapshot.timeline = TimelineSummary(coverage: "读取正常 · 示例", events: [closed, issue, app, reopened, idle], history: [closed, issue, app, reopened, idle], commanderErrors: 0, latestAppEvent: idle, latestAppIssue: app, conversationLabelsVerifiedAt: makeTime(-3600))
        render()
    }
    private func verifyPanelLayout() {
        func verify(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fputs("CommanderGuard UI check failed: \(message)\n", stderr); exit(2) }
        }
        guard let window = panelWindow, let root = window.contentView, let scroll = panelScroll else { fputs("CommanderGuard UI check failed: panel was not created\n", stderr); exit(2) }
        let savedSnapshot = snapshot, savedRecoveryLedger = recoveryLedger
        let savedWatchdog = watchdog, savedDeferredReason = deferredReason, savedManualNotice = manualNotice
        let savedPendingRecovery = pendingRecoveryVerification, savedVerifiedRestart = verifiedRestart
        let savedIncident = channelIncident
        recoveryLedger = ChannelRecoveryLedger()
        snapshot.activity = ActivitySummary(state: "未观察到新调用", idleProven: true)
        snapshot.channelChecked = Date()
        verify(recoveryAvailability() == "已暂停 · 云端主动探测已关闭", "OFF must pause recovery even with healthy channel evidence")
        snapshot.channelChecked = Date().addingTimeInterval(-3600)
        verify(recoveryAvailability() == "已暂停 · 云端主动探测已关闭", "OFF must pause recovery even with expired channel evidence")
        snapshot.channelChecked = nil; snapshot.channelState = "启动等待中"
        pollChannel()
        verify(snapshot.channelState == "未主动验证" && snapshot.channelDetail.contains("云端主动探测已关闭"), "OFF must not leave an unprobed channel displaying startup wait forever")
        let beforeDeniedPing = lastPingAt, beforeDeniedCheck = snapshot.channelChecked
        recordProbe(.unknown("探测间隔未到"), now: Date(), submitted: false)
        verify(lastPingAt == beforeDeniedPing && snapshot.channelChecked == beforeDeniedCheck, "Denied checks must not create actual ping timestamps")
        let savedRecoveryOutcome = lastRecoveryOutcome
        pendingRecoveryVerification = (100, 101)
        verifyPendingRecovery(now: Date(), currentPID: nil, oldProcessExited: false)
        verify(pendingRecoveryVerification?.new == 101, "Unknown current PID must retain pending verification")
        verifyPendingRecovery(now: Date(), currentPID: 101, oldProcessExited: false)
        verify(pendingRecoveryVerification?.new == 101, "Unconfirmed old process exit must retain verification")
        verifyPendingRecovery(now: Date(), currentPID: 102, oldProcessExited: true)
        verify(pendingRecoveryVerification == nil && lastRecoveryOutcome == savedRecoveryOutcome, "A replaced PID must invalidate without confirming recovery")
        pendingRecoveryVerification = (100, 101)
        verifyPendingRecovery(now: Date(), currentPID: 101, oldProcessExited: true)
        verify(pendingRecoveryVerification == nil && verifiedRestart?.new == 101 && lastRecoveryOutcome?.contains("实际 ping 成功") == true, "Matching exited-old/new-current evidence must confirm recovery")
        verifiedRestart = savedVerifiedRestart; pendingRecoveryVerification = savedPendingRecovery
        lastRecoveryOutcome = savedRecoveryOutcome
        snapshot = savedSnapshot; recoveryLedger = savedRecoveryLedger
        watchdog = savedWatchdog; deferredReason = savedDeferredReason; manualNotice = savedManualNotice
        channelIncident = savedIncident
        render()
        recoveryLedger.autoRecoveryEnabled = true
        renderPanel()
        verify(panelRecoveryStatus?.stringValue.contains("开 · 已暂停") == true && panelRecoveryStatus?.textColor == .systemOrange, "Enabled but blocked auto recovery must show its effective state and reason")
        recoveryLedger = savedRecoveryLedger
        renderPanel()
        verify(middleTruncate("云端实时服务连接池异常", limit: 12).count <= 12, "small-limit middle truncation overflowed")
        verify(middleTruncate("abcdef", limit: 1) == "…", "single-character truncation must stay bounded")
        verify(item.button?.image != nil && item.button?.title.contains("…") == false, "menu bar keeps its icon and avoids clipped-word ellipses")
        for size in [NSSize(width: 940, height: 720), NSSize(width: 760, height: 560)] {
            window.setContentSize(size)
            for page in 0...2 {
                panelPage = page; renderPanel()
                root.layoutSubtreeIfNeeded()
                verify(window.isVisible && scroll.frame.width > 650 && scroll.frame.height > 80, "panel content is clipped at \(Int(size.width))x\(Int(size.height)), page \(page)")
                verify(scroll.documentView != nil, "panel page \(page) is empty")
                verify(panelHeroes?.isHidden == false && panelNav?.isHidden == false, "Status strip and navigation must stay visible on page \(page)")
                if size.width == 940 && page == 1, let table = recordTable, let tableScroll = recordTableScroll {
                    let columnsWidth = table.tableColumns.reduce(0) { $0 + $1.width }
                    let effectiveWidth = columnsWidth + table.intercellSpacing.width * CGFloat(max(0, table.tableColumns.count - 1))
                    verify(table.style == .plain, "Records table must avoid implicit row-end padding")
                    verify(table.frame.width <= tableScroll.contentView.bounds.width + 1 && effectiveWidth <= tableScroll.contentView.bounds.width + 1, "940px records table must fit the viewport including inter-column spacing (table \(Int(table.frame.width)), columns \(Int(effectiveWidth)), viewport \(Int(tableScroll.contentView.bounds.width)))")
                    guard let sessionRow = recordSteps.firstIndex(where: { $0.sessionKey != nil }), let sessionColumn = table.tableColumns.first(where: { $0.identifier.rawValue == "session" }) else { preconditionFailure("Verified session row or column is missing at 940px") }
                    let badge = tableView(table, viewFor: sessionColumn, row: sessionRow)
                    verify((badge?.subviews.first?.subviews.first as? NSTextField)?.stringValue.contains("会话") == true, "940px session column must contain its verified-session badge")
                }
            }
        }
        window.setContentSize(NSSize(width: 940, height: 720))
        panelPage = 0; renderPanel(); root.layoutSubtreeIfNeeded(); scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        verify(panelConnection?.stringValue == "上次探测成功", "Channel headline must stay concise while time and freshness remain separate")
        verify(panelChat?.stringValue == "连接正常" && panelChatDetail?.isHidden == false && panelChatDetail?.stringValue.hasPrefix("原回答是否完整：无法确认") == true, "ChatGPT connection health must not imply answer completeness")
        verify(panelSectionCount == 3, "Overview must show conclusion, guard controls, and a compact quota/task row")
        verify(panelControlCard?.isHidden == false && panelRecoveryToggle?.title == "自动恢复本机 Commander" && panelRecoveryToggle?.toolTip?.contains("不会重试原任务") == true, "Recovery control must explain its local-only action and safeguards")
        verify(panelProbeToggle?.title == "云端主动探测（可能消耗额度）" && panelProbeToggle?.state == .off && panelProbeBudget?.stringValue == activeProbeStatus.display && panelProbeIntervalPicker?.indexOfSelectedItem == ActiveProbeBudget.defaultIntervalIndex && panelProbeIntervalPicker?.numberOfItems == ActiveProbeBudget.intervalOptions.count && panelManualCheck?.isEnabled == false, "Probe switch must default OFF and show the selected cadence")
        verify(panelWakeToggle?.title == "防止闲置睡眠（Guard）" && panelWakeToggle?.toolTip?.contains("其他程序仍可能保持唤醒") == true && panelWakeStatus?.stringValue.contains("保持唤醒：") == true, "Wake control must describe its actual assertion and limits")
        verify(quotaProgress?.isHidden == false && quotaSynced?.isHidden == false && quotaSynced?.stringValue.range(of: #"\d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil && (quotaSynced?.font?.pointSize ?? 0) >= 17, "Quota card must show finite progress and a prominent last-success clock")
        verify(panelHeroes?.isHidden == false && panelConnectionTime?.stringValue.range(of: #"\d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil && (panelConnectionTime?.font?.pointSize ?? 0) >= 14, "Persistent status strip must show a readable evidence time")
        verify(panelManualCheckStatus?.stringValue.contains("暂不可检查") == true, "Disabled manual ping must explain the blocking reason without a tooltip")
        if let menu = quotaIntervalPicker?.menu {
            let savedDocument = panelScroll?.documentView
            menuWillOpen(menu); renderPanelPage()
            verify(quotaIntervalMenuOpen && panelScroll?.documentView === savedDocument, "Live updates must preserve an open quota frequency menu")
            menuDidClose(menu)
            verify(!quotaIntervalMenuOpen, "Closing the frequency menu must resume panel updates")
        }
        if let menu = panelProbeIntervalPicker?.menu {
            let savedDocument = panelScroll?.documentView
            menuWillOpen(menu); renderPanelPage()
            verify(probeIntervalMenuOpen && panelScroll?.documentView === savedDocument, "Live updates must preserve the probe frequency menu")
            menuDidClose(menu)
            verify(!probeIntervalMenuOpen, "Closing the probe frequency menu must resume updates")
        }
        verify(quotaIntervalPicker?.numberOfItems == quotaRefreshOptions.count && quotaIntervalPicker?.indexOfSelectedItem == (quotaRefreshOptions.firstIndex(of: quotaRefreshSeconds) ?? 3), "Quota card must show the configured background sync interval")
        if let overviewRoot = scroll.documentView as? TopAlignedPanelDocumentView,
           let overviewStack = overviewRoot.subviews.first as? NSStackView {
            verify(overviewStack.frame.minY <= 2, "Overview content must start at the top without a blank band")
            if overviewStack.arrangedSubviews.count == 3 {
                let quotaAndTask = overviewStack.arrangedSubviews[2]
                verify(overviewRoot.visibleRect.intersects(quotaAndTask.frame) && quotaAndTask.frame.maxY <= scroll.contentView.bounds.height + 2, "Quota and current task must both fit in the default 940x720 overview")
            } else {
                verify(false, "Overview must keep quota and current task together in the third row")
            }
        } else {
            verify(false, "Overview document must use the top-aligned container")
        }

        let savedNotice = manualNotice
        manualNotice = "启动等待中，暂不能手动检查"; renderPanelPage()
        var pendingViews = [scroll.documentView!], noticeVisible = false
        while let view = pendingViews.popLast() {
            if let field = view as? NSTextField, field.stringValue == manualNotice { noticeVisible = true }
            pendingViews.append(contentsOf: view.subviews)
        }
        verify(noticeVisible, "Manual check deferral and setting errors must be visible on Overview")
        manualNotice = savedNotice

        panelPage = 2; renderPanel(); root.layoutSubtreeIfNeeded(); scroll.layoutSubtreeIfNeeded()
        verify(panelSectionCount <= 3, "Connection status must not become a feature inventory")
        if let connectionRoot = scroll.documentView as? TopAlignedPanelDocumentView,
           let connectionStack = connectionRoot.subviews.first as? NSStackView {
            verify(connectionStack.frame.minY <= 2, "Connection content must start at the top without a blank band")
        } else {
            verify(false, "Connection document must use the top-aligned container")
        }
        verify(panelNav?.label(forSegment: 2) == "故障与恢复", "Third tab must focus on incident history")
        verify(panelControlCard?.isHidden == true && panelHeroes?.isHidden == false && panelNav?.isHidden == false, "Compact status and navigation must persist outside Overview")

        panelPage = 1; renderPanel(); root.layoutSubtreeIfNeeded(); scroll.layoutSubtreeIfNeeded()
        guard let table = recordTable, let tableScroll = recordTableScroll else { fputs("CommanderGuard UI check failed: records are missing\n", stderr); exit(2) }
        verify(tableScroll.frame.width >= scroll.contentView.bounds.width * 0.95, "Operation table must use the available page width (table \(Int(tableScroll.frame.width)), page \(Int(scroll.contentView.bounds.width)))")
        verify(table.tableColumns.reduce(0) { $0 + $1.width } >= tableScroll.contentView.bounds.width * 0.95, "Operation columns must use the available page width")
        verify(table.tableColumns.allSatisfy { $0.width >= $0.minWidth } && table.rowHeight >= 36, "Record columns and rows must preserve readable minimum sizes")
        verify(panelHeroes?.isHidden == false && panelControlCard?.isHidden == true, "Records page must retain the compact status strip and hide repeated controls")
        verify(recordSteps.count == 4 && !recordSteps.contains(where: { $0.tool == "ping" || $0.historical }), "Record page must fold historical records and hide connection checks by default")
        verify(historicalRecordsToggle?.title == "较早记录（时间不详，1条）", "Historical fold must state the unknown time and record count")
        historicalRecordsToggle?.performClick(nil); renderLogPage()
        verify(recordSteps.count == 5 && recordSteps.contains(where: \.historical), "Expanding the historical fold must reveal older rows")
        historicalRecordsToggle?.performClick(nil); renderLogPage()
        recordFilter?.selectItem(at: 3); renderLogPage()
        verify(recordSteps.count == 6 && recordSteps.contains(where: { $0.detail.contains("ping") }) && recordSteps.contains(where: \.historical), "All filter must include connection checks and historical records")
        verify(recordSteps.first(where: \.historical)?.historical == true, "Historical row must remain explicitly marked")
        recordFilter?.selectItem(at: 1); renderLogPage()
        verify(recordSteps.count == 1 && recordSteps[0].id == "preview-2", "Ongoing filter must match only ongoing work")
        recordFilter?.selectItem(at: 2); renderLogPage()
        verify(recordSteps.count == 1 && recordSteps[0].id == "preview-4", "Issue filter must include failed and unconfirmed work")
        recordSearch?.stringValue = "error.log"; renderLogPage()
        verify(recordSteps.count == 1 && recordSteps[0].detail.contains("error.log"), "Search must match sanitized paths")
        recordSearch?.stringValue = "archive.log"; recordFilter?.selectItem(at: 0); renderLogPage()
        verify(recordSteps.count == 1 && recordSteps[0].historical, "Search must reveal matching folded historical records")
        guard let historicalIndex = recordSteps.firstIndex(where: \.historical) else { preconditionFailure("Historical search result is missing") }
        recordTable?.selectRowIndexes(IndexSet(integer: historicalIndex), byExtendingSelection: false)
        verify(recordDetail?.stringValue.contains("时间未知") == true && recordDetail?.stringValue.contains("来源：历史记录（时间不详）") == true && recordDetail?.stringValue.contains("异常") == true, "Historical selection must show honest time, source, and failure")
        recordSearch?.stringValue = "会话"; recordFilter?.selectItem(at: 0); renderLogPage()
        verify(recordSteps.count == 2 && recordSteps.allSatisfy { $0.sessionKey != nil }, "Search must retain known sessions")
        recordSearch?.stringValue = ""; renderLogPage()
        guard let conflictIndex = recordSteps.firstIndex(where: { $0.sessionAttributionConflict }) else { preconditionFailure("Conflicted preview row is missing") }
        recordTable?.selectRowIndexes(IndexSet(integer: conflictIndex), byExtendingSelection: false)
        verify(recordDetail?.stringValue.contains("归属冲突") == false && recordDetail?.stringValue.contains("归属：会话") == false, "Conflicted attribution must not appear as row ownership")
        recordSearch?.stringValue = "归属未确认"; renderLogPage()
        verify(recordSteps.isEmpty, "Unconfirmed ownership must not appear in record search")
        recordSearch?.stringValue = ""; renderLogPage()
        guard let selected = recordSteps.firstIndex(where: { $0.id == "preview-2" }) else { preconditionFailure("Filtered record rows are missing") }
        table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        verify(recordDetail?.stringValue.contains("swift test --filter ConnectionTests") == true && recordDetail?.stringValue.contains("归属：会话 ") == true && recordDetail?.stringValue.contains("归属未确认") == false, "Selecting a row must retain verified attribution without unconfirmed ownership noise")
        let sessionColumn = table.tableColumns.first { $0.identifier.rawValue == "session" }
        let sessionView = sessionColumn.flatMap { tableView(table, viewFor: $0, row: selected) }
        verify((sessionView?.subviews.first?.subviews.first as? NSTextField)?.stringValue.contains("会话") == true, "Verified session must appear as a labeled badge")
        let selectedID = selectedRecordID
        renderPanel()
        verify(selectedRecordID == selectedID && recordDetail?.stringValue.contains("swift test --filter ConnectionTests") == true, "Selected record detail must survive refresh")
        let previewSteps = snapshot.activity.steps
        snapshot.activity.steps = [previewSteps.first(where: \.historical)!]
        recordSearch?.stringValue = ""; recordFilter?.selectItem(at: 0); renderLogPage()
        verify(recordSteps.isEmpty && recordDetail?.stringValue.contains("本次启动后暂无新操作") == true, "An all-historical list must explain why recent rows are folded")
        snapshot.activity.steps = previewSteps; renderLogPage()
        verify(item.button?.image?.isTemplate == true && item.button?.title.contains("通道正常") == true && item.button?.title.contains("DC ") == false, "Menu bar must show an icon and scoped live status; title=\(item.button?.title ?? "nil"), icon=\(item.button?.image?.isTemplate.description ?? "nil"), channel=\(snapshot.channelState)")
        verify(panelHeading?.isHidden == true && panelHeroes?.isHidden == false && panelControlCard?.isHidden == true, "Records page must retain the compact status strip without repeated controls")
        print("CommanderGuard UI check passed")
    }
}

if CommandLine.arguments.contains("--self-test") { selfTest() }
else if CommandLine.arguments.contains("--active-probe-status") {
    let status = ActiveProbeBudget.shared.status()
    print("enabled=\(status.enabled) · \(status.display)")
    exit(status.error == nil ? 0 : 1)
}
else if CommandLine.arguments.contains("--preview-ui") {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate(previewMode: true); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
else if CommandLine.arguments.contains("--probe-headless") {
    do {
        let originalFront = NSWorkspace.shared.frontmostApplication?.processIdentifier
        try HeadlessQuotaBrowser.runHeadlessProbe(chromeExecutable: URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFront else { fputs("Headless probe changed foreground app\n", stderr); exit(2) }
        print("CommanderGuard headless pipe check passed; foreground app unchanged")
        exit(0)
    } catch { fputs("CommanderGuard headless check failed: \(error.localizedDescription)\n", stderr); exit(2) }
}
else if CommandLine.arguments.contains("--probe-channel") {
    let probe = MCPChannelProbe()
    probe.run { result in
        let state: String
        let code: Int32
        switch result { case .healthy: state = "通道畅通"; code = 0; case .noLiveConnection: state = "设备无实时连接"; code = 2; case .unknown: state = "通道状态未知"; code = 1 }
        if let data = try? JSONSerialization.data(withJSONObject: ["channel": state, "submitted": probe.submitted, "checked_at": actualProbeTimestamp(submitted: probe.submitted, at: Date()) as Any? ?? NSNull()], options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
        exit(code)
    }
    dispatchMain()
}
else if CommandLine.arguments.contains("--probe-tool") {
    let probe = MCPToolExecutionProbe()
    probe.run { result in
        let state: String
        let code: Int32
        switch result { case .verified: state = "工具执行已验证"; code = 0; case .failed: state = "工具执行失败"; code = 2; case .unknown: state = "工具执行状态未知"; code = 1 }
        if let data = try? JSONSerialization.data(withJSONObject: ["tool_execution": state, "submitted": probe.submitted, "checked_at": actualProbeTimestamp(submitted: probe.submitted, at: Date()) as Any? ?? NSNull()], options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
        exit(code)
    }
    dispatchMain()
}
else if CommandLine.arguments.contains("--check") {
    Monitor.shared.check { state, seen, error in
        let safe: [String: Any] = ["cloud": state, "last_seen": seen.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "checked_at": ISO8601DateFormatter.flex.string(from: Date()), "message": error ?? ""]
        if let d = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]), let s = String(data: d, encoding: .utf8) { print(s) }
        exit(error == nil ? 0 : 1)
    }
    dispatchMain()
} else {
    let lockFD = open("/tmp/com.wuwendi.commander-guard-\(getuid()).lock", O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    if lockFD < 0 { fputs("CommanderGuard could not acquire its instance lock\n", stderr); exit(1) }
    if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("com.wuwendi.commander-guard.open-panel"), object: nil, userInfo: nil, deliverImmediately: true)
        exit(0)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate(); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
