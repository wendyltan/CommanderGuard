import Cocoa
import IOKit
import IOKit.pwr_mgt
import Foundation
import Darwin
import CoreFoundation
import CryptoKit

struct Snapshot {
    var service = "未知"
    var cloud = "未知"
    var lastSeen: Date?
    var checked = Date()
    var errorCount = 0
    var message = ""
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
    func elapsed(at uptime: TimeInterval) -> TimeInterval? { uncertain ? nil : duration ?? max(0, uptime - startedUptime) }
}

func activityStepRows(_ steps: [ActivityStep], uptime: TimeInterval) -> [String] {
    let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"
    return steps.map { step in
        let symbol = step.uncertain ? "?" : (step.failed ? "!" : (step.duration != nil ? "✓" : "●"))
        let duration = step.uncertain ? "未确认" : (step.duration == nil ? "进行中 \(barCallClock(step, uptime: uptime))" : barCallClock(step, uptime: uptime))
        return "\(clock.string(from: step.startedAt))  \(symbol)  \(step.detail)  · \(duration)"
    }
}

func visibleTimelineEvents(_ events: [TimelineEvent]) -> [TimelineEvent] {
    events.filter { $0.source == "chatgpt_app" || $0.event.hasPrefix("Commander错误:") || $0.event.hasPrefix("调用error:") }
}

struct TimelineEvent: Codable {
    let source: String
    let event: String
    let sourceAt: String?
    let observedAt: String
    let conversationTitle: String?

    init(source: String, event: String, sourceAt: String?, observedAt: String, conversationTitle: String? = nil) {
        self.source = source; self.event = event; self.sourceAt = sourceAt; self.observedAt = observedAt; self.conversationTitle = conversationTitle
    }
}

struct TimelineSummary {
    var coverage = "初次读取中"
    var events: [TimelineEvent] = []
    var history: [TimelineEvent] = []
    var commanderErrors = 0
    var latestAppEvent: TimelineEvent?
    var conversationLabelsVerifiedAt: String?
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
    case "chatgpt_completion_transport_recovery_started": return "\(title) · 响应恢复尝试"
    case "chatgpt_conversation_refetch_started": return "\(title) · 对话状态开始刷新"
    case "chatgpt_conversation_refetch_completed":
        let status = ["streaming": "界面响应中", "error": "界面错误", "idle": "界面空闲"][parts.count > 1 ? parts[1] : ""] ?? "状态未确认"
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

    var summary: TimelineSummary { TimelineSummary(coverage: coverage, events: Array(events.suffix(12)), history: Array(events.suffix(500)), commanderErrors: commanderErrors, latestAppEvent: latestAppEvent, conversationLabelsVerifiedAt: conversationLabels.verifiedAt) }

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
        else if !coverageGap { coverage = "已覆盖当前日志 · Commander 调用归属未确认" }
        initialPollComplete = true
        saveIfNeeded()
    }

    private func tail(_ url: URL, source: String, now: Date) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attributes[.size] as? UInt64 else { coverageGap = true; coverage = "日志不可读 · 覆盖有缺口"; return }
        let key = url.path
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        var cursor = cursors[key]
        if cursor == nil {
            let offset = size
            if initialPollComplete { coverageGap = true; coverage = "新日志路径 · 覆盖有缺口" }
            cursor = Cursor(offset: offset, inode: inode); cursors[key] = cursor; partial[key] = Data()
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
            else if !dropping { if line.count < maxLine { line.append(byte) } else { dropping = true } }
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
            let errors = [("[DEBUG] Failed to update call result:", "Commander错误: 回传结果写入失败"), ("[DEBUG] Failed to update transport capability:", "Commander错误: 通道能力写入失败"), ("[DEBUG] Failed to mark call executing:", "Commander错误: 调用认领失败"), ("[DEBUG] Doorbell claim attempt failed for ", "Commander错误: 调用认领失败"), ("[DEBUG] Heartbeat update failed:", "Commander错误: 心跳写入失败"), ("Heartbeat failed:", "Commander错误: 心跳失败"), ("[DEBUG] Manual token refresh failed:", "Commander错误: 认证刷新失败"), ("[DEBUG] Manual token refresh threw:", "Commander错误: 认证刷新异常"), ("❌ Channel error:", "Commander错误: 通道错误"), ("⏱️ Channel subscription timed out,", "Commander错误: 通道订阅超时"), ("⚠️ Channel closed —", "Commander错误: 通道关闭"), ("[DEBUG] Tool call handler rejected:", "Commander错误: 调用处理器拒绝"), ("[DEBUG] Tool call handler threw:", "Commander错误: 调用处理器异常"), ("❌ Could not report failure for ", "Commander错误: 失败结果报告失败")]
            if let (_, label) = errors.first(where: { line.hasPrefix($0.0) }) { append(TimelineEvent(source: "commander", event: label, sourceAt: nil, observedAt: ISO8601DateFormatter.flex.string(from: now))) }
            return
        }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = appLine.firstMatch(in: line, range: range), let nameRange = Range(match.range(at: 2), in: line), let dateRange = Range(match.range(at: 1), in: line) else { return }
        let name = String(line[nameRange])
        let allowed = ["chatgpt_pubsub_transport_closed", "chatgpt_pubsub_transport_opened", "chatgpt_pubsub_reconnect_scheduled", "chatgpt_completion_transport_recovery_started", "chatgpt_conversation_refetch_started", "chatgpt_conversation_refetch_completed"]
        guard allowed.contains(name) else { return }
        var label = name
        let rest = Range(match.range(at: 3), in: line).map { String(line[$0]) } ?? ""
        if name == "chatgpt_conversation_refetch_completed" {
            guard let status = rest.split(separator: " ").first(where: { $0.hasPrefix("statusAfter=") }).map({ String($0.dropFirst("statusAfter=".count)) }), ["streaming", "error", "idle"].contains(status) else { return }
            label += " · \(status)"
        }
        let title = ["chatgpt_completion_transport_recovery_started", "chatgpt_conversation_refetch_started", "chatgpt_conversation_refetch_completed"].contains(name) ? conversationLabels.title(in: rest) : nil
        append(TimelineEvent(source: source, event: label, sourceAt: String(line[dateRange]), observedAt: ISO8601DateFormatter.flex.string(from: now), conversationTitle: title))
    }

    private func append(_ event: TimelineEvent) {
        events.append(event)
        if let row = try? JSONEncoder().encode(event), pendingBytes + row.count + 1 <= maxJournal / 2 { pending.append(event); pendingBytes += row.count + 1 }
        else { coverageGap = true; coverage = "时间线有缺口 · 保存队列已满" }
        if event.source == "commander" && (event.event.contains("错误") || event.event.contains("error")) { commanderErrors += 1 }
        if event.source == "chatgpt_app" { latestAppEvent = event }
        if events.count > 5000 { events.removeFirst(events.count - 5000) }
    }

    private func valid(_ event: TimelineEvent) -> Bool {
        guard ISO8601DateFormatter.parse(event.observedAt) != nil else { return false }
        if event.source == "commander" {
            guard event.conversationTitle == nil else { return false }
            if event.event.hasPrefix("Commander错误: ") { return event.sourceAt == nil && Set(["回传结果写入失败", "通道能力写入失败", "调用认领失败", "心跳写入失败", "心跳失败", "认证刷新失败", "认证刷新异常", "通道错误", "通道订阅超时", "通道关闭", "调用处理器拒绝", "调用处理器异常", "失败结果报告失败"]).contains(String(event.event.dropFirst("Commander错误: ".count))) }
            guard event.sourceAt == nil, let colon = event.event.range(of: ": ") else { return false }
            let kind = String(event.event[..<colon.lowerBound]), tool = String(event.event[colon.upperBound...])
            return ["调用receipt", "调用completion", "调用error"].contains(kind) && Set(CommanderActivity.tools.values).contains(tool)
        }
        guard event.source == "chatgpt_app", let stamp = event.sourceAt, ISO8601DateFormatter.parse(stamp) != nil else { return false }
        let parts = event.event.components(separatedBy: " · ")
        let allNames: Set<String> = ["chatgpt_pubsub_transport_closed", "chatgpt_pubsub_transport_opened", "chatgpt_pubsub_reconnect_scheduled", "chatgpt_completion_transport_recovery_started", "chatgpt_conversation_refetch_started", "chatgpt_conversation_refetch_completed"]
        guard let name = parts.first, allNames.contains(name) else { return false }
        let canHaveTitle = ["chatgpt_completion_transport_recovery_started", "chatgpt_conversation_refetch_started", "chatgpt_conversation_refetch_completed"].contains(name)
        guard event.conversationTitle.map(ConversationLabelCatalog.isValidTitle) ?? true,
              canHaveTitle || event.conversationTitle == nil else { return false }
        return name == "chatgpt_conversation_refetch_completed" ? (parts.count == 2 && ["streaming", "error", "idle"].contains(parts[1])) : parts.count == 1
    }

    private func loadJournal() {
        let manager = FileManager.default
        for file in [journal.appendingPathExtension("bak"), journal] {
            guard let size = try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber, size.intValue <= maxJournal, let data = try? Data(contentsOf: file) else { continue }
            for line in data.split(separator: 10).suffix(2500) {
                if let event = try? JSONDecoder().decode(TimelineEvent.self, from: Data(line)), valid(event) { events.append(event); if event.source == "chatgpt_app" { latestAppEvent = event } }
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
    return activity.steps.first { activity.active[$0.tool, default: 0] > 0 && $0.duration == nil }
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
    let uncertain = activity.error || activity.state.contains("调用状态未确认") || activity.state.contains("日志读取异常") || activity.state.contains("状态未知")
    return uncertain ? "状态未确认" : "当前无工具调用"
}

enum CommanderActivity {
    static let tools = ["read_file": "读取文件", "read_multiple_files": "读取文件", "read_process_output": "读取进程输出", "list_sessions": "查看终端会话", "list_processes": "查看进程", "list_directory": "查看目录", "search_files": "搜索文件", "start_search": "开始搜索", "get_more_search_results": "读取搜索结果", "stop_search": "停止搜索", "list_searches": "查看搜索任务", "get_file_info": "查看文件信息", "start_process": "启动进程", "interact_with_process": "操作进程", "kill_process": "结束进程", "force_terminate": "结束进程", "write_file": "写入文件", "edit_block": "编辑文件", "create_directory": "创建目录", "move_file": "移动文件", "get_config": "读取配置"]
    static let uuidPattern = try! NSRegularExpression(pattern: #"^🔧 Received tool call ([0-9a-fA-F-]{36}): ([a-z_]+) "#)
    static let completionPattern = try! NSRegularExpression(pattern: #"^[✅❌] Tool call ([a-z_]+) (completed|failed):"#)

    static func parse(_ bytes: Data) -> (String, String, String, String)? {
        guard let line = String(data: bytes, encoding: .utf8) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        if let m = uuidPattern.firstMatch(in: line, range: range), let idRange = Range(m.range(at: 1), in: line), let toolRange = Range(m.range(at: 2), in: line) {
            let id = String(line[idRange]), tool = String(line[toolRange])
            guard UUID(uuidString: id) != nil, tools[tool] != nil else { return nil }
            guard let separator = line.range(of: ": \(tool) ") else { return nil }
            let args = String(line[separator.upperBound...])
            return (id, tool, "received", detail(tool: tool, args: args))
        }
        if let m = completionPattern.firstMatch(in: line, range: range), let toolRange = Range(m.range(at: 1), in: line), let resultRange = Range(m.range(at: 2), in: line) {
            let tool = String(line[toolRange])
            guard tools[tool] != nil else { return nil }
            return ("", tool, String(line[resultRange]), tools[tool]!)
        }
        return nil
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
        default: return tools[tool] ?? "本机操作"
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

/// Reads only bounded log prefixes. Bootstrap supplies recent labels, never live-running state.
final class ActivityLogReader {
    private let url: URL
    private var offset: UInt64 = 0
    private var fileID: UInt64?
    private var initialized = false
    private var partial = Data()
    private var discarding = false
    private var prefixEvent = ""
    // ponytail: retain the last 256 IDs; long-delayed older replays are outside this bounded cache.
    private var seen = [String]()
    private var active = [String: Int]()
    private var steps = [ActivityStep]()
    private var recent = [String]()
    private var recentIDs = [String]()
    private var lastObserved: Date?
    private var lastTool = ""
    private var observedLive = false
    private var uncertain = false
    private var lastOutcome = "调用状态未确认"
    private(set) var summary = ActivitySummary()
    private let lineLimit = 4 * 1024
    private let ioLimit = 64 * 1024

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RemoteDesktopCommander/stdout.log")) { self.url = url }

    func poll(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? UInt64 else {
            invalidateSteps(); summary.steps = steps; active.removeAll(); summary.active.removeAll(); observedLive = false; uncertain = true; lastOutcome = "调用状态未确认"; summary.error = true; summary.state = "日志不可读 / 状态未知"; return
        }
        let id = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        if !initialized || id != fileID || size < offset {
            let wasInitialized = initialized
            offset = size; fileID = id; initialized = true; partial.removeAll(); discarding = false; prefixEvent = ""
            if wasInitialized { invalidateSteps() }; active.removeAll(); seen.removeAll(); recent.removeAll(); recentIDs.removeAll(); lastObserved = nil; lastTool = ""; observedLive = false; uncertain = wasInitialized; lastOutcome = "调用状态未确认"
            let start = size > 64 * 1024 ? size - 64 * 1024 : 0
            if let handle = try? FileHandle(forReadingFrom: url) {
                try? handle.seek(toOffset: start)
                var tail = (try? handle.read(upToCount: Int(size - start))) ?? Data()
                try? handle.close()
                if start > 0 {
                    if let newline = tail.firstIndex(of: 10) { tail.removeSubrange(...newline) }
                    else { tail.removeAll(); discarding = true }
                }
                consume(tail, live: false, now: now, uptime: uptime)
            }
            summary = ActivitySummary(state: recent.isEmpty && !uncertain ? "未观察到新调用" : "调用状态未确认", tool: lastTool, observed: lastObserved, recent: recent, steps: steps, active: [:], error: false)
            return
        }
        if size == offset { if summary.error { summary.error = false; summary.state = "调用状态未确认（日志读取中断）" }; return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { invalidateSteps(); summary.steps = steps; active.removeAll(); summary.active.removeAll(); observedLive = false; uncertain = true; lastOutcome = "调用状态未确认"; summary.error = true; summary.state = "日志读取异常 / 状态未知"; return }
        if size - offset > UInt64(ioLimit) {
            // ponytail: skip excess backlog in bounded time; a gap makes outstanding state unknown.
            offset = size - UInt64(min(ioLimit, Int(size)))
            try? handle.seek(toOffset: offset)
            invalidateSteps(); active.removeAll(); partial.removeAll(); discarding = false; prefixEvent = ""
            observedLive = false; uncertain = true; lastOutcome = "调用状态未确认"; lastObserved = nil
            var tail = (try? handle.read(upToCount: Int(size - offset))) ?? Data()
            try? handle.close(); offset = size
            if let newline = tail.firstIndex(of: 10) { tail.removeSubrange(...newline) }
            else { tail.removeAll(); discarding = true }
            consume(tail, live: false, now: now, uptime: uptime)
            summary = ActivitySummary(state: "调用状态未确认（日志有间隔）", tool: lastTool, observed: lastObserved, recent: recent, steps: steps, active: [:], error: false)
            return
        }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(min(UInt64(ioLimit), size - offset))) else {
            try? handle.close(); invalidateSteps(); summary.steps = steps; active.removeAll(); summary.active.removeAll(); observedLive = false; uncertain = true; lastOutcome = "调用状态未确认"; summary.error = true; summary.state = "日志读取异常 / 状态未知"; return
        }
        try? handle.close(); offset += UInt64(data.count)
        if !data.isEmpty { consume(data, live: true, now: now, uptime: uptime) }
        summary.error = false
        summary.active = active
        summary.recent = recent
        summary.steps = steps
        summary.observed = lastObserved
        summary.observedUptime = lastObserved == nil ? nil : summary.observedUptime
        summary.state = !observedLive ? (uncertain || !recent.isEmpty ? "调用状态未确认" : "未观察到新调用") : (active.isEmpty ? lastOutcome : "收到调用（处理中）")
    }

    private func consume(_ data: Data, live: Bool, now: Date, uptime: TimeInterval) {
        for byte in data {
            if byte == 10 {
                if !discarding { emit(partial, live: live, now: now, uptime: uptime) }
                partial.removeAll(keepingCapacity: true); discarding = false; prefixEvent = ""
            } else if !discarding {
                if partial.count < lineLimit { partial.append(byte) }
                else {
                    discarding = true
                    emit(partial, live: live, now: now, uptime: uptime)
                }
            }
        }
        if live && !discarding && !partial.isEmpty { emit(partial, live: true, now: now, uptime: uptime) }
    }

    private func emit(_ bytes: Data, live: Bool, now: Date, uptime: TimeInterval) {
        if let text = String(data: bytes, encoding: .utf8),
           text.hasPrefix("🚀 Starting MCP Device") || text.hasPrefix("🛑 Shutting down device") {
            let key = text.hasPrefix("🚀") ? "service-start" : "service-stop"
            guard key != prefixEvent else { return }; prefixEvent = key
            if live { active.removeAll(); observedLive = false; uncertain = true; lastOutcome = "调用状态未确认"; lastObserved = nil; summary.active.removeAll(); summary.state = "调用状态未确认" }
            if live { invalidateSteps(); summary.steps = steps }
            return
        }
        guard let event = CommanderActivity.parse(bytes) else { return }
        let key = "\(event.0)|\(event.1)|\(event.2)|\(event.3)"
        guard key != prefixEvent else { return }
        prefixEvent = key
        handle(event, live: live, now: now, uptime: uptime)
    }

    private func handle(_ event: (String, String, String, String), live: Bool, now: Date, uptime: TimeInterval) {
        let (id, tool, result, detail) = event
        if result == "received" {
            if seen.contains(id) {
                if live && summary.latestReceivedID == id {
                    lastTool = detail; summary.tool = detail
                    if let i = steps.firstIndex(where: { $0.id == id && $0.duration == nil && !$0.uncertain }) { steps[i].detail = detail }
                    summary.steps = steps
                }
                return
            }
            lastTool = detail
            summary.tool = detail
            seen.append(id); if seen.count > 256 { seen.removeFirst() }
            let recentLabel = "收到：\(detail)"
            if recent.first != recentLabel { recent.insert(recentLabel, at: 0); recentIDs.insert(id, at: 0) }
            else if !recentIDs.isEmpty { recentIDs[0] = id }
            recent = Array(recent.prefix(3)); recentIDs = Array(recentIDs.prefix(3))
            if live { observedLive = true; uncertain = false; lastOutcome = "收到调用（处理中）"; summary.returnedStepID = nil; active[tool, default: 0] += 1; summary.tool = detail; summary.observed = now; summary.observedUptime = uptime; summary.latestReceivedID = id; lastObserved = now }
            if live { steps.insert(ActivityStep(id: id, tool: tool, detail: detail, startedAt: now, startedUptime: uptime), at: 0); steps = Array(steps.prefix(100)); summary.steps = steps }
        } else {
            if live {
                observedLive = true; uncertain = false; lastOutcome = result == "completed" ? "本机已返回（云端结果未知）" : "本机异常（云端结果未知）"; summary.returnedStepID = nil; lastObserved = now; summary.observedUptime = uptime
                let candidates = steps.indices.filter { steps[$0].tool == tool && steps[$0].duration == nil && !steps[$0].uncertain }
                if candidates.count == 1 && active[tool] == 1 { let i = candidates[0]; steps[i].duration = max(0, uptime - steps[i].startedUptime); steps[i].failed = result == "failed"; if result == "completed" { summary.returnedStepID = steps[i].id } }
                else { for i in candidates { steps[i].uncertain = true } }
                if let count = active[tool], count > 0 { if count == 1 { active.removeValue(forKey: tool) } else { active[tool] = count - 1 } }
                summary.steps = steps
            }
        }
    }

    private func invalidateSteps() { for i in steps.indices where steps[i].duration == nil { steps[i].uncertain = true } }
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

func selfTest() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let fresh = now.addingTimeInterval(-300)
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
    var completed = pending; completed.duration = 2
    precondition(barCallClock(completed, uptime: 99) == "2 秒")
    precondition(activityStepRows([pending], uptime: 13)[0].contains("●  读取文件  · 进行中 3 秒"))
    precondition(activityStepRows([completed], uptime: 99)[0].contains("✓  读取文件  · 2 秒"))
    var failedStep = completed; failedStep.failed = true
    precondition(activityStepRows([failedStep], uptime: 99)[0].contains("!  读取文件  · 2 秒"))
    var uncertainStep = failedStep; uncertainStep.uncertain = true
    precondition(activityStepRows([uncertainStep], uptime: 99)[0].contains("?  读取文件  · 未确认"))
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
    precondition(callState(ActivitySummary(state: "本机已返回（云端结果未知）")) == "当前无工具调用")
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
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): read_file_extra {".utf8)) == nil)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = dir.appendingPathComponent("stdout.log")
    FileManager.default.createFile(atPath: log.path, contents: Data())
    let reader = ActivityLogReader(url: log)
    reader.poll(); precondition(reader.summary.state == "未观察到新调用")
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
    precondition(reader.summary.steps.first?.startedAt == uniqueStart && reader.summary.steps.first?.duration == 3 && callState(reader.summary) == "当前无工具调用")
    let capLog = dir.appendingPathComponent("cap.log")
    FileManager.default.createFile(atPath: capLog.path, contents: Data())
    let capReader = ActivityLogReader(url: capLog); capReader.poll()
    func appendCap(_ s: String) { let f = try! FileHandle(forWritingTo: capLog); try! f.seekToEnd(); try! f.write(contentsOf: Data(s.utf8)); try! f.close() }
    for index in 0...100 {
        appendCap("🔧 Received tool call 00000000-0000-4000-8000-\(String(format: "%012d", index)): read_file {}\n")
    }
    capReader.poll(now: now, uptime: 30)
    appendCap("✅ Tool call read_file completed: uncorrelated completion\n")
    capReader.poll(now: now.addingTimeInterval(1), uptime: 31)
    precondition(capReader.summary.steps.count == 100 && capReader.summary.active["read_file"] == 100 && capReader.summary.steps.first?.id == "00000000-0000-4000-8000-000000000100" && capReader.summary.steps.first?.uncertain == true && capReader.summary.steps.first?.duration == nil)
    let returnLog = dir.appendingPathComponent("return.log")
    FileManager.default.createFile(atPath: returnLog.path, contents: Data())
    let returnReader = ActivityLogReader(url: returnLog); returnReader.poll()
    func appendReturn(_ s: String) { let f = try! FileHandle(forWritingTo: returnLog); try! f.seekToEnd(); try! f.write(contentsOf: Data(s.utf8)); try! f.close() }
    appendReturn("🔧 Received tool call a23e4567-e89b-12d3-a456-426614174000: list_directory {}\n✅ Tool call list_directory completed: result\n")
    returnReader.poll(now: now, uptime: 40)
    precondition(recentlyReturnedCall(returnReader.summary, uptime: 40)?.id == "a23e4567-e89b-12d3-a456-426614174000")
    precondition(recentlyReturnedCall(returnReader.summary, uptime: 43) == nil)
    appendReturn("🔧 Received tool call b23e4567-e89b-12d3-a456-426614174000: list_directory {}\n✅ Tool call list_directory completed: result\n✅ Tool call list_sessions completed: unmatched\n")
    returnReader.poll(now: now.addingTimeInterval(1), uptime: 41)
    precondition(returnReader.summary.active.isEmpty && returnReader.summary.state == "本机已返回（云端结果未知）" && returnReader.summary.returnedStepID == nil && recentlyReturnedCall(returnReader.summary, uptime: 41) == nil)
    append("🔧 Received tool call 323e4567-e89b-12d3-a456-426614174000: read_file {" + String(repeating: "x", count: 30_000))
    reader.poll(); precondition(reader.summary.active["read_file"] == 1)
    append(String(repeating: "z", count: 300_000))
    reader.poll(); precondition(reader.summary.active.isEmpty && reader.summary.state.contains("未确认"))
    append("🚀 Starting MCP Device...\n🔧 Received tool call 523e4567-e89b-12d3-a456-426614174000: read_file {live}\n")
    reader.poll(); precondition(reader.summary.active["read_file"] == 1)
    append("🛑 Shutting down device...\n")
    reader.poll(); precondition(reader.summary.active.isEmpty && reader.summary.state.contains("未确认"))
    // Truncation clears inferred activity and never calls an old start live.
    try! Data("✅ Tool call read_file completed: old\n".utf8).write(to: log)
    reader.poll(); precondition(reader.summary.active.isEmpty && reader.summary.state == "调用状态未确认")
    let oldLog = dir.appendingPathComponent("old.log")
    try! FileManager.default.moveItem(at: log, to: oldLog)
    FileManager.default.createFile(atPath: log.path, contents: Data("🔧 Received tool call 423e4567-e89b-12d3-a456-426614174000: read_file {old start}\n".utf8))
    reader.poll(); precondition(reader.summary.active.isEmpty && reader.summary.state == "调用状态未确认")
    let bootstrap = ActivityLogReader(url: log); bootstrap.poll()
    precondition(bootstrap.summary.active.isEmpty && bootstrap.summary.state == "调用状态未确认" && bootstrap.summary.steps.isEmpty)
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
    precondition(timeline.summary.events.isEmpty && timeline.summary.coverage.contains("Commander 调用归属未确认")) // Startup tail is never relabeled as live.
    let appHandle = try! FileHandle(forWritingTo: appLog); try! appHandle.seekToEnd()
    try! appHandle.write(contentsOf: Data("\(sourceStamp) warning [electron-message-handler] chatgpt_pubsub_transport_closed private body=DO_NOT_STORE\n".utf8))
    try! appHandle.write(contentsOf: Data("transcript chatgpt_pubsub_transport_opened\n".utf8))
    try! appHandle.write(contentsOf: Data("\(sourceStamp) warning [electron-message-handler] chatgpt_conversation_refetch_completed statusAfter=private_token\n".utf8))
    try! appHandle.write(contentsOf: Data("\(sourceStamp) error [electron-message-handler] chatgpt_completion_transport_recovery_started partial".utf8)); try! appHandle.close()
    timeline.poll(now: now.addingTimeInterval(1)); precondition(timeline.summary.events.count == 1 && timeline.summary.events[0].event == "chatgpt_pubsub_transport_closed")
    let appHandle2 = try! FileHandle(forWritingTo: appLog); try! appHandle2.seekToEnd()
    try! appHandle2.write(contentsOf: Data("\n\(sourceStamp) info [electron-message-handler] chatgpt_pubsub_transport_opened\n\(sourceStamp) info [electron-message-handler] chatgpt_pubsub_reconnect_scheduled\n".utf8)); try! appHandle2.close()
    timeline.poll(now: now.addingTimeInterval(2)); timeline.poll(now: now.addingTimeInterval(3))
    precondition(timeline.summary.events.suffix(3).map(\.event) == ["chatgpt_completion_transport_recovery_started", "chatgpt_pubsub_transport_opened", "chatgpt_pubsub_reconnect_scheduled"])
    precondition(timeline.summary.events.last?.sourceAt == sourceStamp)
    let labeledLog = day.appendingPathComponent("labeled.log")
    FileManager.default.createFile(atPath: labeledLog.path, contents: Data())
    let labeledJournal = dir.appendingPathComponent("labeled.jsonl")
    let labeledTimeline = TimelineReader(appRoot: appRoot, commanderLog: dir.appendingPathComponent("no-commander.log"), commanderErrorLog: nil, journal: labeledJournal, conversationLabelsURL: labelCatalogURL)
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
    let longPrefix = "\(sourceStamp) info [electron-message-handler] chatgpt_pubsub_transport_closed "
    let longHandle = try! FileHandle(forWritingTo: appLog); try! longHandle.seekToEnd(); try! longHandle.write(contentsOf: Data((longPrefix + String(repeating: "x", count: 9000) + " DO_NOT_KEEP\n").utf8)); try! longHandle.close()
    timeline.poll(now: now.addingTimeInterval(3.5)); precondition(timeline.summary.latestAppEvent?.event == "chatgpt_pubsub_transport_closed")
    let savedTimeline = String(data: try! Data(contentsOf: journal), encoding: .utf8)!
    precondition(!savedTimeline.contains("DO_NOT_STORE") && !savedTimeline.contains("private body") && !savedTimeline.contains("conversationId"))
    let restored = TimelineReader(appRoot: appRoot, commanderLog: dir.appendingPathComponent("stdout.log"), commanderErrorLog: nil, journal: journal, conversationLabelsURL: labelCatalogURL)
    precondition(restored.summary.events.count >= 3)
    let movedAppLog = dir.appendingPathComponent("rotated-app.log"); try! FileManager.default.moveItem(at: appLog, to: movedAppLog)
    try! Data("historical event\n".utf8).write(to: appLog); timeline.poll(now: now.addingTimeInterval(4))
    precondition(timeline.summary.coverage.contains("轮换") && timeline.summary.events.count == 5)
    try! Data("small\n".utf8).write(to: appLog); timeline.poll(now: now.addingTimeInterval(4)); precondition(timeline.summary.coverage.contains("截断"))
    let missingTimeline = TimelineReader(appRoot: dir.appendingPathComponent("missing"), commanderLog: dir.appendingPathComponent("missing.log"), commanderErrorLog: nil, journal: dir.appendingPathComponent("missing.jsonl"))
    missingTimeline.poll(); precondition(missingTimeline.summary.coverage.contains("缺失"))
    let liveCommander = dir.appendingPathComponent("live-stdout.log"); try! Data("historical\n".utf8).write(to: liveCommander)
    let commanderErrorLog = dir.appendingPathComponent("live-stderr.log"); try! Data("historic error\n".utf8).write(to: commanderErrorLog)
    let commanderTimeline = TimelineReader(appRoot: dir.appendingPathComponent("empty"), commanderLog: liveCommander, commanderErrorLog: commanderErrorLog, journal: dir.appendingPathComponent("commander.jsonl")); commanderTimeline.poll()
    let cf = try! FileHandle(forWritingTo: liveCommander); try! cf.seekToEnd(); try! cf.write(contentsOf: Data("🔧 Received tool call \(safeID): read_file {secret argument}\n✅ Tool call read_file completed: private result\n".utf8)); try! cf.close()
    let ef = try! FileHandle(forWritingTo: commanderErrorLog); try! ef.seekToEnd(); try! ef.write(contentsOf: Data("[DEBUG] Heartbeat update failed: secret details\n".utf8)); try! ef.close()
    commanderTimeline.poll(now: now); commanderTimeline.poll(now: now.addingTimeInterval(1))
    let longCommanderLine = "🔧 Received tool call 123e4567-e89b-12d3-a456-426614174001: read_file {\"padding\":\"" + String(repeating: "敏", count: 5000) + "\"}\n"
    let longCommanderFile = try! FileHandle(forWritingTo: liveCommander); try! longCommanderFile.seekToEnd(); try! longCommanderFile.write(contentsOf: Data(longCommanderLine.utf8)); try! longCommanderFile.close()
    commanderTimeline.poll(now: now.addingTimeInterval(2))
    precondition(commanderTimeline.summary.events.count == 4 && commanderTimeline.summary.events[0].source == "commander" && commanderTimeline.summary.commanderErrors == 1)
    let commanderJSON = String(data: try! Data(contentsOf: dir.appendingPathComponent("commander.jsonl")), encoding: .utf8)!
    precondition(!commanderJSON.contains("secret argument") && !commanderJSON.contains("private result") && !commanderJSON.contains(safeID) && !commanderJSON.contains("敏"))
    let boundedRoot = dir.appendingPathComponent("bounded-app", isDirectory: true)
    let boundedDay = boundedRoot.appendingPathComponent("2026/10/01", isDirectory: true)
    try! FileManager.default.createDirectory(at: boundedDay, withIntermediateDirectories: true)
    let boundedAppLog = boundedDay.appendingPathComponent("app.log"); FileManager.default.createFile(atPath: boundedAppLog.path, contents: Data())
    let boundedJournal = dir.appendingPathComponent("bounded-timeline.jsonl")
    let boundedTimeline = TimelineReader(appRoot: boundedRoot, commanderLog: dir.appendingPathComponent("no-commander.log"), commanderErrorLog: nil, journal: boundedJournal)
    boundedTimeline.poll(now: now)
    let manyEvents = String(repeating: "2026-10-01T03:33:01.055Z warning [electron-message-handler] chatgpt_pubsub_transport_closed\n", count: 18000)
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
        print("CommanderGuard self-test passed")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private var assertion: IOPMAssertionID = 0
    private var paused = false
    private var snapshot = Snapshot()
    private var summaryLines: [NSMenuItem] = []
    private var guardItem: NSMenuItem!
    private var logWindow: NSWindow?
    private var logTextView: NSTextView?
    private var logDetailsButton: NSButton?
    private var showingLogDetails = false
    private let activityReader = ActivityLogReader()
    private let timelineReader = TimelineReader()
    private var activityBusy = false
    private var activityTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Commander 守护"
        rebuild()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in self.poll() }
        activityTimer = Timer(timeInterval: 1, repeats: true) { _ in self.pollActivity() }
        RunLoop.main.add(activityTimer!, forMode: .common)
        pollActivity()
    }
    func applicationWillTerminate(_ n: Notification) { timer?.invalidate(); activityTimer?.invalidate(); releaseAssertion() }
    private func rebuild() {
        let m = NSMenu()
        ["连接：未知", "动作：未观察到新调用"].forEach { let x = NSMenuItem(title: $0, action: nil, keyEquivalent: ""); x.isEnabled = false; m.addItem(x); summaryLines.append(x) }
        let recent = NSMenuItem(title: "执行日志…", action: #selector(openLogWindow), keyEquivalent: ""); recent.target = self; m.addItem(recent)
        guardItem = NSMenuItem(title: "暂停防休眠（仅影响本机睡眠）", action: #selector(togglePause), keyEquivalent: ""); guardItem.target = self; m.addItem(guardItem)
        m.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); quit.target = NSApplication.shared; m.addItem(quit)
        item.menu = m
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
    private func pollActivity() {
        guard !activityBusy else { return }
        activityBusy = true
        DispatchQueue.global(qos: .utility).async {
            self.activityReader.poll()
            self.timelineReader.poll()
            let value = self.activityReader.summary
            let timeline = self.timelineReader.summary
            DispatchQueue.main.async { self.snapshot.activity = value; self.snapshot.timeline = timeline; self.activityBusy = false; self.render() }
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
        guardItem.title = paused ? "恢复防休眠（重新阻止本机睡眠）" : "暂停防休眠（仅影响本机睡眠）"
    }
    private func releaseAssertion() { if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 } }
    private func render() {
        guard summaryLines.count == 2 else { return }
        let latestAppEvent = snapshot.timeline.latestAppEvent.map { event in
            let time = ISO8601DateFormatter.parse(event.observedAt).map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "时间未知"
            return "\(appEventLabel(event)) · \(time)"
        } ?? "未观察到新事件"
        let activity = snapshot.activity
        let clockText: (Date) -> String = { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) }
        let connection = snapshot.service == "运行中" ? "●" : (snapshot.service == "未运行" ? "!" : "?")
        let connectionText = "Commander 服务\(snapshot.service == "运行中" ? "运行中" : (snapshot.service == "未运行" ? "未运行" : "状态未知"))"
        summaryLines[0].title = "状态：\(connectionText)"
        let uptime = ProcessInfo.processInfo.systemUptime
        if let step = currentCallStep(activity) {
            let elapsed = durationText(step.elapsed(at: ProcessInfo.processInfo.systemUptime))
            let timing = step.uncertain ? "耗时未确认" : "等待返回 \(elapsed)"
            summaryLines[1].title = "动作：\(middleTruncate(CommanderActivity.menuDetail(step.detail), limit: 80)) · \(clockText(step.startedAt)) · \(timing)"
        } else if let step = recentlyReturnedCall(activity, uptime: uptime) {
            summaryLines[1].title = "动作：\(middleTruncate(CommanderActivity.menuDetail(step.detail), limit: 80)) · 调用耗时 \(durationText(step.duration))"
        } else {
            summaryLines[1].title = "动作：\(callState(activity))"
        }
        let activeStep = currentCallStep(activity)
        let callStatus = callState(activity)
        let barTimer = activeStep.map { barCallClock($0, uptime: uptime) } ?? ""
        let returnedStep = activeStep == nil ? recentlyReturnedCall(activity, uptime: uptime) : nil
        let barAction = activeStep.map(\.detail) ?? returnedStep.map(\.detail) ?? callStatus
        let barDuration = returnedStep.map { durationText($0.duration) }
        let shortAction = middleTruncate(CommanderActivity.menuDetail(barAction), limit: 40)
        item.button?.title = "DC \(connection)\(barTimer.isEmpty ? (barDuration.map { " \($0)" } ?? "") : " \(barTimer)") · \(shortAction)"
        let origin = "最近一次本机观察；\(conversationLabelNote(snapshot.timeline.conversationLabelsVerifiedAt)) 无新事件不表示空闲或完成。"
        let age = activity.observed.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "未知"
        item.button?.toolTip = "\(connectionText)\n\(returnedStep == nil ? "" : "本机调用已返回 · ")\(barAction)\(barDuration.map { " · 调用耗时 \($0)" } ?? "") · \(callStatus) · \(age)\n\(origin)"
        writeStatus()
        if logWindow?.isVisible == true { renderLogWindow(latestAppEvent: latestAppEvent) }
    }
    private func durationText(_ value: TimeInterval?) -> String {
        guard let value else { return "未确认" }
        return value < 1 ? "<1 秒" : "\(Int(value)) 秒"
    }
    private func middleTruncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let prefix = String(value.prefix(12)), suffix = String(value.suffix(limit - prefix.count - 1))
        return "\(prefix)…\(suffix)"
    }
    private func writeStatus() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CommanderGuard", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { fputs("CommanderGuard: unable to create status directory\n", stderr); return }
        let rows = activityStepRows(snapshot.activity.steps, uptime: ProcessInfo.processInfo.systemUptime)
        let safeSteps: [[String: Any]] = snapshot.activity.steps.map { step in ["tool": step.tool, "detail": step.detail, "started_at": ISO8601DateFormatter.flex.string(from: step.startedAt), "elapsed_seconds": step.elapsed(at: ProcessInfo.processInfo.systemUptime) as Any? ?? NSNull(), "duration_seconds": step.duration as Any? ?? NSNull(), "uncertain": step.uncertain, "failed": step.failed] }
        let latestStep = currentCallStep(snapshot.activity)
        let callElapsed = latestStep?.elapsed(at: ProcessInfo.processInfo.systemUptime)
        let currentState = callState(snapshot.activity)
        let timelineRows: [[String: Any]] = snapshot.timeline.events.map { ["source": $0.source, "event": $0.event, "conversation_title": $0.conversationTitle as Any? ?? NSNull(), "source_timestamp": $0.sourceAt as Any? ?? NSNull(), "observed_at": $0.observedAt] }
        let lastAppEvent: [String: Any] = snapshot.timeline.latestAppEvent.map { ["event": $0.event, "conversation_title": $0.conversationTitle as Any? ?? NSNull(), "source_timestamp": $0.sourceAt as Any? ?? NSNull(), "observed_at": $0.observedAt] } ?? [:]
        let object: [String: Any] = ["service": snapshot.service, "cloud": snapshot.cloud, "last_seen": snapshot.lastSeen.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "checked_at": ISO8601DateFormatter.flex.string(from: snapshot.checked), "error_count": snapshot.errorCount, "paused": paused, "idle_prevention": assertion != 0, "message": snapshot.message, "menu": ["menubar_title": item.button?.title ?? "", "connection": summaryLines.first?.title ?? "", "action": summaryLines.count > 1 ? summaryLines[1].title : "", "execution_step_rows": rows, "execution_steps": safeSteps, "tool_call_elapsed_seconds": callElapsed as Any? ?? NSNull(), "tool_call_state": currentState, "recent_actions": snapshot.activity.recent], "activity": ["state": snapshot.activity.state, "tool": snapshot.activity.tool, "active_count": snapshot.activity.activeCount, "observed_at": snapshot.activity.observed.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "recent": snapshot.activity.recent, "error": snapshot.activity.error], "timeline": ["coverage": snapshot.timeline.coverage, "commander_errors_this_run": snapshot.timeline.commanderErrors, "conversation_labels_verified_at": snapshot.timeline.conversationLabelsVerifiedAt as Any? ?? NSNull(), "last_chatgpt_app_event": lastAppEvent, "events": timelineRows]]
        guard let d = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        do { try d.write(to: dir.appendingPathComponent("status.json"), options: .atomic) }
        catch { fputs("CommanderGuard: unable to write sanitized status file\n", stderr) }
    }
    @objc private func togglePause() { paused.toggle(); updateGuard(); render() }
    @objc private func openLogWindow() {
        if logWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "CommanderGuard · 操作记录"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 600, height: 400)
            window.center()
            let bounds = window.contentView!.bounds
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 40, width: bounds.width, height: bounds.height - 40)); scroll.hasVerticalScroller = true; scroll.autoresizingMask = [.width, .height]
            let text = NSTextView(frame: scroll.contentView.bounds); text.isEditable = false; text.isSelectable = true; text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 13, weight: .regular); text.textContainerInset = NSSize(width: 12, height: 12); text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            let details = NSButton(title: "故障详情…", target: self, action: #selector(toggleLogDetails)); details.frame = NSRect(x: 12, y: 8, width: 120, height: 24); details.autoresizingMask = [.maxYMargin]; details.bezelStyle = .rounded
            scroll.documentView = text; window.contentView?.addSubview(scroll); window.contentView?.addSubview(details); logWindow = window; logTextView = text; logDetailsButton = details
        }
        renderLogWindow(latestAppEvent: snapshot.timeline.latestAppEvent.map { event in
            let time = ISO8601DateFormatter.parse(event.observedAt).map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "时间未知"
            return "\(appEventLabel(event)) · \(time)"
        } ?? "未观察到新事件")
        logWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func toggleLogDetails() {
        showingLogDetails.toggle()
        logDetailsButton?.title = showingLogDetails ? "收起故障详情" : "故障详情…"
        if let text = logTextView { text.setSelectedRange(NSRange(location: text.selectedRange().location, length: 0)) }
        let latest = snapshot.timeline.latestAppEvent.map { event in
            let time = ISO8601DateFormatter.parse(event.observedAt).map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "时间未知"
            return "\(appEventLabel(event)) · \(time)"
        } ?? "未观察到新事件"
        renderLogWindow(latestAppEvent: latest)
    }
    private func renderLogWindow(latestAppEvent: String) {
        guard let window = logWindow, let text = logTextView else { return }
        let clip = text.enclosingScrollView?.contentView
        let oldOrigin = clip?.bounds.origin ?? .zero
        let activity = snapshot.activity
        let uptime = ProcessInfo.processInfo.systemUptime
        let steps = activityStepRows(activity.steps, uptime: uptime)
        let history = visibleTimelineEvents(snapshot.timeline.history).reversed().map { event -> String in
            let time = ISO8601DateFormatter.parse(event.observedAt).map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "时间未知"
            let source = event.source == "chatgpt_app" ? "App" : "Commander"
            let label = event.source == "chatgpt_app" ? appEventLabel(event) : commanderEventLabel(event.event).replacingOccurrences(of: "Commander错误：", with: "")
            return "\(time)  \(source)  \(label)"
        }
        var content = "最近本机工具调用（最多 100 条；时间为本机观察时间）\n● 进行中  ✓ 调用结束  ! 本机异常  ? 未确认\n\(steps.isEmpty ? "暂无操作记录" : steps.joined(separator: "\n"))"
        if showingLogDetails {
            content += "\n\n连接与异常（最近 \(history.count) 条，新事件在前）\n\(history.isEmpty ? "暂无连接或异常记录" : history.joined(separator: "\n"))\n\nCommander：\(snapshot.service) · 云端登记：\(snapshot.cloud) · 错误 \(snapshot.errorCount)\nApp 最近事件：\(latestAppEvent) · 覆盖：\(snapshot.timeline.coverage)\n\(conversationLabelNote(snapshot.timeline.conversationLabelsVerifiedAt)) · Commander 新观测错误：\(snapshot.timeline.commanderErrors) 条"
        }
        window.title = "CommanderGuard · 操作记录"
        guard text.string != content else { return }
        let selection = text.selectedRange()
        if selection.length > 0 { return }
        let wasEmpty = text.string.isEmpty
        text.string = content
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
        text.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: (content as NSString).length))
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let length = (content as NSString).length
        let location = min(selection.location, length)
        text.setSelectedRange(NSRange(location: location, length: 0))
        if wasEmpty, let clip { clip.scroll(to: .zero); text.enclosingScrollView?.reflectScrolledClipView(clip) }
        else if let clip { clip.scroll(to: oldOrigin); text.enclosingScrollView?.reflectScrolledClipView(clip) }
    }
    private func commanderEventLabel(_ event: String) -> String {
        guard let separator = event.range(of: ": ") else { return event }
        let kind = String(event[..<separator.lowerBound]), tool = String(event[separator.upperBound...])
        let label = ["调用receipt": "收到调用", "调用completion": "本机返回", "调用error": "本机调用异常"][kind] ?? kind
        return "\(label)：\(tool)"
    }
}

if CommandLine.arguments.contains("--self-test") { selfTest() }
else if CommandLine.arguments.contains("--check") {
    Monitor.shared.check { state, seen, error in
        let safe: [String: Any] = ["cloud": state, "last_seen": seen.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "checked_at": ISO8601DateFormatter.flex.string(from: Date()), "message": error ?? ""]
        if let d = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]), let s = String(data: d, encoding: .utf8) { print(s) }
        exit(error == nil ? 0 : 1)
    }
    dispatchMain()
} else {
    let lockFD = open("/tmp/com.wuwendi.commander-guard-\(getuid()).lock", O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 { fputs("CommanderGuard is already running\n", stderr); exit(0) }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate(); app.delegate = delegate
    app.run()
}
