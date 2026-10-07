import AppKit
import SwiftUI

@MainActor struct CodexUsageView: View {
    @ViewState private var store = CodexUsageStore.shared
    @ViewState private var showsModels = false
    @ViewState private var expandedModel: String?
    @ViewState private var modelScrollAnchor: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var modelAnimation

    private var focusedModel: CodexModelUsage? {
        store.models.first { $0.id == expandedModel }
    }

    init(store: CodexUsageStore? = nil, showsModels: Bool = false, expandedModel: String? = nil) {
        _store = ViewState(initialValue: store ?? .shared)
        _showsModels = ViewState(initialValue: showsModels)
        _expandedModel = ViewState(initialValue: expandedModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    if showsModels, let model = focusedModel {
                        CodexModelDetail(model: model, namespace: modelAnimation)
                            .transition(.opacity)
                    } else if showsModels { models }
                    else { overview(now: context.date) }
                    footer(now: context.date)
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 3)
        .frame(height: 238, alignment: .top)
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .task(id: store.home) { await store.monitor() }
        .onChange(of: store.period) { _, _ in
            if let id = expandedModel, !store.models.contains(where: { $0.id == id }) {
                expandedModel = nil
            }
            modelScrollAnchor = nil
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if showsModels {
                Button(action: goBack) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
                        Text("Models").font(.system(size: 15, weight: .semibold))
                    }
                    .frame(height: 28).contentShape(Rectangle())
                }
                .accessibilityLabel(focusedModel == nil ? "Models. Back to Codex allowance" : "Back to model list")
                .help(focusedModel == nil ? "Back to allowance" : "Back to models")
            } else {
                Text("Codex").font(.system(size: 15, weight: .semibold))
                if let plan = store.quota?.plan {
                    Text(plan.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 8)
            if showsModels { periodPicker }
            if store.isRefreshing || store.isScanning {
                ProgressView().controlSize(.mini).tint(.white).frame(width: 20)
                    .accessibilityLabel("Refreshing Codex usage")
            }
            Menu {
                Button("Refresh usage", systemImage: "arrow.clockwise") {
                    Task { await store.refresh(force: true) }
                }
                .disabled(store.isRefreshing || store.isScanning)
                Divider()
                Button("Codex usage dashboard", systemImage: "arrow.up.right") { openDashboard() }
                Button("OpenAI API usage", systemImage: "chart.bar") { open("https://platform.openai.com/usage") }
                Button("OpenAI API pricing", systemImage: "dollarsign") { NSWorkspace.shared.open(CodexRateCatalog.sourceURL) }
                if let date = store.pricingUpdatedAt {
                    Text("Rates checked \(date.formatted(date: .abbreviated, time: .omitted))")
                }
                Divider()
                Button("Choose Codex folder…", systemImage: "folder") { chooseFolder() }
                Button("Show session files in Finder", systemImage: "folder.badge.gearshape") { NSWorkspace.shared.open(store.home) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65)).frame(width: 24, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Codex options").help("Refresh, dashboards, pricing, and data source")
        }
        .frame(height: 28)
    }

    @ViewBuilder private func overview(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let quota = store.quota {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.vertical) {
                        if quota.windows.isEmpty {
                            Text("No fixed allowance window reported.")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                                .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(quota.windows) { window in
                                    CodexQuotaLane(window: window, now: now, recorded: quota.isLocal)
                                }
                            }
                        }
                    }
                    .frame(height: 84)
                    HStack(spacing: 8) {
                        if let count = quota.resetCount, count > 0 {
                            Button("\(count) reset\(count == 1 ? "" : "s") available", action: openDashboard)
                                .foregroundStyle(.white.opacity(0.8))
                                .help(resetCreditHelp(quota))
                        } else if quota.resetCount == 0 {
                            Text("No resets available").foregroundStyle(.white.opacity(0.6))
                        } else {
                            Button("Reset status unavailable", action: openDashboard)
                                .foregroundStyle(.white.opacity(0.65))
                                .help("Reset availability couldn’t be read. Check the Codex dashboard.")
                        }
                        Spacer()
                        if let expiry = quota.resetCredits.first?.expiresAt {
                            Text("Expires \(expiry.formatted(.dateTime.month(.abbreviated).day()))")
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        if quota.unlimitedCredits {
                            Text("Unlimited credits").foregroundStyle(.white.opacity(0.65))
                        } else if let balance = quota.credits, let number = Double(balance), number > 0 {
                            Text("\(number.formatted(.number.precision(.fractionLength(0...2)))) credits")
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    .font(.system(size: 10)).frame(height: 14)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.isRefreshing ? "Reading your allowance…" : "Connect your Codex session")
                        .font(.system(size: 13, weight: .medium))
                    Text(store.quotaError ?? "Uses your Codex CLI sign-in. Token history stays on this Mac.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true).lineLimit(3)
                    if !store.isRefreshing {
                        HStack(spacing: 14) {
                            Button("Choose folder…", action: chooseFolder)
                            Button("Open dashboard", action: openDashboard)
                        }.font(.system(size: 11, weight: .medium))
                    }
                }
                .frame(height: 96, alignment: .top)
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    periodPicker
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(store.isScanning && store.localUpdatedAt == nil ? "…" : CodexTokenTotals.compact(store.total.total))
                            .font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text("tokens").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    }
                    .help("\(store.total.total.formatted()) local tokens · \(store.fileCount) session files")
                }
                Spacer()
                Button { selectModels(true) } label: {
                    HStack(spacing: 8) {
                        Text("\(store.models.count) model\(store.models.count == 1 ? "" : "s")")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    .frame(height: 28).contentShape(Rectangle())
                }
                .accessibilityLabel("View model usage and API pricing")
            }
            .frame(height: 54)
        }
        .frame(height: 172, alignment: .top)
        .transition(.opacity)
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Spacer()
                Text("Tokens").frame(width: 64, alignment: .trailing)
                Text("API estimate").frame(width: 76, alignment: .trailing)
                Color.clear.frame(width: 8, height: 1)
            }
            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            .help("Estimated USD cost at current Standard short-context API rates, not your subscription bill. Fast mode, long context and tools can differ.")
            ScrollViewReader { proxy in
              ScrollView {
                LazyVStack(spacing: 2) {
                    if store.models.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(store.isScanning ? "Reading local sessions…" : "No tokens recorded in this period.")
                                .font(.system(size: 12, weight: .medium))
                            Text("Choose a longer period or check your Codex folder.")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                        }
                        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                    }
                    ForEach(store.models) { model in
                        CodexModelRow(model: model, namespace: modelAnimation) {
                            withAnimation(reduceMotion ? nil : StandardAnimations.focusTab) {
                                modelScrollAnchor = model.id
                                expandedModel = model.id
                            }
                        }
                    }
                }
              }
              .scrollIndicators(.never)
              .onAppear {
                  if let id = modelScrollAnchor { proxy.scrollTo(id, anchor: .center) }
              }
            }
        }
        .frame(height: 172)
        .transition(.asymmetric(
            insertion: .opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.2)),
            removal: .opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.1))
        ))
    }

    private var periodPicker: some View {
        Menu {
            ForEach(CodexUsagePeriod.allCases) { period in
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { store.period = period }
                } label: {
                    if store.period == period {
                        Label(period.rawValue, systemImage: "checkmark")
                    } else {
                        Text(period.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(store.period.rawValue).font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.7)).frame(height: 20)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Usage period: \(store.period.rawValue)")
    }

    private func footer(now: Date) -> some View {
        HStack(spacing: 5) {
            Text(status(now: now)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if showsModels {
                Button { NSWorkspace.shared.open(CodexRateCatalog.sourceURL) } label: {
                    Image(systemName: "info.circle").font(.system(size: 10))
                }
                .accessibilityLabel("About API estimates. Open official pricing")
                .help("API estimates use current Standard short-context rates. Rates fetched \(store.pricingUpdatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "not yet"). Token history is local; this is not your bill. Open official pricing.")
            }
        }
        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
        .frame(height: 12)
        .help([store.quotaError, store.localError, store.pricingError,
               "Session data: \(store.home.path). Local totals include clients writing to this folder. Cloud-only tokens are not included."].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityLabel([status(now: now), store.quotaError, store.localError, store.pricingError].compactMap { $0 }.joined(separator: ". "))
    }

    private func status(now: Date) -> String {
        if let error = store.localError { return error }
        if let quota = store.quota {
            let age = max(0, Int(now.timeIntervalSince(quota.updatedAt) / 60))
            let time = age < 1 ? "just now" : age < 60 ? "\(age)m ago" : "\(age / 60)h ago"
            if quota.isLocal {
                return store.isRefreshing ? "Local reading · refreshing…" : "Local reading · \(time) · refresh unavailable"
            }
            if store.quotaError != nil || age >= 2 { return "Last reading \(time) · refresh needed" }
            if let error = store.pricingError { return error }
            return "Updated \(time)"
        }
        if store.isRefreshing { return "Reading live allowance…" }
        return store.isScanning ? "Reading token history…" : "Local tokens · account limits unavailable"
    }

    private func selectModels(_ value: Bool) {
        withAnimation(reduceMotion ? nil : StandardAnimations.focusTab) {
            expandedModel = nil
            showsModels = value
        }
    }

    private func goBack() {
        withAnimation(reduceMotion ? nil : StandardAnimations.focusTab) {
            if let model = focusedModel {
                modelScrollAnchor = model.id
                expandedModel = nil
            } else {
                showsModels = false
            }
        }
    }

    private func resetCreditHelp(_ quota: CodexQuotaSnapshot) -> String {
        let details = quota.resetCredits.map { credit in
            credit.title + (credit.expiresAt.map { " · expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
        }
        return (["View and redeem available resets in the Codex usage dashboard."] + details).joined(separator: "\n")
    }

    private func open(_ url: String) { if let url = URL(string: url) { NSWorkspace.shared.open(url) } }
    private func openDashboard() { open("https://chatgpt.com/codex/settings/usage") }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose your Codex folder"
        panel.message = "Select the folder containing auth.json and sessions (usually ~/.codex)."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true; panel.directoryURL = store.home
        SharingStateManager.shared.beginInteraction()
        panel.begin { response in
            Task { @MainActor in
                SharingStateManager.shared.endInteraction()
                if response == .OK, let url = panel.url { store.selectHome(url) }
            }
        }
    }
}
