import SwiftUI

struct CaffeineSetupView: View {
    @ObservedObject private var settings = CaffeineSettings.shared
    @ObservedObject private var selection = FocusSessionManager.shared.selection
    @ObservedObject private var manager = FocusSessionManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var search = ""
    @ViewState private var showOptions = false
    @ViewState private var showOtherApps = false
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    private var matchingApps: [CaffeineAppChoice] {
        settings.apps.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showOptions {
                HStack(spacing: 10) {
                    Button("Back to apps", systemImage: "chevron.left") { switchOptions(false) }
                        .labelStyle(.iconOnly).font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                        .frame(width: 28, height: 28).modifier(FocusControlSurface())
                    Text("Session settings").font(.system(size: 18, weight: .semibold))
                    Spacer()
                }
                CaffeineOptionsView(settings: settings).frame(height: 237, alignment: .top)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Choose what stays awake").font(.system(size: 19, weight: .semibold))
                        Spacer()
                        Button("Caffeine settings", systemImage: "slider.horizontal.3") { switchOptions(true) }
                            .labelStyle(.iconOnly).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                            .frame(width: 29, height: 29).modifier(FocusControlSurface()).help("Caffeine settings")
                    }
                    Text("Checked apps keep working when you close the lid.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                }
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.55)).accessibilityHidden(true)
                    CaffeineSearchField(text: $search)
                        .transaction { $0.animation = nil }
                        .frame(height: 18)
                    if !search.isEmpty {
                        Button("Clear search", systemImage: "xmark.circle.fill") { search = "" }
                            .labelStyle(.iconOnly).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 10).frame(height: 28).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(search.isEmpty ? "Running now" : "Search results").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                            Spacer()
                            if search.isEmpty {
                                Button("Select all", action: settings.keepAllRunning).font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                            }
                        }
                        LazyVGrid(columns: columns, spacing: 7) {
                            ForEach(matchingApps.filter { $0.running || !search.isEmpty }) { app in
                                CaffeineAppRow(app: app, selected: settings.isKept(app)) { settings.toggle(app) }
                            }
                        }
                        if search.isEmpty {
                            Button { toggleOtherApps() } label: {
                                HStack {
                                    Text(showOtherApps ? "Other apps" : "Choose from other apps")
                                    Spacer()
                                    Image(systemName: showOtherApps ? "chevron.up" : "chevron.down")
                                }
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7)).padding(.vertical, 7)
                            }
                            if showOtherApps {
                                LazyVGrid(columns: columns, spacing: 7) {
                                    ForEach(matchingApps.filter { !$0.running }) { app in
                                        CaffeineAppRow(app: app, selected: settings.isKept(app)) { settings.toggle(app) }
                                    }
                                }
                            }
                        }
                        if matchingApps.isEmpty {
                            Text(settings.loading ? "Finding your apps…" : "No apps found. Try another name.")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).padding(.vertical, 25)
                        }
                    }.padding(.trailing, 3)
                }
                .frame(height: 168).scrollIndicators(.visible)
            }
            HStack(spacing: 12) {
                Text("\(settings.keptCount) apps selected").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 0)
                Button(action: continueToTime) {
                    Label(manager.isActive ? "Done" : "Continue", systemImage: manager.isActive ? "checkmark" : "arrow.right")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                        .padding(.horizontal, 17).frame(height: 32).modifier(FocusControlSurface(accent: true))
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .frame(maxWidth: 500).onAppear(perform: settings.refresh).buttonStyle(.plain)
    }
    private func switchOptions(_ options: Bool) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { showOptions = options }
    }
    private func toggleOtherApps() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { showOtherApps.toggle() }
    }
    private func continueToTime() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.9)) {
            selection.completeCaffeineSetup()
        }
        FocusHaptics.action()
    }
}
