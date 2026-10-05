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
    var channelState = "启动宽限"
    var channelDetail = "等待 Commander 与日志完成启动"
    var channelFailures = 0
    var channelChecked: Date?
    var toolExecutionState = "未验证"
    var toolExecutionDetail = "尚未检查本机工具执行"
    var toolExecutionChecked: Date?
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
    func elapsed(at uptime: TimeInterval) -> TimeInterval? { uncertain || historical ? nil : duration ?? max(0, uptime - startedUptime) }
}

func activityStepRows(_ steps: [ActivityStep], uptime: TimeInterval) -> [String] {
    let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"
    return steps.map { step in
        let symbol = step.historical && step.finished ? (step.failed ? "!" : "✓") : (step.uncertain ? "?" : (step.failed ? "!" : (step.finished || step.duration != nil ? "✓" : "●")))
        let duration = step.historical ? (step.finished ? "已返回 · 耗时未知" : "开始时间未知 · 状态未确认") : (step.uncertain ? "未确认" : (step.duration == nil ? "进行中 \(barCallClock(step, uptime: uptime))" : barCallClock(step, uptime: uptime)))
        return "\(step.historical ? "时间未知" : clock.string(from: step.startedAt))  \(symbol)  \(step.detail)  · \(duration)"
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

struct NetworkGuardianStatus {
    let updatedAt: Date?
    let healthy: Bool?
    let proxyAvailable: Bool?
    let tunnelState: String
    let manualPause: Bool?
    let newLogFailures: Double?
    let recentFailureScore: Double?

    static func read(_ url: URL, now: Date) -> NetworkGuardianStatus {
        func unknown() -> NetworkGuardianStatus { NetworkGuardianStatus(updatedAt: nil, healthy: nil, proxyAvailable: nil, tunnelState: "unknown", manualPause: nil, newLogFailures: nil, recentFailureScore: nil) }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 64 * 1024,
              let data = try? Data(contentsOf: url), data.count <= 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawDate = object["updated_at"] as? String,
              rawDate.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression) != nil,
              let updatedAt = ISO8601DateFormatter.parse(rawDate), now.timeIntervalSince(updatedAt) >= 0,
              now.timeIntervalSince(updatedAt) <= 120,
              let healthyNumber = object["healthy"] as? NSNumber, CFGetTypeID(healthyNumber) == CFBooleanGetTypeID(),
              let proxyNumber = object["proxy_available"] as? NSNumber, CFGetTypeID(proxyNumber) == CFBooleanGetTypeID(),
              let healthy = object["healthy"] as? Bool, let proxyAvailable = object["proxy_available"] as? Bool,
              let tunnel = object["tunnel_state"] as? String,
              ["running", "down", "unknown"].contains(tunnel) else { return unknown() }
        let manualNumber = object["manual_pause"] as? NSNumber
        let manualPause = manualNumber.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? object["manual_pause"] as? Bool : nil }
        func bounded(_ key: String) -> Double? {
            guard let value = object[key] as? NSNumber else { return nil }
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let number = value.doubleValue
            return number.isFinite && (0...1_000_000).contains(number) ? number : nil
        }
        guard object["manual_pause"] == nil || manualPause != nil,
              ["new_log_failures", "recent_failure_score"].allSatisfy({ object[$0] == nil || bounded($0) != nil }) else { return unknown() }
        return NetworkGuardianStatus(updatedAt: updatedAt, healthy: healthy, proxyAvailable: proxyAvailable,
                                     tunnelState: tunnel, manualPause: manualPause,
                                     newLogFailures: bounded("new_log_failures"), recentFailureScore: bounded("recent_failure_score"))
    }

    var safeSummary: String {
        guard let updatedAt else { return "网络守护状态未知（文件缺失、格式无效或超过 120 秒）" }
        let health = healthy.map { $0 ? "网页探测正常（不验证持久连接）" : "网页探测失败" } ?? "网页探测未知"
        let proxy = proxyAvailable.map { $0 ? "可用" : "不可用" } ?? "未知"
        let pause = manualPause == true ? " · 手动暂停" : ""
        let failures = newLogFailures.map { " · 新日志失败 \(String(format: "%.4g", $0))" } ?? ""
        let score = recentFailureScore.map { " · 近期失败分数 \(String(format: "%.4g", $0))" } ?? ""
        let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"
        let tunnel = ["running": "运行中", "down": "未运行", "unknown": "未知"][tunnelState] ?? "未知"
        return "\(health) · 代理\(proxy) · 隧道\(tunnel)\(pause)\(failures)\(score) · 更新 \(clock.string(from: updatedAt))"
    }
}

struct IncidentDiagnosis {
    let title: String
    let startedAt: Date?
    let lastSeenAt: Date?
    let nextAction: String
    let evidence: String
    let network: NetworkGuardianStatus

    static func make(timeline: TimelineSummary, activity: ActivitySummary, network: NetworkGuardianStatus, service: String = "未知", channelState: String = "未知", now: Date) -> IncidentDiagnosis {
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
        let appIssue = answerIssues.filter { now.timeIntervalSince($0.1) <= 900 }.max { $0.1 < $1.1 }
        let oldAnswerIssue = answerIssues.max { $0.1 < $1.1 }
        let appDisruption = appDisruptions.max { $0.1 < $1.1 }
        let commanderConnectivity = recent.filter { $0.0.source == "commander" && ["Commander错误: 通道错误", "Commander错误: 通道订阅超时", "Commander错误: 通道关闭"].contains($0.0.event) }
        let commanderIssue = recent.filter { $0.0.source == "commander" && ($0.0.event.hasPrefix("Commander错误:") || $0.0.event.hasPrefix("调用error:")) }.max { $0.1 < $1.1 }
        let appAt = appDisruption?.1
        let guardianBad = network.healthy == false || network.proxyAvailable == false || network.tunnelState == "down" || (network.newLogFailures ?? 0) > 0 || (network.recentFailureScore ?? 0) > 0
        let matchedCommander = appAt.flatMap { appDate in commanderConnectivity.filter { abs($0.1.timeIntervalSince(appDate)) <= 10 }.min { abs($0.1.timeIntervalSince(appDate)) < abs($1.1.timeIntervalSince(appDate)) } }
        let shared = appAt != nil && matchedCommander != nil
        let unknownActivity = activity.error || activity.coverageGap || activity.catchingUp || !activity.idleProven || activity.state.contains("未确认") || activity.state.contains("未知")
        let busyActivity = activity.activeCount > 0
        let coverageUnknown = ["缺失", "不可读", "缺口", "读取失败", "截断", "轮换", "队列已满", "追赶中", "初次读取"].contains { timeline.coverage.contains($0) }
        let reopened = latestOpen.map { open in appAt.map { open > $0 } ?? false } ?? false
        let serviceIssue = service == "未运行" || ["通道异常", "通道不可用", "恢复尚未确认"].contains(channelState)
        let networkIssue = network.updatedAt != nil && guardianBad
        let title: String
        let action: String
        let evidence: String
        var relevantDates: [Date] = []
        var lastObservedOverride: Date?
        if serviceIssue {
            title = service == "未运行" ? "Commander 服务当前未运行" : "Commander 命令通道检查异常"
            action = "查看本机服务与操作记录；确认调用状态后再决定下一步。"
            evidence = "ping 只检查本机命令通道响应；未验证实际工具执行或 ChatGPT 回答。"
        } else if shared {
            title = "App 与 Commander 连接近期同时异常"
            action = "检查网络连接；回到原对话核对回答，再决定是否继续。"
            evidence = "Commander 使用本机观察时间；时间接近提示可能共享连接问题，但不证明根因或会话归属。"
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
        } else if networkIssue {
            title = "网络守护近期报告网络异常"
            action = "检查网络守护当前状态与网络连接；此状态不说明 ChatGPT 回答结果。"
            evidence = "网页探测失败或隧道状态只是选定的本机状态；不证明 ChatGPT 持久连接根因。"
            lastObservedOverride = network.updatedAt
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
        return IncidentDiagnosis(title: title, startedAt: relevantDates.min(), lastSeenAt: lastObservedOverride ?? relevantDates.max(), nextAction: action, evidence: evidence, network: network)
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
    let deliveryLimit = "Message delivery timed out 没有可读的专属结构化事件；响应恢复尝试只是前兆，不代表该提示已出现"

    var menuLine: String { "ChatGPT：" + (answer.components(separatedBy: "；").first ?? answer) }
}

func chatMonitorSummary(events: [ChatMonitorEvidence], timelineCoverage: String) -> ChatMonitorSummary {
    let unreadable = ["不可读", "缺口", "缺失", "读取失败", "轮换或截断", "新日志路径", "队列已满", "追赶中", "初次读取"].contains { timelineCoverage.contains($0) }
    let stamp: (String) -> String = { raw in
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { return "时间未知" }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    let answerEvents = events.filter {
        $0.kind == "chatgpt_completion_transport_recovery_started" || $0.kind == "chatgpt_completion_transport_recovery_poll_failed" ||
        ($0.kind == "chatgpt_conversation_refetch_completed" && $0.outcome == "error")
    }
    let answer: String
    if let latest = answerEvents.max(by: { $0.observedAt < $1.observedAt || ($0.observedAt == $1.observedAt && $0.failureKind == nil && $1.failureKind != nil) }) {
        let type = latest.kind == "chatgpt_completion_transport_recovery_poll_failed" ? "回答恢复检查失败" : latest.kind == "chatgpt_completion_transport_recovery_started" ? (latest.failureKind == "resume_unavailable" ? "恢复流不可用" : "响应流恢复尝试") : "对话状态刷新失败"
        answer = "最近异常：\(type) · \(stamp(latest.observedAt))；恢复情况未确认"
    } else if unreadable {
        answer = "日志不可读或有缺口；回答状态未知"
    } else {
        answer = "尚未观察到可识别的回答异常"
    }

    let connectionEvents = events.filter {
        ["chatgpt_pubsub_reconnect_exhausted", "chatgpt_pubsub_connection_failed", "chatgpt_pubsub_transport_closed", "chatgpt_pubsub_reconnect_scheduled", "chatgpt_pubsub_transport_opened"].contains($0.kind)
    }
    let connection: String
    if let latest = connectionEvents.max(by: { $0.observedAt < $1.observedAt }) {
        let detail: String
        switch latest.kind {
        case "chatgpt_pubsub_reconnect_exhausted": detail = "更新连接重连已耗尽"
        case "chatgpt_pubsub_connection_failed": detail = "更新连接失败"
        case "chatgpt_pubsub_transport_closed": detail = "更新连接已关闭"
        case "chatgpt_pubsub_reconnect_scheduled": detail = "更新连接准备重连"
        default: detail = "更新连接已建立"
        }
        let next = latest.kind == "chatgpt_pubsub_transport_opened" ? "仍需单独确认回答是否恢复" : "检查 ChatGPT 网络连接；恢复后确认原回答状态"
        connection = "\(detail) · \(stamp(latest.observedAt))；\(next)"
    } else if unreadable {
        connection = "连接状态未知（日志不可读或有缺口）"
    } else {
        connection = "暂无连接异常事件；连接事件缺失不代表回答成功"
    }
    return ChatMonitorSummary(answer: answer, connection: connection)
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
        if event.source == "chatgpt_app" { latestAppEvent = event }
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
            if event.event.hasPrefix("Commander错误: ") { return event.sourceAt == nil && Set(["回传结果写入失败", "通道能力写入失败", "调用认领失败", "心跳写入失败", "心跳失败", "认证刷新失败", "认证刷新异常", "通道错误", "通道订阅超时", "通道关闭", "调用处理器拒绝", "调用处理器异常", "失败结果报告失败"]).contains(String(event.event.dropFirst("Commander错误: ".count))) }
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
                if let event = try? JSONDecoder().decode(TimelineEvent.self, from: Data(line)), valid(event) { events.append(event); if event.source == "chatgpt_app" { latestAppEvent = event }; rememberAppIssue(event) }
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

func recoveryConfirmed(oldPID: Int32, newPID: Int32?, probe: ChannelProbeResult) -> Bool {
    guard let newPID, newPID != oldPID else { return false }
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
        if channelIndicator(service: snapshot.service, state: snapshot.channelState, checked: snapshot.channelChecked, now: now) != "●" { return "待复查（上次通道探测成功）" }
        return "通道可回应"
    }
    return ["启动宽限": "启动等待中", "通道异常": "异常", "通道不可用": "不可用", "通道状态未知": "未确认", "正在恢复通道": "正在恢复", "恢复尚未确认": "恢复尚未确认"][snapshot.channelState] ?? snapshot.channelState
}

enum CommanderActivity {
    static let tools = ["read_file": "读取文件", "read_multiple_files": "读取文件", "read_process_output": "读取进程输出", "list_sessions": "查看终端会话", "list_processes": "查看进程", "list_directory": "查看目录", "search_files": "搜索文件", "start_search": "开始搜索", "get_more_search_results": "读取搜索结果", "stop_search": "停止搜索", "list_searches": "查看搜索任务", "get_file_info": "查看文件信息", "start_process": "启动进程", "interact_with_process": "操作进程", "kill_process": "结束进程", "force_terminate": "结束进程", "write_file": "写入文件", "edit_block": "编辑文件", "create_directory": "创建目录", "move_file": "移动文件", "get_config": "读取配置"]
    static let uuidPattern = try! NSRegularExpression(pattern: #"^🔧 Received tool call ([0-9a-fA-F-]{36}): ([A-Za-z0-9_-]+) "#)
    static let completionPattern = try! NSRegularExpression(pattern: #"^[✅❌] Tool call ([A-Za-z0-9_-]+) (completed|failed):"#)

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
            return ("", tool, String(line[resultRange]), tools[tool] ?? "本机工具调用")
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
        default: return tools[tool] ?? "本机工具调用"
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
            partial.removeAll(); discarding = false; prefixEvent = ""
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
        partial.removeAll(); discarding = false; prefixEvent = ""
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
                if !discarding { emit(partial, live: live, complete: true, now: now, uptime: uptime) }
                partial.removeAll(keepingCapacity: true); discarding = false; prefixEvent = ""
            } else if !discarding {
                if partial.count < lineLimit { partial.append(byte) }
                else {
                    if live,
                       (partial.starts(with: Data("🔧 Received tool call ".utf8)) || partial.starts(with: Data("✅ Tool call ".utf8)) || partial.starts(with: Data("❌ Tool call ".utf8))),
                       CommanderActivity.parse(partial, partial: true) == nil { markGap("调用事件前缀超过读取上限", now: now) }
                    discarding = true
                    emit(partial, live: live, complete: false, now: now, uptime: uptime)
                }
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

struct ChannelWatchdogState {
    let startedAt: Date
    var lastProbe = Date.distantPast
    var failures = 0
    var status = "启动宽限"
    var detail = "等待 Commander 与日志完成启动"
    var recovering = false

    func isDue(now: Date) -> Bool { now.timeIntervalSince(startedAt) >= 90 && now.timeIntervalSince(lastProbe) >= 30 && !recovering }
    mutating func observed(_ result: ChannelProbeResult, now: Date) {
        switch result {
        case .healthy: failures = 0; status = "通道畅通"; detail = "MCP ping 已往返"
        case .noLiveConnection: failures += 1; status = failures >= 3 ? "通道不可用" : "通道异常"; detail = "连续明确失败 \(failures)/3"
        case .unknown(let reason): failures = 0; status = "通道状态未知"; detail = reason
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

    func run(_ done: @escaping (ChannelProbeResult) -> Void) {
        completion = done
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
        session.dataTask(with: request).resume()
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

    func run(_ done: @escaping (ToolExecutionProbeResult) -> Void) {
        completion = done
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
        session.dataTask(with: request).resume()
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

func selfTest() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
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
    var watchdogTest = ChannelWatchdogState(startedAt: now)
    precondition(!watchdogTest.isDue(now: now.addingTimeInterval(89)) && watchdogTest.isDue(now: now.addingTimeInterval(90)))
    watchdogTest.lastProbe = now.addingTimeInterval(90)
    precondition(!watchdogTest.isDue(now: now.addingTimeInterval(119)) && watchdogTest.isDue(now: now.addingTimeInterval(120)))
    for n in 1...3 { watchdogTest.observed(.noLiveConnection, now: now.addingTimeInterval(Double(90 + n * 30))); precondition(watchdogTest.failures == n) }
    watchdogTest.observed(.unknown("网络未知"), now: now.addingTimeInterval(200)); precondition(watchdogTest.failures == 0)
    watchdogTest.observed(.healthy, now: now.addingTimeInterval(230)); precondition(watchdogTest.status == "通道畅通")
    for _ in 0..<5 { watchdogTest.observedManual(.noLiveConnection, now: now); precondition(watchdogTest.failures == 0 && watchdogTest.status == "通道异常") }
    watchdogTest.observed(.noLiveConnection, now: now); precondition(watchdogTest.failures == 1)
    watchdogTest.observedManual(.healthy, now: now); precondition(watchdogTest.failures == 0 && watchdogTest.status == "通道畅通")
    var ledgerTest = ChannelRecoveryLedger(); ledgerTest.recordAttempt(at: now)
    precondition(!ledgerTest.canAttempt(at: now.addingTimeInterval(299)) && ledgerTest.canAttempt(at: now.addingTimeInterval(300)))
    precondition(!recoveryConfirmed(oldPID: 100, newPID: nil, probe: .healthy))
    precondition(!recoveryConfirmed(oldPID: 100, newPID: 100, probe: .healthy))
    precondition(!recoveryConfirmed(oldPID: 100, newPID: 101, probe: .unknown("未知")))
    precondition(recoveryConfirmed(oldPID: 100, newPID: 101, probe: .healthy))
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
    var displaySnapshot = Snapshot(service: "运行中", channelState: "通道畅通", channelChecked: now)
    precondition(channelSummary(displaySnapshot, now: now) == "通道可回应")
    precondition(channelSummary(displaySnapshot, now: now.addingTimeInterval(76)) == "待复查（上次通道探测成功）")
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
    precondition(CommanderActivity.parse(Data("🔧 Received tool call \(safeID): read_file_extra {".utf8))?.3 == "本机工具调用")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let ledgerFile = dir.appendingPathComponent("recovery.json")
    precondition(ledgerTest.save(to: ledgerFile))
    precondition(!ChannelRecoveryLedger.load(from: ledgerFile).canAttempt(at: now.addingTimeInterval(299)))
    try! Data("invalid".utf8).write(to: ledgerFile)
    precondition(!ChannelRecoveryLedger.load(from: ledgerFile).autoRecoveryEnabled)
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
    let chatResult = chatMonitorSummary(TimelineSummary(coverage: "已覆盖当前日志", history: [issue, laterOpen, laterIdle]))
    precondition(chatResult.answer.contains("恢复流不可用") && chatResult.connection.contains("更新连接已建立") && !chatResult.answer.contains("回答已恢复"))
    precondition(chatResult.answer.contains("恢复情况未确认"))
    precondition(appEventLabel(TimelineEvent(source: "chatgpt_app", event: "chatgpt_conversation_refetch_completed · error", sourceAt: issueTime, observedAt: issueTime)).contains("对话状态刷新失败"))
    let repeated = TimelineEvent(source: "chatgpt_app", event: "chatgpt_pubsub_transport_opened", sourceAt: "2026-10-04T11:41:00.100Z", observedAt: "2026-10-04T11:41:00.100Z")
    let repeated2 = TimelineEvent(source: "chatgpt_app", event: "chatgpt_pubsub_transport_opened", sourceAt: "2026-10-04T11:41:00.800Z", observedAt: "2026-10-04T11:41:00.800Z")
    let separate = TimelineEvent(source: "chatgpt_app", event: "chatgpt_pubsub_transport_opened", sourceAt: "2026-10-04T11:41:03.000Z", observedAt: "2026-10-04T11:41:03.000Z")
    let grouped = groupedTimelineEvents([repeated, repeated2, separate])
    precondition(grouped.count == 2 && grouped[0].1 == 2 && grouped[1].1 == 1)
    precondition(groupedTimelineEvents([issue, TimelineEvent(source: issue.source, event: issue.event, sourceAt: issue.sourceAt, observedAt: issue.observedAt)]).count == 2, "Different failure classifications must remain separate")
    precondition(chatResult.menuLine.count < 100 && chatResult.deliveryLimit.contains("没有可读"))
    precondition(chatMonitorSummary(TimelineSummary(coverage: "App 日志缺失")).answer.contains("未知"))
    precondition(chatMonitorSummary(TimelineSummary(coverage: "已覆盖当前日志")).answer.contains("尚未观察到"))
    let retainedIssue = chatMonitorSummary(TimelineSummary(coverage: "已覆盖当前日志", history: [laterOpen, laterIdle], latestAppIssue: issue))
    precondition(retainedIssue.answer.contains("恢复流不可用"))
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
    precondition(chatMonitorSummary(chatReader.summary).answer.contains("恢复检查失败"))
    precondition(chatMonitorSummary(chatReader.summary).connection.contains("重连已耗尽"))
    let recoveredEvent = chatReader.summary.history.first { $0.event == extraEvents[0] }!
    precondition(appEventLabel(recoveredEvent).contains("恢复完成"))
    precondition(chatMonitorSummary(TimelineSummary(coverage: "已覆盖当前日志", history: [issue, recoveredEvent])).answer.contains("恢复情况未确认"))
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
    let incidentURL = dir.appendingPathComponent("guardian-status.json")
    let offsetFormatter = DateFormatter(); offsetFormatter.locale = Locale(identifier: "en_US_POSIX"); offsetFormatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600); offsetFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    let offsetStamp = offsetFormatter.string(from: now.addingTimeInterval(-50))
    func writeGuardian(_ values: [String: Any]) { try! JSONSerialization.data(withJSONObject: values).write(to: incidentURL) }
    let goodGuardian: [String: Any] = ["updated_at": offsetStamp, "healthy": true, "proxy_available": true, "tunnel_state": "running", "manual_pause": false, "new_log_failures": 0, "recent_failure_score": 0]
    writeGuardian(goodGuardian)
    let guardianGood = NetworkGuardianStatus.read(incidentURL, now: now)
    precondition(guardianGood.updatedAt != nil && guardianGood.healthy == true)
    precondition(NetworkGuardianStatus.read(dir.appendingPathComponent("missing-status.json"), now: now).updatedAt == nil)
    writeGuardian(["updated_at": ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-121)), "healthy": true, "proxy_available": true, "tunnel_state": "running"])
    precondition(NetworkGuardianStatus.read(incidentURL, now: now).updatedAt == nil, "Stale network status must be unknown")
    writeGuardian(["updated_at": "2026-10-05T11:05:14", "healthy": true, "proxy_available": true, "tunnel_state": "running"])
    precondition(NetworkGuardianStatus.read(incidentURL, now: now).updatedAt == nil, "A timezone-less timestamp must be rejected")
    writeGuardian(goodGuardian.merging(["healthy": 1]) { _, new in new })
    precondition(NetworkGuardianStatus.read(incidentURL, now: now).updatedAt == nil, "Malformed selected status must be unknown")
    writeGuardian(goodGuardian.merging(["updated_at": ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(1))]) { _, new in new })
    precondition(NetworkGuardianStatus.read(incidentURL, now: now).updatedAt == nil, "Future status must not be treated as current")
    let safeIdle = ActivitySummary(state: "未观察到新调用", idleProven: true)
    let eventTime = ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-50))
    let appClose = TimelineEvent(source: "chatgpt_app", event: "chatgpt_pubsub_transport_closed", sourceAt: eventTime, observedAt: eventTime)
    let commanderChannel = TimelineEvent(source: "commander", event: "Commander错误: 通道错误", sourceAt: nil, observedAt: ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-45)))
    var badGuardianJSON = goodGuardian
    badGuardianJSON["healthy"] = false; badGuardianJSON["proxy_available"] = false; badGuardianJSON["tunnel_state"] = "down"
    badGuardianJSON["updated_at"] = ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-48))
    writeGuardian(badGuardianJSON)
    let guardianBad = NetworkGuardianStatus.read(incidentURL, now: now)
    let joint = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志", history: [appClose, commanderChannel]), activity: safeIdle, network: guardianBad, service: "运行中", channelState: "通道畅通", now: now)
    precondition(joint.title.contains("同时异常") && joint.evidence.contains("不证明"), "Near-time cross-service evidence must remain tentative")
    precondition(joint.startedAt == ISO8601DateFormatter.parse(eventTime) && joint.lastSeenAt == ISO8601DateFormatter.parse(commanderChannel.observedAt), "A failed webpage check must not replace actual incident times")
    let pairWithHealthyWeb = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志", history: [appClose, commanderChannel]), activity: safeIdle, network: guardianGood, service: "运行中", channelState: "通道畅通", now: now)
    precondition(pairWithHealthyWeb.title.contains("同时异常") && pairWithHealthyWeb.evidence.contains("不证明"), "A healthy public webpage probe must not hide a near-time App and Commander interruption")
    let appOnly = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志", history: [appClose]), activity: safeIdle, network: guardianGood, now: now)
    precondition(appOnly.title.contains("连接近期中断") && appOnly.evidence.contains("不等同于 Commander ping"))
    let opened = TimelineEvent(source: "chatgpt_app", event: "chatgpt_pubsub_transport_opened", sourceAt: ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-10)), observedAt: eventTime)
    let duplicateClose = TimelineEvent(source: "chatgpt_app", event: appClose.event, sourceAt: eventTime, observedAt: ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-49)))
    let interrupted = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志", history: [appClose, duplicateClose, opened]), activity: safeIdle, network: guardianGood, now: now)
    precondition(interrupted.title.contains("之后观察到重新连接") && !interrupted.title.contains("次"), "Co-temporal close records should collapse into one incident")
    let repeatClose = TimelineEvent(source: "chatgpt_app", event: appClose.event, sourceAt: ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-20)), observedAt: ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-19)))
    let repeatedDiagnosis = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志", history: [appClose, duplicateClose, repeatClose]), activity: safeIdle, network: guardianGood, now: now)
    precondition(repeatedDiagnosis.title.contains("近15分钟 2 个关闭时段"), "Distinct close groups should report the repeat count")
    let oldIssue = TimelineEvent(source: "chatgpt_app", event: "chatgpt_completion_transport_recovery_started", sourceAt: ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-1800)), observedAt: eventTime, failureKind: "resume_unavailable")
    let oldTimeline = TimelineSummary(coverage: "已覆盖当前日志", history: [oldIssue], latestAppIssue: oldIssue)
    let oldDiagnosis = IncidentDiagnosis.make(timeline: oldTimeline, activity: safeIdle, network: guardianGood, now: now)
    precondition(oldDiagnosis.title.contains("较早") && chatMonitorSummary(oldTimeline).answer.contains("恢复流不可用"), "Old unresolved answer incidents must persist separately")
    let oldPlusClose = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志", history: [oldIssue, appClose], latestAppIssue: oldIssue), activity: safeIdle, network: guardianGood, now: now)
    precondition(oldPlusClose.title.contains("更新连接近期中断"), "An old answer issue must not hide a new connection interruption")
    let stopped = IncidentDiagnosis.make(timeline: oldTimeline, activity: safeIdle, network: guardianGood, service: "未运行", channelState: "未知", now: now)
    precondition(stopped.title.contains("服务当前未运行"), "Current service state must outrank old answer history")
    let expired = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志", history: [TimelineEvent(source: "chatgpt_app", event: appClose.event, sourceAt: ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-901)), observedAt: eventTime)]), activity: safeIdle, network: guardianGood, now: now)
    precondition(expired.title.contains("没有可操作") && expired.startedAt == nil, "Expired incidents must not remain current")
    let earlierCommander = TimelineEvent(source: "commander", event: "Commander错误: 通道关闭", sourceAt: nil, observedAt: ISO8601DateFormatter.flex.string(from: now.addingTimeInterval(-600)))
    let exactJoint = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志", history: [earlierCommander, appClose, commanderChannel]), activity: safeIdle, network: guardianGood, now: now)
    precondition(exactJoint.startedAt == ISO8601DateFormatter.parse(eventTime) && exactJoint.lastSeenAt == ISO8601DateFormatter.parse(commanderChannel.observedAt), "Unrelated older Commander events must not change incident times")
    let unknownActivity = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志"), activity: ActivitySummary(state: "状态未确认"), network: guardianGood, now: now)
    precondition(unknownActivity.title.contains("未确认") && unknownActivity.nextAction.contains("当前不建议重启或重试"))
    let busyDiagnosis = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志"), activity: ActivitySummary(state: "收到调用（处理中）", active: ["read_file": 1]), network: guardianGood, now: now)
    precondition(busyDiagnosis.title.contains("进行中") && busyDiagnosis.nextAction.contains("等待当前调用返回"))
    let missingCoverage = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "读取失败"), activity: ActivitySummary(state: "未观察到新调用", observed: now.addingTimeInterval(-600)), network: guardianGood, now: now)
    precondition(missingCoverage.title.contains("覆盖") && missingCoverage.startedAt == nil, "An unrelated call timestamp cannot become a diagnostic gap start")
    let networkOnly = IncidentDiagnosis.make(timeline: TimelineSummary(coverage: "已覆盖当前日志"), activity: safeIdle, network: guardianBad, now: now)
    precondition(networkOnly.title.contains("网络守护近期") && networkOnly.startedAt == nil && networkOnly.lastSeenAt == guardianBad.updatedAt)
    precondition(IncidentDiagnosis.make(timeline: oldTimeline, activity: safeIdle, network: guardianGood, now: now).title.contains("较早"), "A successful probe must not clear an answer issue")
    print("CommanderGuard self-test passed")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private var channelTimer: Timer?
    private var assertion: IOPMAssertionID = 0
    private var paused = false
    private var snapshot = Snapshot()
    private var summaryLines: [NSMenuItem] = []
    private var statusMenu: NSMenu?
    private var guardItem: NSMenuItem!
    private var recoveryItem: NSMenuItem!
    private let recoveryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CommanderGuard/channel-recovery.json")
    private var recoveryLedger = ChannelRecoveryLedger.load(from: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CommanderGuard/channel-recovery.json"))
    private var watchdog = ChannelWatchdogState(startedAt: Date())
    private var channelBusy = false
    private var lastPingAt: Date?
    private var lastPingResult = "尚无实际检查结果"
    private var deferredReason = "等待首次检查"
    private var lastRecoveryOutcome: String?
    private var manualNotice: String?
    private var manualPingBusy = false
    private var toolProbeBusy = false
    private var lastToolProbeAttempt = Date.distantPast
    private var toolProbeDeferredReason = "等待首次工具检查"
    private var lastActivityPoll = Date.distantPast
    private var recoveryLaunched = false
    private let previewMode: Bool
    private var panelWindow: NSWindow?
    private var panelPage = 0
    private var panelScroll: NSScrollView?
    private var panelNav: NSSegmentedControl?
    private var panelHeading: NSStackView?
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
    private var panelNetwork: NSTextField?
    private var panelNetworkTime: NSTextField?
    private var panelNetworkDetail: NSTextField?
    private var panelRecoveryToggle: NSButton?
    private var panelRecoveryStatus: NSTextField?
    private var panelWakeToggle: NSButton?
    private var logTextView: NSTextView?
    private var recordSearch: NSSearchField?
    private var recordFilter: NSPopUpButton?
    private var recordTable: NSTableView?
    private var recordTableScroll: NSScrollView?
    private var recordDocument: NSStackView?
    private var recordDetail: NSTextField?
    private var recordSteps: [ActivityStep] = []
    private var selectedRecordID: String?
    private let activityReader = ActivityLogReader(errorURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RemoteDesktopCommander/stderr.log"))
    private var verifiedRestart: (old: Int32, new: Int32)?
    private let timelineReader = TimelineReader()
    private var activityBusy = false
    private var activityTimer: Timer?

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
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in self.poll() }
        channelTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in self.pollChannel(); self.pollToolExecution() }
        activityTimer = Timer(timeInterval: 1, repeats: true) { _ in self.pollActivity() }
        RunLoop.main.add(activityTimer!, forMode: .common)
        pollActivity()
    }
    func applicationWillTerminate(_ n: Notification) { timer?.invalidate(); channelTimer?.invalidate(); activityTimer?.invalidate(); releaseAssertion() }
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
    private func pollChannel() {
        let now = Date()
        guard !channelBusy, !manualPingBusy, watchdog.isDue(now: now) else { return }
        watchdog.lastProbe = now
        guard snapshot.service == "运行中" else { recordDeferred("Commander 服务未运行"); return }
        channelBusy = true; deferredReason = "正在检查"; render()
        MCPChannelProbe().run { result in
            DispatchQueue.main.async {
                self.channelBusy = false
                self.recordProbe(result, now: Date())
                if case .noLiveConnection = result, self.watchdog.failures >= 3 { self.considerRecovery() }
            }
        }
    }
    private func recordProbe(_ result: ChannelProbeResult, now: Date, manual: Bool = false) {
        lastPingAt = now; lastPingResult = probeDescription(result); deferredReason = "未延后"
        manualNotice = nil
        if manual { watchdog.observedManual(result, now: now) }
        else { watchdog.observed(result, now: now) }
        snapshot.channelState = watchdog.status; snapshot.channelDetail = watchdog.detail
        snapshot.channelFailures = watchdog.failures; snapshot.channelChecked = now
        render()
    }
    private func recordDeferred(_ reason: String) {
        deferredReason = reason; manualNotice = nil
        watchdog.observed(.unknown(reason), now: Date())
        snapshot.channelState = watchdog.status
        snapshot.channelFailures = watchdog.failures
        snapshot.channelDetail = "检查暂缓：\(reason)"
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
        let now = Date()
        guard !previewMode, !toolProbeBusy, !watchdog.recovering else { return }
        refreshToolExecutionFromActivity(snapshot.activity, now: now)
        if toolExecutionFresh(snapshot, now: now) { return }
        guard now.timeIntervalSince(lastToolProbeAttempt) >= 30 else { return }
        guard snapshot.service == "运行中" else { toolProbeDeferredReason = "Commander 服务未运行"; return }
        guard channelIndicator(service: snapshot.service, state: snapshot.channelState, checked: snapshot.channelChecked, now: now) == "●" else {
            toolProbeDeferredReason = "消息通道尚未确认"; return
        }
        guard activitySafeForRecovery(snapshot.activity), !activityBusy else {
            toolProbeDeferredReason = activityDeferralReason(snapshot.activity); return
        }
        startToolExecutionProbe(manual: false)
    }
    private func startToolExecutionProbe(manual: Bool) {
        let now = Date()
        guard !toolProbeBusy else { if manual { manualNotice = "工具执行检查已在进行"; render() }; return }
        refreshToolExecutionFromActivity(snapshot.activity, now: now)
        if toolExecutionFresh(snapshot, now: now) {
            if manual { manualNotice = "通道已检查；工具执行由最近真实调用验证"; render() }
            return
        }
        guard snapshot.service == "运行中" else { toolProbeDeferredReason = "Commander 服务未运行"; if manual { manualNotice = "工具检查暂缓：Commander 服务未运行"; render() }; return }
        guard activitySafeForRecovery(snapshot.activity), !activityBusy else {
            let reason = activityDeferralReason(snapshot.activity); toolProbeDeferredReason = reason
            if manual { manualNotice = "通道已检查；工具检查暂缓：\(reason)"; render() }
            return
        }
        lastToolProbeAttempt = now; toolProbeBusy = true; toolProbeDeferredReason = "正在执行只读工具检查"; render()
        MCPToolExecutionProbe().run { result in
            DispatchQueue.main.async {
                self.toolProbeBusy = false
                self.recordToolExecution(result, now: Date())
                if manual { self.manualNotice = "通道已检查；\(self.toolExecutionSummary(now: Date()))"; self.render() }
            }
        }
    }
    private func recordToolExecution(_ result: ToolExecutionProbeResult, now: Date) {
        snapshot.toolExecutionChecked = now
        switch result {
        case .verified:
            snapshot.toolExecutionState = "已验证"; snapshot.toolExecutionDetail = "只读 list_sessions 已经本机工具层执行"
        case .failed(let reason):
            snapshot.toolExecutionState = "失败"; snapshot.toolExecutionDetail = reason
        case .unknown(let reason):
            snapshot.toolExecutionState = "未知"; snapshot.toolExecutionDetail = reason
        }
        toolProbeDeferredReason = "未延后"
        render()
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
        guard !watchdog.recovering else { manualCheckBlocked("自动恢复处理中，暂不能手动检查"); return }
        guard !channelBusy, !manualPingBusy else { manualCheckBlocked("已有连接检查进行中"); return }
        guard Date().timeIntervalSince(watchdog.startedAt) >= 90 else { manualCheckBlocked("启动等待中，暂不能手动检查"); return }
        guard snapshot.service == "运行中" else { manualCheckBlocked("Commander 服务未运行"); return }
        manualNotice = nil; manualPingBusy = true; deferredReason = "手动检查进行中"; render()
        MCPChannelProbe().run { result in
            DispatchQueue.main.async {
                self.manualPingBusy = false
                self.recordProbe(result, now: Date(), manual: true)
                if case .healthy = result { self.startToolExecutionProbe(manual: true) }
                else { self.manualNotice = "消息通道未确认；未进行工具执行检查"; self.render() }
            }
        }
    }
    private func manualCheckBlocked(_ reason: String) { manualNotice = reason; render() }
    private func considerRecovery() {
        guard recoveryLedger.autoRecoveryEnabled else { snapshot.channelDetail = "自动恢复已关闭"; render(); return }
        guard recoveryLedger.canAttempt(at: Date()) else { snapshot.channelDetail = "处于持久化冷却期"; render(); return }
        guard activitySafeForRecovery(snapshot.activity) else { snapshot.channelDetail = "本机调用或日志状态阻止恢复"; render(); return }
        watchdog.recovering = true
        recoveryLaunched = false
        DispatchQueue.global(qos: .utility).async {
            guard let pid = self.servicePID(), CommanderProcessTree.safe(servicePID: pid) else {
                DispatchQueue.main.async { self.abortRecovery("进程树未知或含其他子进程；未重启") }
                return
            }
            DispatchQueue.main.async {
                guard self.recoveryGateOpen(oldPID: pid) else { self.abortRecovery("本机调用状态或自动恢复设置已变化；未重启"); return }
                Monitor.shared.checkOutstandingCalls { idle, error in
                    guard idle == true else { self.abortRecovery(error ?? "云端待执行调用状态未知；未重启"); return }
                    guard self.recoveryGateOpen(oldPID: pid) else { self.abortRecovery("本机调用状态或自动恢复设置已变化；未重启"); return }
                    DispatchQueue.global(qos: .utility).async {
                        let safe = self.servicePID() == pid && CommanderProcessTree.safe(servicePID: pid)
                        DispatchQueue.main.async {
                            guard safe, self.recoveryGateOpen(oldPID: pid) else { self.abortRecovery("服务进程或本机调用状态已变化；未重启"); return }
                            self.startRecovery(oldPID: pid)
                        }
                    }
                }
            }
        }
    }
    private func recoveryGateOpen(oldPID: Int32) -> Bool {
        watchdog.recovering && recoveryLedger.autoRecoveryEnabled && recoveryLedger.canAttempt(at: Date()) &&
        snapshot.service == "运行中" && activitySafeForRecovery(snapshot.activity) && !activityBusy &&
        Date().timeIntervalSince(lastActivityPoll) < 3
    }
    private func abortRecovery(_ detail: String) {
        watchdog.recovering = false; recoveryLaunched = false; snapshot.channelDetail = detail; render()
    }
    private func startRecovery(oldPID: Int32) {
        guard recoveryGateOpen(oldPID: oldPID) else { abortRecovery("恢复前状态已变化；未重启"); return }
        guard servicePID() == oldPID else { abortRecovery("Commander 进程已变化；未重启"); return }
        recoveryLedger.recordAttempt(at: Date())
        guard recoveryLedger.save(to: recoveryURL) else { abortRecovery("无法安全保存冷却记录；未重启"); return }
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
            MCPChannelProbe().run { result in DispatchQueue.main.async { self.recoveryFinished(oldPID: oldPID, newPID: newPID, result: result) } }
        }
    }
    private func recoveryFinished(oldPID: Int32, newPID: Int32?, result: ChannelProbeResult) {
        watchdog.recovering = false; recoveryLaunched = false
        if newPID != nil { lastPingAt = Date(); lastPingResult = probeDescription(result); snapshot.channelChecked = lastPingAt }
        lastRecoveryOutcome = newPID == nil ? resultMessageForMissingRecoveryProbe(result) : probeDescription(result)
        if recoveryConfirmed(oldPID: oldPID, newPID: newPID, probe: result) {
            watchdog.failures = 0; snapshot.channelState = "通道已恢复"; snapshot.channelDetail = "服务 PID 已变化，后续 MCP ping 成功"
            if let newPID, kill(oldPID, 0) == -1 && errno == ESRCH {
                verifiedRestart = (oldPID, newPID)
                pollActivity()
            }
        } else {
            snapshot.channelState = "恢复尚未确认"; snapshot.channelDetail = newPID == nil ? (watchdog.detail + "；" + probeDescription(result)) : "服务已重启，但后续 MCP ping 未成功（\(probeDescription(result))）"
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
        activityBusy = true
        DispatchQueue.global(qos: .utility).async {
            if let restart { self.activityReader.confirmedProcessRestart(oldPID: restart.old, newPID: restart.new, oldProcessExited: true) }
            self.activityReader.poll()
            self.timelineReader.poll()
            let value = self.activityReader.summary
            let timeline = self.timelineReader.summary
            DispatchQueue.main.async {
                self.snapshot.activity = value; self.snapshot.timeline = timeline; self.lastActivityPoll = Date(); self.activityBusy = false
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
        let connection = channelIndicator(service: snapshot.service, state: snapshot.channelState, checked: snapshot.channelChecked, now: Date())
        let connectionText = "Commander 服务\(snapshot.service == "运行中" ? "运行中" : (snapshot.service == "未运行" ? "未运行" : "状态未知"))"
        summaryLines[0].title = "消息通道：\(channelSummary(snapshot, now: Date()))"
        summaryLines[1].title = "工具执行：\(toolExecutionSummary(now: Date()))"
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
        let shortAction = middleTruncate(CommanderActivity.menuDetail(barAction), limit: 16)
        item.button?.title = "\(connection) \(middleTruncate(channelSummary(snapshot, now: Date()), limit: 8))\(barTimer.isEmpty ? (barDuration.map { " \($0)" } ?? "") : " \(barTimer)") · \(shortAction)"
        item.button?.setAccessibilityLabel("CommanderGuard，命令连接\(channelSummary(snapshot, now: Date()))")
        item.button?.setAccessibilityValue("本机操作：\(barAction)；\(callStatus)")
        item.button?.setAccessibilityHelp("点击打开运行概览；右键可查看菜单")
        let origin = "消息通道与本机工具执行分别验证；任一层成功都不代表 ChatGPT 原回答完成。\(conversationLabelNote(snapshot.timeline.conversationLabelsVerifiedAt)) 无新事件不表示空闲或完成。"
        let age = activity.observed.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "未知"
        item.button?.toolTip = "\(connectionText)\n消息通道：\(snapshot.channelState) · \(displayPingResult(snapshot.channelDetail))\n工具执行：\(toolExecutionSummary(now: Date())) · \(snapshot.toolExecutionDetail)\n\(returnedStep == nil ? "" : "本机调用已返回 · ")\(barAction)\(barDuration.map { " · 调用耗时 \($0)" } ?? "") · \(callStatus) · \(age)\n\(manualNotice.map { "手动检查：\(displayPingResult($0))\n" } ?? "")\(origin)"
        if !previewMode { writeStatus() }
        if panelWindow?.isVisible == true { renderPanel() }
    }
    private func recoveryAvailability() -> String {
        guard recoveryLedger.autoRecoveryEnabled else { return "已关闭" }
        if watchdog.recovering { return "恢复中" }
        guard recoveryLedger.canAttempt(at: Date()) else { return "已开启 · 冷却中" }
        guard snapshot.service == "运行中" else { return "已开启 · 等待 Commander 服务" }
        if !activitySafeForRecovery(snapshot.activity) { return "已开启 · 暂缓：\(activityDeferralReason(snapshot.activity))" }
        return "已开启 · 等待检查"
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
        let safeSteps: [[String: Any]] = snapshot.activity.steps.map { step in ["tool": step.tool, "detail": step.detail, "started_at": step.historical ? NSNull() : ISO8601DateFormatter.flex.string(from: step.startedAt) as Any, "elapsed_seconds": step.elapsed(at: ProcessInfo.processInfo.systemUptime) as Any? ?? NSNull(), "duration_seconds": step.duration as Any? ?? NSNull(), "uncertain": step.uncertain, "failed": step.failed, "historical": step.historical, "finished": step.finished] }
        let latestStep = currentCallStep(snapshot.activity)
        let callElapsed = latestStep?.elapsed(at: ProcessInfo.processInfo.systemUptime)
        let currentState = callState(snapshot.activity)
        let timelineRows: [[String: Any]] = snapshot.timeline.events.map { ["source": $0.source, "event": $0.event, "conversation_title": $0.conversationTitle as Any? ?? NSNull(), "failure_kind": $0.failureKind as Any? ?? NSNull(), "source_timestamp": $0.sourceAt as Any? ?? NSNull(), "observed_at": $0.observedAt] }
        let lastAppEvent: [String: Any] = snapshot.timeline.latestAppEvent.map { ["event": $0.event, "conversation_title": $0.conversationTitle as Any? ?? NSNull(), "failure_kind": $0.failureKind as Any? ?? NSNull(), "source_timestamp": $0.sourceAt as Any? ?? NSNull(), "observed_at": $0.observedAt] } ?? [:]
        let chat = chatMonitorSummary(snapshot.timeline)
        let diagnosis = currentDiagnosis()
        var object: [String: Any] = ["chatgpt": ["answer": chat.answer, "update_connection": chat.connection, "coverage": snapshot.timeline.coverage, "delivery_timeout_directly_observable": false, "limitation": chat.deliveryLimit], "service": snapshot.service, "cloud": snapshot.cloud, "last_seen": snapshot.lastSeen.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "checked_at": ISO8601DateFormatter.flex.string(from: snapshot.checked), "error_count": snapshot.errorCount, "paused": paused, "idle_prevention": assertion != 0, "message": snapshot.message, "channel": ["state": snapshot.channelState, "detail": snapshot.channelDetail, "consecutive_no_live": snapshot.channelFailures, "checked_at": snapshot.channelChecked.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "auto_recovery_enabled": recoveryLedger.autoRecoveryEnabled, "last_recovery_attempt": recoveryLedger.lastAttempt.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "last_ping_at": lastPingAt.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "last_ping_result": lastPingResult, "check_deferred_reason": deferredReason, "recovery_status": recoveryAvailability(), "last_recovery_result": lastRecoveryOutcome as Any? ?? NSNull()], "menu": ["menubar_title": item.button?.title ?? "", "menubar_has_icon": item.button?.image != nil, "connection": summaryLines[0].title, "channel": summaryLines[0].title, "tool_execution": summaryLines[1].title, "action": summaryLines[2].title, "recovery": summaryLines[3].title, "chatgpt": summaryLines[4].title, "execution_step_rows": rows, "execution_steps": safeSteps, "tool_call_elapsed_seconds": callElapsed as Any? ?? NSNull(), "tool_call_state": currentState, "recent_actions": snapshot.activity.recent], "activity": ["state": snapshot.activity.state, "tool": snapshot.activity.tool, "active_count": snapshot.activity.activeCount, "observed_at": snapshot.activity.observed.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "recent": snapshot.activity.recent, "error": snapshot.activity.error, "coverage_gap": snapshot.activity.coverageGap, "gap_reason": snapshot.activity.gapReason, "gap_first_at": snapshot.activity.gapFirstAt.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "gap_last_at": snapshot.activity.gapLastAt.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "backlog_bytes": snapshot.activity.backlogBytes, "catching_up": snapshot.activity.catchingUp, "pending_line": snapshot.activity.pendingLine, "idle_proven": snapshot.activity.idleProven], "timeline": ["coverage": snapshot.timeline.coverage, "commander_errors_this_run": snapshot.timeline.commanderErrors, "conversation_labels_verified_at": snapshot.timeline.conversationLabelsVerifiedAt as Any? ?? NSNull(), "last_chatgpt_app_event": lastAppEvent, "events": timelineRows]]
        object["tool_execution"] = ["state": snapshot.toolExecutionState, "detail": snapshot.toolExecutionDetail, "checked_at": snapshot.toolExecutionChecked.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "fresh": toolExecutionFresh(snapshot, now: Date()), "evidence_ttl_seconds": Int(toolExecutionEvidenceTTL), "probe_deferred_reason": toolProbeDeferredReason]
        object["diagnosis"] = ["title": diagnosis.title, "started_at": diagnosis.startedAt.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "last_seen_at": diagnosis.lastSeenAt.map(ISO8601DateFormatter.flex.string(from:)) as Any? ?? NSNull(), "next_action": diagnosis.nextAction, "evidence": diagnosis.evidence, "network_guardian": diagnosis.network.safeSummary]
        guard let d = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        do { try d.write(to: dir.appendingPathComponent("status.json"), options: .atomic) }
        catch { fputs("CommanderGuard: unable to write sanitized status file\n", stderr) }
    }
    @objc private func togglePause() { paused.toggle(); updateGuard(); render() }
    @objc private func toggleAutoRecovery() {
        var next = recoveryLedger; next.autoRecoveryEnabled.toggle()
        guard next.save(to: recoveryURL) else { snapshot.channelDetail = "自动恢复设置无法保存"; render(); return }
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
    private func card(_ content: NSView, padding: CGFloat = 18) -> NSVisualEffectView {
        let card = NSVisualEffectView(); card.material = .contentBackground; card.state = .active
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
        let stack = vertical(5)
        stack.addArrangedSubview(label(eyebrow.uppercased(), size: 10, weight: .semibold, color: .secondaryLabelColor))
        stack.addArrangedSubview(value); stack.addArrangedSubview(time)
        value.font = .systemFont(ofSize: 16, weight: .semibold)
        value.maximumNumberOfLines = 2
        time.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        time.textColor = .secondaryLabelColor
        detail.isHidden = true
        return card(stack, padding: 12)
    }
    private func buildPanel() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = previewMode ? "CommanderGuard · 界面预览" : "CommanderGuard"
        if previewMode && CommandLine.arguments.contains("--preview-dark") { window.appearance = NSAppearance(named: .darkAqua) }
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 760, height: 560); window.center()
        let root = NSView(); root.wantsLayer = true; window.contentView = root
        let layout = vertical(14); layout.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 20, right: 28)
        root.addSubview(layout); layout.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([layout.leadingAnchor.constraint(equalTo: root.leadingAnchor), layout.trailingAnchor.constraint(equalTo: root.trailingAnchor), layout.topAnchor.constraint(equalTo: root.topAnchor), layout.bottomAnchor.constraint(equalTo: root.bottomAnchor)])

        let title = vertical(4)
        title.addArrangedSubview(label("COMMANDERGUARD", size: 11, weight: .bold, color: .secondaryLabelColor))
        title.addArrangedSubview(label("运行概览", size: 27, weight: .bold))
        title.addArrangedSubview(label(previewMode ? "设计预览 · 以下为固定示例数据" : "消息通道、工具执行、ChatGPT 回答与网络路径分层观察", size: 13, color: .secondaryLabelColor))
        layout.addArrangedSubview(title)
        panelHeading = title

        let commandValue = label("等待观察"); let commandTime = label("检查：暂无"); let commandDetail = label("")
        let toolValue = label("未验证"); let toolTime = label("检查：暂无"); let toolDetail = label("")
        let chatValue = label("等待读取"); let chatTime = label("问题：暂无"); let chatDetail = label("")
        let networkValue = label("未确认"); let networkTime = label("检查：暂无"); let networkDetail = label("")
        panelConnection = commandValue; panelConnectionTime = commandTime; panelConnectionDetail = commandDetail
        panelToolExecution = toolValue; panelToolExecutionTime = toolTime; panelToolExecutionDetail = toolDetail
        panelChat = chatValue; panelChatTime = chatTime; panelChatDetail = chatDetail
        panelNetwork = networkValue; panelNetworkTime = networkTime; panelNetworkDetail = networkDetail
        let heroes = NSStackView(); heroes.orientation = .horizontal; heroes.spacing = 10; heroes.distribution = .fillEqually
        let commandCard = heroCard("消息通道", value: commandValue, time: commandTime, detail: commandDetail)
        let toolCard = heroCard("工具执行", value: toolValue, time: toolTime, detail: toolDetail)
        let chatCard = heroCard("ChatGPT 回答", value: chatValue, time: chatTime, detail: chatDetail)
        let networkCard = heroCard("网络路径", value: networkValue, time: networkTime, detail: networkDetail)
        [commandCard, toolCard, chatCard, networkCard].forEach { heroes.addArrangedSubview($0) }
        toolCard.heightAnchor.constraint(equalTo: commandCard.heightAnchor).isActive = true
        chatCard.heightAnchor.constraint(equalTo: commandCard.heightAnchor).isActive = true
        networkCard.heightAnchor.constraint(equalTo: commandCard.heightAnchor).isActive = true
        panelHeroMinimum = heroes.heightAnchor.constraint(greaterThanOrEqualToConstant: 76)
        panelHeroMinimum?.isActive = true
        layout.addArrangedSubview(heroes)
        heroes.widthAnchor.constraint(equalTo: layout.widthAnchor, constant: -56).isActive = true

        let controls = NSStackView(); controls.orientation = .horizontal; controls.alignment = .centerY; controls.spacing = 22
        let recovery = NSButton(checkboxWithTitle: "自动恢复命令连接", target: self, action: #selector(toggleAutoRecovery))
        let wake = NSButton(checkboxWithTitle: "保持电脑唤醒", target: self, action: #selector(togglePause))
        let check = NSButton(title: "检查链路", target: self, action: #selector(manualCheck)); check.bezelStyle = .rounded
        [recovery, wake, check].forEach { $0.isEnabled = !previewMode }
        panelRecoveryToggle = recovery; panelWakeToggle = wake
        controls.addArrangedSubview(recovery); controls.addArrangedSubview(wake)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal); controls.addArrangedSubview(spacer)
        controls.addArrangedSubview(check)
        let controlContent = vertical(5)
        controlContent.addArrangedSubview(controls)
        controls.widthAnchor.constraint(equalTo: controlContent.widthAnchor).isActive = true
        let recoveryStatus = label("自动恢复：等待检查", size: 11, color: .secondaryLabelColor)
        panelRecoveryStatus = recoveryStatus
        controlContent.addArrangedSubview(recoveryStatus)
        let controlCard = card(controlContent, padding: 16)
        layout.addArrangedSubview(controlCard)
        controlCard.widthAnchor.constraint(equalTo: layout.widthAnchor, constant: -56).isActive = true

        let nav = NSSegmentedControl(labels: ["概览", "操作记录", "连接诊断"], trackingMode: .selectOne, target: self, action: #selector(panelPageChanged(_:)))
        nav.selectedSegment = panelPage; nav.segmentStyle = .rounded; nav.heightAnchor.constraint(equalToConstant: 32).isActive = true
        panelNav = nav; layout.addArrangedSubview(nav)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical); scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        panelScroll = scroll; layout.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: layout.widthAnchor, constant: -56).isActive = true
        panelWindow = window
        renderPanelPage()
    }
    private func stamp(_ date: Date?) -> String { date.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .medium) } ?? "暂无" }
    private func prominentStamp(_ date: Date?) -> String { date.map { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: $0) } ?? "暂无" }
    private func eventStamp(_ event: TimelineEvent) -> String { stamp(ISO8601DateFormatter.parse(event.sourceAt ?? event.observedAt)) }
    private func displayPingResult(_ value: String) -> String { value.replacingOccurrences(of: "ping 成功", with: "命令连接检查成功") }
    private func currentDiagnosis(now: Date = Date()) -> IncidentDiagnosis {
        let network: NetworkGuardianStatus
        if previewMode {
            network = NetworkGuardianStatus(updatedAt: nil, healthy: nil, proxyAvailable: nil, tunnelState: "unknown", manualPause: nil, newLogFailures: nil, recentFailureScore: nil)
        } else {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OpenAILinkGuardian/status.json")
            network = NetworkGuardianStatus.read(url, now: now)
        }
        return IncidentDiagnosis.make(timeline: snapshot.timeline, activity: snapshot.activity, network: network,
                                      service: snapshot.service, channelState: snapshot.channelState, now: now)
    }
    private func networkLayerStatus(_ network: NetworkGuardianStatus) -> String {
        guard network.updatedAt != nil else { return "未确认" }
        if network.healthy == false || network.proxyAvailable == false || network.tunnelState == "down" { return "异常" }
        if network.healthy == true && network.proxyAvailable == true && network.tunnelState == "running" { return "网页探测正常" }
        return "部分确认"
    }
    private func renderPanel() {
        guard panelWindow != nil else { return }
        let now = Date()
        let diagnosis = currentDiagnosis(now: now)
        panelConnection?.stringValue = channelSummary(snapshot, now: now)
        let marker = channelIndicator(service: snapshot.service, state: snapshot.channelState, checked: snapshot.channelChecked, now: now)
        panelConnection?.textColor = marker == "●" ? .systemGreen : (marker == "!" ? .systemRed : .labelColor)
        panelConnectionTime?.stringValue = "检查：\(prominentStamp(lastPingAt))"
        let channelDetail = displayPingResult(manualNotice ?? (manualPingBusy || channelBusy ? deferredReason : snapshot.channelDetail))
        panelConnectionDetail?.stringValue = middleTruncate(channelDetail, limit: 56)

        let toolState = toolExecutionSummary(now: now)
        panelToolExecution?.stringValue = toolState
        panelToolExecution?.textColor = snapshot.toolExecutionState == "失败" ? .systemRed : (toolExecutionFresh(snapshot, now: now) ? .systemGreen : .labelColor)
        panelToolExecutionTime?.stringValue = "检查：\(prominentStamp(snapshot.toolExecutionChecked))"
        panelToolExecutionDetail?.stringValue = middleTruncate(toolProbeBusy ? "正在执行只读工具检查" : snapshot.toolExecutionDetail, limit: 56)

        let chat = chatMonitorSummary(snapshot.timeline)
        if let issue = snapshot.timeline.latestAppIssue,
           let issueAt = ISO8601DateFormatter.parse(issue.sourceAt ?? issue.observedAt) {
            let recent = now.timeIntervalSince(issueAt) >= 0 && now.timeIntervalSince(issueAt) <= 900
            panelChat?.stringValue = recent ? "回答异常（恢复未确认）" : "历史异常 · 原回答未确认"
            panelChat?.textColor = recent ? .systemOrange : .secondaryLabelColor
            panelChatTime?.stringValue = "回答问题：\(prominentStamp(issueAt))"
        } else {
            panelChat?.stringValue = chat.answer; panelChat?.textColor = .labelColor
            panelChatTime?.stringValue = "回答问题：暂无"
        }
        panelChatDetail?.stringValue = middleTruncate("更新连接：\(chat.connection)", limit: 56)

        let networkState = networkLayerStatus(diagnosis.network)
        panelNetwork?.stringValue = networkState
        panelNetwork?.textColor = networkState == "异常" ? .systemRed : (networkState == "网页探测正常" ? .systemGreen : .labelColor)
        panelNetworkTime?.stringValue = "检查：\(prominentStamp(diagnosis.network.updatedAt))"
        panelNetworkDetail?.stringValue = diagnosis.network.updatedAt == nil ? "守护状态缺失、无效或已过期" : middleTruncate(diagnosis.network.safeSummary, limit: 56)

        panelRecoveryToggle?.state = recoveryLedger.autoRecoveryEnabled ? .on : .off
        panelWakeToggle?.state = paused ? .off : .on
        panelRecoveryStatus?.stringValue = "自动恢复：\(middleTruncate(recoveryAvailability(), limit: 85))"
        renderPanelPage()
    }
    private func row(_ title: String, _ value: String, color: NSColor = .labelColor) -> NSView {
        let h = NSStackView(); h.orientation = .horizontal; h.alignment = .top; h.spacing = 14
        let key = label(title, size: 12, weight: .medium, color: .secondaryLabelColor)
        key.widthAnchor.constraint(equalToConstant: 128).isActive = true
        let content = label(value, size: 13, color: color)
        if ["首次观察", "最近观察"].contains(title) { content.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold) }
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
        let origin = scroll.contentView.bounds.origin
        let doc = NSStackView(); doc.orientation = .vertical; doc.alignment = .leading; doc.spacing = 14
        for section in sections { doc.addArrangedSubview(section); section.widthAnchor.constraint(equalTo: doc.widthAnchor).isActive = true }
        scroll.documentView = doc
        doc.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)])
        doc.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func renderPanelPage() {
        guard panelWindow != nil else { return }
        panelHeading?.isHidden = panelPage == 1
        panelConnectionDetail?.isHidden = panelPage == 1
        panelToolExecutionDetail?.isHidden = panelPage == 1
        panelChatDetail?.isHidden = panelPage == 1
        panelNetworkDetail?.isHidden = panelPage == 1
        panelHeroMinimum?.constant = panelPage == 1 ? 64 : 76
        if panelPage == 1 { renderLogPage(); return }
        let chat = chatMonitorSummary(snapshot.timeline)
        let activity = snapshot.activity
        let events = visibleTimelineEvents(snapshot.timeline.history).sorted { ($0.sourceAt ?? $0.observedAt) > ($1.sourceAt ?? $1.observedAt) }
        if panelPage == 0 {
            let diagnosis = currentDiagnosis()
            let active = currentCallStep(activity)
            let action = active.map { "\($0.detail) · \($0.historical ? "开始时间未知" : stamp($0.startedAt))" } ?? callState(activity)
            let recent = groupedTimelineEvents(events).prefix(5).map { event, count in
                (eventStamp(event), (event.source == "chatgpt_app" ? appEventLabel(event) : commanderEventLabel(event.event)) + (count > 1 ? " ×\(count)" : ""))
            }
            setSections([
                section("当前需要处理", rows: [("判断", diagnosis.title), ("下一步", diagnosis.nextAction), ("首次观察", stamp(diagnosis.startedAt)), ("最近观察", stamp(diagnosis.lastSeenAt)), ("说明", diagnosis.evidence)]),
                section("当前活动", subtitle: "仅表示本机已观察到的调用", rows: [("状态", action), ("日志", activity.error ? "暂时不可读" : activity.coverageGap ? "覆盖缺口 · \(activity.gapReason)" : activity.catchingUp ? "追赶中" : "读取正常")]),
                section("最近事件", subtitle: "顶部四张状态卡已显示当前链路状态；这里仅保留事件经过", rows: recent.isEmpty ? [("记录", "暂无连接或异常事件")] : recent)
            ])
        } else {
            let diagnosis = currentDiagnosis()
            let remaining = recoveryLedger.lastAttempt.map { max(0, 300 - Int(Date().timeIntervalSince($0))) }
            let recent = groupedTimelineEvents(events).prefix(20).map { event, count in
                (eventStamp(event), "\(event.source == "chatgpt_app" ? "ChatGPT" : "Commander") · \(event.source == "chatgpt_app" ? appEventLabel(event) : commanderEventLabel(event.event))" + (count > 1 ? " ×\(count)" : ""))
            }
            setSections([
                section("诊断与下一步", rows: [("判断", diagnosis.title), ("建议", diagnosis.nextAction), ("首次观察", stamp(diagnosis.startedAt)), ("最近观察", stamp(diagnosis.lastSeenAt)), ("证据范围", diagnosis.evidence)]),
                section("网络守护证据", subtitle: "顶部卡片只显示结论；这里保留判断依据", rows: [("选定状态", diagnosis.network.safeSummary)]),
                section("Commander 诊断依据", subtitle: "不重复顶部状态与时间，只显示额外证据", rows: [("服务", snapshot.service), ("云端登记", snapshot.cloud), ("通道说明", displayPingResult(snapshot.channelDetail)), ("工具依据", snapshot.toolExecutionDetail), ("工具检查暂缓", toolProbeBusy ? "正在检查" : toolProbeDeferredReason), ("手动检查", displayPingResult(manualNotice ?? deferredReason))]),
                section("自动恢复", rows: [("状态", recoveryAvailability()), ("冷却剩余", remaining.map { "\($0) 秒" } ?? "无"), ("最近尝试", stamp(recoveryLedger.lastAttempt)), ("最近结果", lastRecoveryOutcome ?? (recoveryLedger.lastAttempt == nil ? "暂无恢复尝试" : "本次运行未观察到结果"))]),
                section("ChatGPT 观察范围", subtitle: "回答状态与更新连接已在顶部显示", rows: [("监控范围", "仅当前本机 App 的固定事件；其他设备或网页提示可能不可见"), ("覆盖限制", chat.deliveryLimit), ("处理建议", "回原对话确认回答状态，核对操作记录后再决定是否继续")]),
                section("日志覆盖", rows: [("本机活动", callState(activity)), ("调用日志", activity.error ? "暂时不可读" : activity.coverageGap ? "覆盖缺口 · \(activity.gapReason)" : activity.catchingUp ? "追赶中 · 剩余 \(activity.backlogBytes) 字节" : "当前未发现覆盖缺口"), ("缺口首次", stamp(activity.gapFirstAt)), ("缺口最近", stamp(activity.gapLastAt)), ("时间线", snapshot.timeline.coverage)]),
                section("连接与异常", subtitle: "最多 20 条 · 新事件在前", rows: recent.isEmpty ? [("记录", "暂无连接事件")] : recent)
            ])
        }
    }
    private func sourceColor(_ title: String) -> NSColor {
        let colors: [NSColor] = [.systemBlue, .systemTeal, .systemPurple, .systemOrange, .systemPink]
        return colors[Int(Array(SHA256.hash(data: Data(title.utf8)))[0]) % colors.count]
    }
    private func renderLogPage() {
        guard let scroll = panelScroll else { return }
        let doc: NSStackView
        if let document = recordDocument {
            doc = document
        } else {
            doc = vertical(12)
            doc.translatesAutoresizingMaskIntoConstraints = false
            let search = NSSearchField(); search.placeholderString = "搜索命令、工具或路径"; (search.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = true
            search.target = self; search.action = #selector(recordSearchChanged(_:)); recordSearch = search
            let filter = NSPopUpButton(); filter.addItems(withTitles: ["全部", "进行中", "异常与未确认"])
            filter.target = self; filter.action = #selector(recordFilterChanged(_:)); recordFilter = filter
            let controls = NSStackView(views: [search, filter]); controls.orientation = .horizontal; controls.spacing = 10
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
            filter.widthAnchor.constraint(equalToConstant: 180).isActive = true
            doc.addArrangedSubview(label("本机操作记录 · 最多 100 条 · 归属未确认", size: 14, weight: .semibold))
            doc.addArrangedSubview(label("搜索仅匹配已脱敏的命令、工具和路径；选择记录查看完整内容与时间。", size: 12, color: .secondaryLabelColor))
            doc.addArrangedSubview(controls)
            let detail = label("选择一条记录查看详情", size: 13)
            detail.isSelectable = true
            recordDetail = detail
            let detailCard = card(detail, padding: 14); doc.addArrangedSubview(detailCard)
            detailCard.widthAnchor.constraint(equalTo: doc.widthAnchor).isActive = true
            let table = NSTableView(); table.headerView = nil; table.rowHeight = 44; table.delegate = self; table.dataSource = self
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("record")); column.title = "本机操作"; column.width = 660
            table.addTableColumn(column); table.usesAlternatingRowBackgroundColors = true
            let tableScroll = NSScrollView(); tableScroll.hasVerticalScroller = true; tableScroll.documentView = table
            tableScroll.heightAnchor.constraint(equalToConstant: 230).isActive = true
            recordTable = table; recordTableScroll = tableScroll; doc.addArrangedSubview(tableScroll)
            let eventTitle = label("ChatGPT App 事件 · 最近 25 条 · 原始事件时间", size: 15, weight: .semibold)
            doc.addArrangedSubview(eventTitle)
            let eventsText = NSTextView(); eventsText.isEditable = false; eventsText.isSelectable = true; eventsText.isRichText = true
            eventsText.font = .monospacedSystemFont(ofSize: 12, weight: .regular); eventsText.textContainerInset = NSSize(width: 10, height: 8)
            eventsText.isVerticallyResizable = true; eventsText.isHorizontallyResizable = false; eventsText.textContainer?.widthTracksTextView = true
            eventsText.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
            doc.addArrangedSubview(eventsText); logTextView = eventsText
            scroll.documentView = doc
            recordDocument = doc
            NSLayoutConstraint.activate([doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)])
        }
        if scroll.documentView !== doc { scroll.documentView = doc }
        let oldOrigin = scroll.contentView.bounds.origin
        let oldTableOrigin = recordTableScroll?.contentView.bounds.origin ?? .zero
        let query = recordSearch?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let mode = recordFilter?.indexOfSelectedItem ?? 0
        recordSteps = snapshot.activity.steps.filter { step in
            let text = "\(step.tool) \(step.detail)".lowercased()
            let matchesQuery = query.isEmpty || text.contains(query)
            let matchesMode = mode == 0 || (mode == 1 ? (!step.finished && !step.failed && !step.uncertain) : (step.failed || step.uncertain))
            return matchesQuery && matchesMode
        }
        if !recordSteps.contains(where: { $0.id == selectedRecordID }) { selectedRecordID = recordSteps.first?.id }
        recordTable?.reloadData()
        if let selectedRecordID, let index = recordSteps.firstIndex(where: { $0.id == selectedRecordID }) {
            recordTable?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        updateRecordDetail()
        let output = NSMutableAttributedString()
        func append(_ value: String, color: NSColor = .labelColor, weight: NSFont.Weight = .regular) {
            output.append(NSAttributedString(string: value, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: weight), .foregroundColor: color]))
        }
        for event in snapshot.timeline.history.filter({ $0.source == "chatgpt_app" }).sorted(by: { ($0.sourceAt ?? $0.observedAt) < ($1.sourceAt ?? $1.observedAt) }).suffix(25) {
            append("\(eventStamp(event))  ", color: .secondaryLabelColor)
            if let title = event.conversationTitle { append("[\(title)]  ", color: sourceColor(title), weight: .semibold) }
            else { append("[来源未识别]  ", color: .tertiaryLabelColor) }
            let value = appEventLabel(event), prefix = event.conversationTitle.map { "\($0) · " } ?? ""
            append("\(!prefix.isEmpty && value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value)\n")
        }
        if output.length == 0 { append("暂无 ChatGPT App 事件\n", color: .secondaryLabelColor) }
        if let text = logTextView {
            let selection = text.selectedRange(), selected = selection.length > 0 && NSMaxRange(selection) <= (text.string as NSString).length ? (text.string as NSString).substring(with: selection) : ""
            text.textStorage?.setAttributedString(output)
            if !selected.isEmpty { let range = (output.string as NSString).range(of: selected); if range.location != NSNotFound { text.setSelectedRange(range) } }
        }
        doc.layoutSubtreeIfNeeded()
        if let table = recordTable, let tableScroll = recordTableScroll {
            table.setFrameSize(NSSize(width: max(660, tableScroll.contentView.bounds.width), height: max(tableScroll.contentView.bounds.height, CGFloat(recordSteps.count) * table.rowHeight)))
            table.sizeLastColumnToFit()
        }
        scroll.contentView.scroll(to: oldOrigin); scroll.reflectScrolledClipView(scroll.contentView)
        if let tableScroll = recordTableScroll { tableScroll.contentView.scroll(to: oldTableOrigin); tableScroll.reflectScrolledClipView(tableScroll.contentView) }
    }
    @objc private func recordSearchChanged(_ sender: NSSearchField) { renderLogPage() }
    @objc private func recordFilterChanged(_ sender: NSPopUpButton) { renderLogPage() }
    func numberOfRows(in tableView: NSTableView) -> Int { recordSteps.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let step = recordSteps[row]
        let time = step.historical ? "时间未知" : prominentStamp(step.startedAt)
        let status = step.uncertain ? "未确认" : step.failed ? "异常" : step.finished ? "已返回" : "进行中"
        let field = NSTextField(wrappingLabelWithString: "\(time) · \(status) · \(step.detail)")
        field.lineBreakMode = .byTruncatingTail; field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.textColor = step.uncertain ? .systemOrange : step.failed ? .systemRed : .labelColor
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = recordTable, table.selectedRow >= 0, recordSteps.indices.contains(table.selectedRow) else { return }
        selectedRecordID = recordSteps[table.selectedRow].id; updateRecordDetail()
    }
    private func updateRecordDetail() {
        guard let step = recordSteps.first(where: { $0.id == selectedRecordID }) else { recordDetail?.stringValue = "当前筛选下没有匹配记录"; return }
        let time = step.historical ? "时间未知" : prominentStamp(step.startedAt)
        let state = step.uncertain ? "未确认" : step.failed ? "异常" : step.finished ? "已返回" : "进行中"
        let duration = step.historical ? "耗时未知" : step.uncertain ? "耗时未确认" : step.duration.map(durationText) ?? barCallClock(step, uptime: ProcessInfo.processInfo.systemUptime)
        let value = "\(time)  ·  \(state)  ·  \(duration)\n\(step.detail)"
        if recordDetail?.currentEditor() == nil, recordDetail?.stringValue != value { recordDetail?.stringValue = value }
    }
    private func loadPreviewSnapshot() {
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        snapshot.service = "运行中"; snapshot.cloud = "已连接"
        snapshot.channelState = "通道畅通"; snapshot.channelDetail = "最近一次检查通过 · 示例"
        snapshot.channelChecked = now.addingTimeInterval(-38)
        snapshot.toolExecutionState = "已验证"; snapshot.toolExecutionDetail = "复用最近真实工具调用成功记录 · 示例"; snapshot.toolExecutionChecked = now.addingTimeInterval(-26)
        lastPingAt = snapshot.channelChecked; lastPingResult = "ping 成功 · 示例"
        deferredReason = "未延后"
        snapshot.activity.state = "有本机调用进行中"
        snapshot.activity.active = ["执行命令": 1]
        snapshot.activity.steps = [
            ActivityStep(id: "preview-1", tool: "读取文件", detail: "读取文件 · /Projects/example/README.md", startedAt: now.addingTimeInterval(-95), startedUptime: uptime - 95, duration: 2, finished: true),
            ActivityStep(id: "preview-2", tool: "执行命令", detail: "执行命令 · swift test --filter ConnectionTests", startedAt: now.addingTimeInterval(-34), startedUptime: uptime - 34, duration: nil),
            ActivityStep(id: "preview-3", tool: "搜索", detail: "搜索 · rg -n 'connection' Sources", startedAt: now.addingTimeInterval(-240), startedUptime: uptime - 240, duration: 1, finished: true),
            ActivityStep(id: "preview-4", tool: "读取文件", detail: "读取文件 · /Projects/example/error.log", startedAt: now.addingTimeInterval(-18), startedUptime: uptime - 18, duration: 0.4, failed: true, finished: true)
        ]
        let makeTime: (TimeInterval) -> String = { ISO8601DateFormatter.flex.string(from: now.addingTimeInterval($0)) }
        let issue = TimelineEvent(source: "chatgpt_app", event: "chatgpt_completion_transport_recovery_started", sourceAt: makeTime(-65), observedAt: makeTime(-64), conversationTitle: "设计讨论", failureKind: "resume_unavailable")
        let app = TimelineEvent(source: "chatgpt_app", event: "chatgpt_conversation_refetch_completed · error", sourceAt: makeTime(-58), observedAt: makeTime(-57), conversationTitle: "功能排查")
        let closed = TimelineEvent(source: "chatgpt_app", event: "chatgpt_pubsub_transport_closed", sourceAt: makeTime(-70), observedAt: makeTime(-69))
        snapshot.timeline = TimelineSummary(coverage: "读取正常 · 示例", events: [closed, issue, app], history: [closed, issue, app], commanderErrors: 0, latestAppEvent: app, latestAppIssue: app, conversationLabelsVerifiedAt: makeTime(-3600))
        render()
    }
    private func verifyPanelLayout() {
        func verify(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fputs("CommanderGuard UI check failed: \(message)\n", stderr); exit(2) }
        }
        guard let window = panelWindow, let root = window.contentView, let scroll = panelScroll else { fputs("CommanderGuard UI check failed: panel was not created\n", stderr); exit(2) }
        for size in [NSSize(width: 940, height: 720), NSSize(width: 760, height: 560)] {
            window.setContentSize(size)
            for page in 0...2 {
                panelPage = page; renderPanel()
                root.layoutSubtreeIfNeeded()
                verify(window.isVisible && scroll.frame.width > 650 && scroll.frame.height > 80, "panel content is clipped at \(Int(size.width))x\(Int(size.height)), page \(page)")
                verify(scroll.documentView != nil, "panel page \(page) is empty")
            }
        }
        panelPage = 1; renderPanel()
        guard let text = logTextView else { fputs("CommanderGuard UI check failed: records are missing\n", stderr); exit(2) }
        verify((10...12).contains(panelConnectionTime?.font?.pointSize ?? 0) && (10...12).contains(panelToolExecutionTime?.font?.pointSize ?? 0) && (10...12).contains(panelChatTime?.font?.pointSize ?? 0) && (10...12).contains(panelNetworkTime?.font?.pointSize ?? 0), "layer timestamps are not secondary to state")
        precondition(recordSteps.count == 4, "Record page must expose all source rows")
        recordFilter?.selectItem(at: 1); renderLogPage()
        precondition(recordSteps.count == 1 && recordSteps[0].id == "preview-2", "Ongoing filter must match only ongoing work")
        recordFilter?.selectItem(at: 2); renderLogPage()
        precondition(recordSteps.count == 1 && recordSteps[0].id == "preview-4", "Issue filter must include failed and unconfirmed work")
        recordSearch?.stringValue = "error.log"; renderLogPage()
        precondition(recordSteps.count == 1 && recordSteps[0].detail.contains("error.log"), "Search must match sanitized paths")
        recordSearch?.stringValue = ""; recordFilter?.selectItem(at: 0); renderLogPage()
        guard let table = recordTable, let selected = recordSteps.firstIndex(where: { $0.id == "preview-2" }) else { preconditionFailure("Filtered record rows are missing") }
        table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        precondition(recordDetail?.stringValue.contains("swift test --filter ConnectionTests") == true, "Selecting a row must reveal the complete safe command")
        let selectedID = selectedRecordID
        renderPanel()
        precondition(selectedRecordID == selectedID && recordDetail?.stringValue.contains("swift test --filter ConnectionTests") == true, "Selected record detail must survive refresh")
        text.setSelectedRange(NSRange(location: 0, length: 4))
        renderPanel()
        precondition(logTextView === text && text.selectedRange().length == 4, "Record selection must survive refresh")
        text.setSelectedRange(NSRange(location: 0, length: 0)); renderPanel()
        precondition(logTextView === text, "Record view must be reused")
        precondition(item.button?.image?.isTemplate == true && item.button?.title.contains("通道可回应") == true && item.button?.title.contains("DC ") == false, "Menu bar must show an icon and scoped live status")
        precondition(panelHeading?.isHidden == true && panelConnectionTime?.isHidden == false && panelRecoveryToggle?.isHidden == false, "Records must retain compact status and controls")
        print("CommanderGuard UI check passed")
    }
    private func commanderEventLabel(_ event: String) -> String {
        guard let separator = event.range(of: ": ") else { return event }
        let kind = String(event[..<separator.lowerBound]), tool = String(event[separator.upperBound...])
        let label = ["调用receipt": "收到调用", "调用completion": "本机调用已返回", "调用error": "本机调用异常"][kind] ?? kind
        return "\(label)：\(tool)"
    }
}

if CommandLine.arguments.contains("--self-test") { selfTest() }
else if CommandLine.arguments.contains("--preview-ui") {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate(previewMode: true); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
else if CommandLine.arguments.contains("--probe-channel") {
    MCPChannelProbe().run { result in
        let state: String
        let code: Int32
        switch result { case .healthy: state = "通道畅通"; code = 0; case .noLiveConnection: state = "设备无实时连接"; code = 2; case .unknown: state = "通道状态未知"; code = 1 }
        if let data = try? JSONSerialization.data(withJSONObject: ["channel": state, "checked_at": ISO8601DateFormatter.flex.string(from: Date())], options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
        exit(code)
    }
    dispatchMain()
}
else if CommandLine.arguments.contains("--probe-tool") {
    MCPToolExecutionProbe().run { result in
        let state: String
        let code: Int32
        switch result { case .verified: state = "工具执行已验证"; code = 0; case .failed: state = "工具执行失败"; code = 2; case .unknown: state = "工具执行状态未知"; code = 1 }
        if let data = try? JSONSerialization.data(withJSONObject: ["tool_execution": state, "checked_at": ISO8601DateFormatter.flex.string(from: Date())], options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
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
