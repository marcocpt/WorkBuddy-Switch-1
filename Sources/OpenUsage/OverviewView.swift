import Charts
import SwiftUI

struct OverviewView: View {
    private struct TrendPoint: Identifiable {
        let date: Date
        let tokens: Int

        var id: Date { date }
    }

    @ObservedObject var state: AppState
    @ObservedObject private var accounts: AccountStore
    @ObservedObject private var traeAccounts: TraeAccountStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: AppState) {
        self.state = state
        _accounts = ObservedObject(wrappedValue: state.accounts)
        _traeAccounts = ObservedObject(wrappedValue: state.traeAccounts)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if state.hasAnySavedAccount,
                   state.isCreditStatsLoading || !state.creditStats.isEmpty {
                    creditStatsPanel
                }
                hero
                metrics
                HStack(alignment: .top, spacing: 22) {
                    trend
                        .frame(maxWidth: .infinity)
                    quotaPanel
                        .frame(width: 260)
                }
                if state.selectedProvider.supportsSessions {
                    recentSessions
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
        }
        .toolbar {
            ToolbarItemGroup {
                if state.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await state.refreshAll(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
                .accessibilityLabel("刷新")
            }
        }
    }

    // MARK: - 积分统计

    private var creditStatsPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("积分统计")
                    .font(.system(size: 16, weight: .semibold))
                if state.isCreditStatsLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }
            .padding(.bottom, 10)
            if state.isCreditStatsLoading && state.creditStats.isEmpty {
                creditSkeletonColumns
            } else {
                creditColumns
            }
        }
        .padding(.top, 18)
    }

    /// 每个 app 一列（WorkBuddy / Trae CN / TRAE Work），列内卡片按最近到期日升序。
    private var creditColumns: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(CreditStatMapper.columns(state.creditStats)) { column in
                VStack(alignment: .leading, spacing: 10) {
                    creditColumnHeader(column.provider, count: column.stats.count)
                    ForEach(column.stats) { stat in
                        CreditStatCard(
                            stat: stat,
                            onSwitchAccount: { switchAccount(stat) },
                            onRefresh: {
                                Task { await state.refreshAll(force: true) }
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// 首次加载尚未拿到数据时，按「有已保存账号的 app」铺骨架列。
    private var creditSkeletonColumns: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(providersWithSavedAccounts, id: \.self) { provider in
                VStack(alignment: .leading, spacing: 10) {
                    creditColumnHeader(provider, count: nil)
                    creditSkeletonCard
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func creditColumnHeader(_ provider: ManagedProvider, count: Int?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: provider.systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(provider.title)
                .font(.system(size: 12, weight: .semibold))
            if let count {
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    /// 拥有已保存账号的 app（首次加载铺骨架时用），顺序与列顺序一致。
    private var providersWithSavedAccounts: [ManagedProvider] {
        var result: [ManagedProvider] = []
        if !accounts.accounts.isEmpty {
            result.append(.workBuddy)
        }
        for variant in TraeVariant.allCases where !traeAccounts.accounts(for: variant).isEmpty {
            result.append(variant.provider)
        }
        return result
    }

    /// 点击积分卡图标：把该卡片账号切换为当前激活账号（当前账号禁用）。
    /// 由 AppState.switchOverviewAccount 原子执行：先对齐 provider，再切账号，
    /// 只触发一次刷新，避免跨 provider 错绑 usageAccountID。
    private func switchAccount(_ stat: AccountCreditStat) {
        Task {
            await state.switchOverviewAccount(
                provider: stat.provider,
                sourceUserID: stat.sourceUserID,
                isCurrent: stat.isCurrent
            )
        }
    }

    private var creditSkeletonCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.08))
                .frame(width: 96, height: 12)
            ProgressView()
                .controlSize(.small)
                .frame(width: 80, height: 24, alignment: .leading)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.06))
                .frame(height: 10)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(OpenUsageColors.separator, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var hero: some View {
        ZStack(alignment: .leading) {
            SpectralRibbonField()
            VStack(alignment: .leading, spacing: 10) {
                Text("WorkBuddy Switch")
                    .font(.system(size: 38, weight: .semibold))
                Text(
                    state.activeCurrentAccountName
                        ?? "尚未保存 \(state.selectedProvider.title) 账号"
                )
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Circle()
                        .fill(
                            state.activeCurrentUserID == nil
                                ? Color.orange
                                : Color.green
                        )
                        .frame(width: 7, height: 7)
                    Text(
                        state.activeCurrentUserID == nil
                            ? "等待 \(state.selectedProvider.title) 登录"
                            : "\(state.selectedProvider.title) 认证已读取"
                    )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 26)
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(OpenUsageColors.separator, lineWidth: 1)
        }
        .padding(.top, 18)
    }

    private var metrics: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
            spacing: 12
        ) {
            MetricTile(
                title: "Token",
                value: DisplayFormat.tokens(state.usage.total.total),
                detail: state.usagePeriod.title,
                systemImage: "number",
                tint: OpenUsageColors.blue
            )
            MetricTile(
                title: usageAmountTitle,
                value: usageAmountValue,
                detail: state.selectedProvider == .workBuddy
                    ? "WorkBuddy 本地记录"
                    : "\(state.selectedProvider.title) API",
                systemImage: "bolt.fill",
                tint: OpenUsageColors.coral
            )
            if state.selectedProvider.supportsSessions {
                MetricTile(
                    title: "对话",
                    value: state.usage.sessions.count.formatted(),
                    detail: "\(recoverableSessionCount) 个可恢复",
                    systemImage: "bubble.left.and.bubble.right.fill",
                    tint: OpenUsageColors.cyan
                )
            } else {
                MetricTile(
                    title: "模型",
                    value: state.usage.models.count.formatted(),
                    detail: "\(state.usage.scannedFiles) 条 API 记录",
                    systemImage: "cpu.fill",
                    tint: OpenUsageColors.cyan
                )
            }
            MetricTile(
                title: "账号",
                value: state.activeAccountCount.formatted(),
                detail: state.activeCurrentAccountShortID ?? "未连接",
                systemImage: "person.2.fill",
                tint: OpenUsageColors.lime
            )
        }
    }

    private var recoverableSessionCount: Int {
        state.sessions.filter {
            !$0.isDeleted && state.canResume($0)
        }.count
    }

    private var usageAmountTitle: String {
        guard state.selectedProvider != .workBuddy else { return "Credits" }
        guard let unit = state.traeQuota?.unit else { return "用量" }
        return unit == .requests ? "请求" : "Credits"
    }

    private var usageAmountValue: String {
        guard state.selectedProvider != .workBuddy else {
            return DisplayFormat.credits(state.usage.credits)
        }
        guard let unit = state.traeQuota?.unit else { return "--" }
        if unit == .requests {
            return state.usage.total.requestCount.formatted()
        }
        return DisplayFormat.credits(state.usage.credits)
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Token 趋势")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(state.usagePeriod.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if trendPoints.isEmpty {
                EmptyStateView(
                    systemImage: "chart.xyaxis.line",
                    title: state.usageMessage == nil ? "暂无用量" : "无法读取用量",
                    message: state.usageMessage ?? emptyTrendMessage
                )
                .frame(height: 190)
            } else {
                Chart(trendPoints) { point in
                    AreaMark(
                        x: .value(
                            "时间",
                            point.date,
                            unit: usesHourlyTrend ? .hour : .day
                        ),
                        y: .value("Token", Double(point.tokens))
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                OpenUsageColors.blue.opacity(0.22),
                                OpenUsageColors.blue.opacity(0.01)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    LineMark(
                        x: .value(
                            "时间",
                            point.date,
                            unit: usesHourlyTrend ? .hour : .day
                        ),
                        y: .value("Token", Double(point.tokens))
                    )
                    .foregroundStyle(OpenUsageColors.blue)
                    .interpolationMethod(.catmullRom)
                }
                .chartXAxis {
                    AxisMarks(values: trendAxisDates) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                if usesHourlyTrend {
                                    Text(date, format: .dateTime.hour())
                                } else {
                                    Text(date, format: .dateTime.month().day())
                                }
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel {
                            if let tokens = value.as(Double.self) {
                                Text(DisplayFormat.axisTokens(tokens))
                            }
                        }
                    }
                }
                .frame(height: 210)
            }
        }
        .padding(.vertical, 4)
    }

    private var usesHourlyTrend: Bool {
        state.usageDateRange.spansSingleDay()
    }

    private var trendPoints: [TrendPoint] {
        if usesHourlyTrend {
            return state.usage.hourly.map {
                TrendPoint(date: $0.hour, tokens: $0.tokens)
            }
        }
        return state.usage.daily.map {
            TrendPoint(date: $0.day, tokens: $0.tokens)
        }
    }

    private var trendAxisDates: [Date] {
        let dates = trendPoints.map(\.date)
        let maxCount = 5
        guard maxCount > 1, dates.count > maxCount else {
            return dates
        }

        let lastIndex = dates.count - 1
        let interval = Double(lastIndex) / Double(maxCount - 1)
        return (0..<maxCount).reduce(into: [Date]()) { result, position in
            let index = min(
                Int((Double(position) * interval).rounded()),
                lastIndex
            )
            let date = dates[index]
            if result.last != date {
                result.append(date)
            }
        }
    }

    private var quotaPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本周期额度")
                .font(.system(size: 16, weight: .semibold))
            if let traeQuota = state.traeQuota {
                traeQuotaContent(traeQuota)
            } else if let quota = state.quota {
                workBuddyQuotaContent(quota)
            } else {
                EmptyStateView(
                    systemImage: "gauge.with.dots.needle.33percent",
                    title: "额度不可用",
                    message: state.quotaMessage
                        ?? "登录 \(state.selectedProvider.title) 后刷新额度。"
                )
                .frame(height: 190)
            }
        }
        .padding(.vertical, 4)
    }

    private func workBuddyQuotaContent(_ quota: QuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            quotaGauge(
                fraction: quota.usedFraction,
                value: quota.usedFraction.formatted(
                    .percent.precision(.fractionLength(0))
                ),
                caption: "已使用"
            )
            quotaFooter(
                packageName: quota.packageName ?? "WorkBuddy",
                detail: "剩余 \(DisplayFormat.credits(quota.remaining)) Credits",
                secondaryDetail: nil,
                resetsAt: quota.resetsAt
            )
        }
    }

    private func traeQuotaContent(_ quota: TraeQuotaSummary) -> some View {
        let fraction = quota.total.map { total in
            guard total > 0 else { return 0.0 }
            return min(max(quota.used / total, 0), 1)
        }
        let unit = quotaUnitTitle(quota.unit)
        let detail = quota.remaining.map {
            "剩余 \(quotaAmount($0, unit: quota.unit)) \(unit)"
        } ?? "\(unit) 不限量"
        let payGoDetail = quota.payGoUsed > 0
            ? "按量 \(quotaAmount(quota.payGoUsed, unit: quota.unit)) \(unit)"
            : nil

        return VStack(alignment: .leading, spacing: 16) {
            quotaGauge(
                fraction: fraction,
                value: fraction?.formatted(
                    .percent.precision(.fractionLength(0))
                ) ?? "∞",
                caption: fraction == nil ? "不限量" : "已使用"
            )
            quotaFooter(
                packageName: quota.packageName,
                detail: detail,
                secondaryDetail: payGoDetail,
                resetsAt: quota.resetsAt
            )
        }
    }

    private func quotaGauge(
        fraction: Double?,
        value: String,
        caption: String
    ) -> some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.07), lineWidth: 11)
            if let fraction {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        AngularGradient(
                            colors: [
                                OpenUsageColors.blue,
                                OpenUsageColors.cyan,
                                OpenUsageColors.lime
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 11, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.8),
                        value: fraction
                    )
            }
            VStack(spacing: 3) {
                Text(value)
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 126, height: 126)
        .frame(maxWidth: .infinity)
    }

    private func quotaFooter(
        packageName: String,
        detail: String,
        secondaryDetail: String?,
        resetsAt: Date?
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(packageName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let secondaryDetail {
                    Text(secondaryDetail)
                        .font(.system(size: 10))
                        .foregroundStyle(OpenUsageColors.coral)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let resetsAt {
                Text(resetsAt, format: .dateTime.month().day())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyTrendMessage: String {
        if state.selectedProvider == .workBuddy {
            return "产生 WorkBuddy 对话后，趋势会出现在这里。"
        }
        return "刷新 \(state.selectedProvider.title) 用量后，趋势会出现在这里。"
    }

    private func quotaUnitTitle(_ unit: TraeQuotaUnit) -> String {
        switch unit {
        case .credits: return "Credits"
        case .requests: return "请求"
        }
    }

    private func quotaAmount(_ value: Double, unit: TraeQuotaUnit) -> String {
        switch unit {
        case .credits:
            return DisplayFormat.credits(value)
        case .requests:
            let fractionDigits = value.rounded() == value ? 0 : 2
            return value.formatted(
                .number.precision(.fractionLength(fractionDigits))
            )
        }
    }

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近对话")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("查看全部") {
                    state.selectedSection = .sessions
                }
                .buttonStyle(.link)
            }
            ForEach(Array(state.sessions.filter { !$0.isDeleted }.prefix(4))) { session in
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left")
                        .foregroundStyle(OpenUsageColors.blue)
                        .frame(width: 28, height: 28)
                        .background(OpenUsageColors.blue.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text("\(session.directoryName) · \(DisplayFormat.relativeDate(session.updatedAt))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                Button {
                    Task { await state.resume(session) }
                } label: {
                    Image(
                        systemName: state.sessionNeedsMigration(session)
                            ? "arrow.left.arrow.right"
                            : "arrow.up.forward.app"
                    )
                }
                .buttonStyle(.borderless)
                .help(state.resumeActionTitle(session))
                .accessibilityLabel(state.resumeActionTitle(session))
                .disabled(!state.canResume(session))
                }
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Divider()
                }
            }
        }
    }
}

/// 概览页积分统计卡片：参考 changexbc/workbuddy-switch 设计。
private struct CreditStatCard: View {
    let stat: AccountCreditStat
    /// 点击卡片图标切换账号（仅非当前账号可点）
    let onSwitchAccount: () -> Void
    /// 点击卡片刷新按钮强制刷新积分
    let onRefresh: () -> Void
    /// 即将到期预览区最多展示几条；完整列表走积分包详情
    private let nearExpiryPreviewLimit = 3
    /// 控制「积分包详情」面板
    @State private var showPackagesDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ① 顶栏：provider 图标（切换按钮）+ 账号名 + 当前标记 + 短ID + 刷新
            headerRow
            // ② 主值 + 副标题（单位 · 包数 · 更新时间）
            if let error = stat.error {
                errorBlock(error)
            } else {
                mainValueBlock
                // ③ 即将到期 TOP N 明细列表（快到期在前，始终展开）
                if !upcomingExpiryPackages.isEmpty {
                    upcomingExpirySection
                } else if !altExpiryText.isEmpty {
                    altExpiryRow
                }
                // ④ 完整积分包入口：有可列出的包时才显示
                if !listedPackages.isEmpty {
                    packageDetailButton
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(OpenUsageColors.separator, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - ① 顶栏（放大 1.5 倍）

    private var headerRow: some View {
        HStack(spacing: 8) {
            Button(action: onSwitchAccount) {
                Image(systemName: providerSystemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22, alignment: .center)
            }
            .buttonStyle(.plain)
            .disabled(stat.isCurrent)
            .help(stat.isCurrent ? "当前账号" : "切换到该账号")
            .accessibilityLabel(stat.isCurrent ? "当前账号" : "切换到该账号")
            Text(stat.accountName.isEmpty ? accountShortID : stat.accountName)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)
            if stat.isCurrent {
                Text("当前")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OpenUsageColors.lime)
            }
            Spacer(minLength: 0)
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22, alignment: .center)
            }
            .buttonStyle(.plain)
            .help("刷新全部数据和积分")
            .accessibilityLabel("刷新全部数据和积分")
            Text(accountShortID)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .layoutPriority(0)
        }
    }

    // MARK: - ② 主值 + 副标题

    @ViewBuilder
    private var mainValueBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(mainValue)
                .font(.system(size: 25, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            HStack(spacing: 0) {
                if stat.unit != .unlimited {
                    Text(unitCaption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                let pkgCount = listedPackages.count
                if pkgCount > 0 {
                    if stat.unit != .unlimited {
                        Text("   ")
                            .font(.system(size: 11))
                    }
                    Text("\(pkgCount) 个积分包")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let refresh = stat.refreshDate {
                    Text("\(Self.timeFormatter.string(from: refresh)) 更新")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func errorBlock(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("—")
                .font(.system(size: 25, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(OpenUsageColors.coral)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - ③ 即将到期区

    private var upcomingExpirySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("即将到期")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                let previews = upcomingExpiryPackages.prefix(nearExpiryPreviewLimit)
                ForEach(Array(previews.enumerated()), id: \.offset) { _, pkg in
                    upcomingExpiryRow(pkg)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
    }

    private func upcomingExpiryRow(_ pkg: CreditPackage) -> some View {
        HStack(spacing: 8) {
            Text(Self.amountText(pkg.remaining))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    pkg.expiringSoon ? OpenUsageColors.coral : .primary
                )
                .monospacedDigit()
            Text(unitLabel)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(pkg.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let date = pkg.expireAt {
                Text("\(Self.shortDateFormatter.string(from: date))到期")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(
                        pkg.expiringSoon ? OpenUsageColors.coral : .secondary
                    )
            }
        }
    }

    /// 没有即将到期包时的替代提示行
    private var altExpiryText: String {
        guard let date = stat.soonestExpireAt else {
            return stat.provider == .workBuddy ? "暂无可展示的到期" : "暂无结算日期"
        }
        let day = Self.shortDateFormatter.string(from: date)
        let prefix = stat.provider == .workBuddy ? "最近到期" : "下次结算"
        return "\(prefix) \(day)"
    }

    @ViewBuilder
    private var altExpiryRow: some View {
        HStack {
            Text(altExpiryText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - ④ 积分包详情入口

    /// 最后一行：点击打开「积分包列表详情」悬浮窗（popover 锚定本按钮行）。
    private var packageDetailButton: some View {
        Button {
            showPackagesDetail = true
        } label: {
            HStack(spacing: 4) {
                Text("查看全部积分包")
                    .font(.system(size: 11, weight: .medium))
                Text("（\(listedPackages.count)）")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("打开积分包列表详情")
        .accessibilityLabel("打开积分包列表详情")
        .popover(isPresented: $showPackagesDetail, arrowEdge: .top) {
            PackageListDetailView(
                accountName: stat.accountName.isEmpty ? accountShortID : stat.accountName,
                packages: CreditPackageOrdering.sorted(listedPackages)
            )
        }
    }

    // MARK: - 计算属性

    /// 即将到期包列表：与「查看全部积分包」同一套顺序的前段（剩余>0、未过期、有到期日）
    private var upcomingExpiryPackages: [CreditPackage] {
        CreditPackageOrdering.upcoming(stat.packages)
    }

    /// 可列出的积分包：排除「有限且已用尽」的包；不限量包（remaining 天然为 0）仍列出
    private var listedPackages: [CreditPackage] {
        stat.packages.filter(\.isListable)
    }

    private var accountShortID: String {
        let id = stat.accountID
        guard id.count > 12 else { return id }
        return "\(id.prefix(7))...\(id.suffix(4))"
    }

    private var unitCaption: String {
        switch stat.unit {
        case .credits: return "总积分"
        case .requests: return "总请求"
        case .unlimited: return ""
        }
    }

    private var unitLabel: String {
        switch stat.unit {
        case .credits: return "积分"
        case .requests: return "请求"
        case .unlimited: return ""
        }
    }

    private var providerSystemImage: String {
        stat.provider.systemImage
    }

    private var tint: Color {
        switch stat.provider {
        case .workBuddy: return OpenUsageColors.blue
        case .traeCN: return OpenUsageColors.coral
        case .traeWork: return OpenUsageColors.cyan
        }
    }

    private var mainValue: String {
        switch stat.unit {
        case .credits:
            return stat.totalRemaining.map(DisplayFormat.credits) ?? "—"
        case .requests:
            guard let value = stat.totalRemaining else { return "—" }
            return value.rounded() == value
                ? String(Int(value))
                : DisplayFormat.credits(value)
        case .unlimited:
            return "不限量"
        }
    }

    static func amountText(_ value: Double) -> String {
        value.rounded() == value
            ? String(Int(value))
            : DisplayFormat.credits(value)
    }

    static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// 单个积分/权益包明细行（名称 + 剩余/总量 + 进度条 + 到期/已用）。
private struct CreditPackageRow: View {
    let pkg: CreditPackage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(pkg.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if pkg.isUnlimited {
                    Text("不限量")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(CreditStatCard.amountText(pkg.remaining)) / \(CreditStatCard.amountText(pkg.total ?? 0))")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(
                            pkg.expired
                                ? OpenUsageColors.coral
                                : (pkg.expiringSoon ? OpenUsageColors.coral : OpenUsageColors.blue)
                        )
                        .frame(width: proxy.size.width * ratio)
                }
            }
            .frame(height: 4)
            Text(detailLine)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var ratio: Double {
        guard let total = pkg.total, total > 0 else { return pkg.isUnlimited ? 1 : 0 }
        return min(max(pkg.remaining / total, 0), 1)
    }

    private var detailLine: String {
        var parts: [String] = []
        if pkg.expired {
            parts.append("已到期")
        } else if let date = pkg.expireAt {
            // 先显示具体到期时间；7 天内到期作为附加提示
            parts.append("到期 \(CreditStatCard.shortDateFormatter.string(from: date))")
            if pkg.expiringSoon {
                parts.append("7 天内到期")
            }
        } else {
            parts.append("暂无到期")
        }
        parts.append("已用 \(CreditStatCard.amountText(pkg.used))")
        return parts.joined(separator: " · ")
    }
}

/// 积分包列表详情悬浮窗（popover）：点击卡片「查看全部积分包」打开，展示完整包明细。
private struct PackageListDetailView: View {
    let accountName: String
    let packages: [CreditPackage]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("积分包列表")
                    .font(.system(size: 15, weight: .semibold))
                Text(accountName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 24, height: 24, alignment: .center)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("关闭")
                .accessibilityLabel("关闭")
            }
            .padding(.bottom, 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(packages.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 0) {
                            CreditPackageRow(pkg: packages[index])
                            if index < packages.count - 1 {
                                Divider()
                                    .padding(.top, 10)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(OpenUsageColors.separator, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(16)
        .frame(width: 420, height: 480)
    }
}
