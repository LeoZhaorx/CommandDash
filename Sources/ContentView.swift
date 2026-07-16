import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.controlActiveState) private var controlActiveState

    @State private var isDropTargeted: Bool = false
    @State private var selectedCategory: String = AppState.allTabName
    @State private var isLogExpanded: Bool = false
    @State private var showingAddTabSheet: Bool = false
    @State private var newTabName: String = ""
    @State private var addTabErrorText: String?
    @State private var tabPendingDelete: String?
    @State private var showingDeleteTabConfirmation: Bool = false
    @State private var renameTarget: CommandItem?
    @State private var renameDraft: String = ""
    @State private var iconEditTarget: CommandItem?
    @State private var emojiDraft: String = ""
    @State private var gradientDraftID: String = CommandIconGradientPreset.default.id
    @State private var hoveredTab: String?
    @State private var tabHoverSwitchWorkItem: DispatchWorkItem?
    @State private var isMainWindowKey: Bool = true
    @State private var showingRunningCommands: Bool = false
    @State private var didEnterRunningZone: Bool = false

    @Namespace private var tabSelectionNamespace

    private let acceptedDropTypes: [UTType] = [.fileURL, .url, .item, .data, .text, .plainText, .utf8PlainText]
    private let runningPollTimer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()
    private let gridColumns = [
        GridItem(.adaptive(minimum: 116, maximum: 130), spacing: 20, alignment: .top)
    ]

    private var isWindowActive: Bool {
        isMainWindowKey || controlActiveState != .inactive
    }

    private var panelOuterShadowPrimaryColor: Color {
        Color.black.opacity(isWindowActive ? 0.18 : 0.08)
    }

    private var panelOuterShadowSecondaryColor: Color {
        Color.black.opacity(isWindowActive ? 0.07 : 0.03)
    }

    private var tabsWithAll: [String] {
        [AppState.allTabName] + appState.tabs
    }

    private var canDropIntoCurrentTab: Bool {
        selectedCategory != AppState.allTabName
    }

    private var visibleCommands: [CommandItem] {
        var list = appState.commands

        if selectedCategory != AppState.allTabName {
            list = list.filter { $0.category == selectedCategory }
        }

        list.sort { lhs, rhs in
            if lhs.id == appState.lastRunCommandID { return true }
            if rhs.id == appState.lastRunCommandID { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return list
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            HStack(spacing: 18) {
                leftPanel
                rightLogPanel
            }
            .padding(34)
        }
        .frame(width: 1320, height: 760)
        .contentShape(Rectangle())
        .onDrop(of: acceptedDropTypes, isTargeted: nil) { providers in
            guard canDropIntoCurrentTab else { return false }
            return handleDrop(providers: providers)
        }
        .onAppear {
            syncSelectedTabOnLaunch()
            appState.refreshRunningCommands()
        }
        .onChange(of: selectedCategory) { newValue in
            appState.rememberSelectedTab(newValue)
        }
        .onChange(of: appState.tabs) { _ in
            syncSelectedTabAfterTabChanges()
        }
        .onChange(of: appState.isRunning) { running in
            guard running else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                isLogExpanded = true
            }
        }
        .onDisappear {
            tabHoverSwitchWorkItem?.cancel()
            tabHoverSwitchWorkItem = nil
        }
        .onReceive(runningPollTimer) { _ in
            appState.refreshRunningCommands()
        }
        .animation(.easeInOut(duration: 0.24), value: isLogExpanded)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow, window.level == .normal else { return }
            isMainWindowKey = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard let window = note.object as? NSWindow, window.level == .normal else { return }
            isMainWindowKey = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isMainWindowKey = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            isMainWindowKey = false
        }
        .sheet(isPresented: $showingAddTabSheet) {
            AddTabSheet(
                tabName: $newTabName,
                errorText: addTabErrorText,
                onCancel: {
                    newTabName = ""
                    addTabErrorText = nil
                    showingAddTabSheet = false
                },
                onConfirm: {
                    createTab()
                }
            )
        }
        .sheet(item: $renameTarget) { command in
            RenameCommandSheet(
                commandName: command.name,
                draftName: $renameDraft,
                onCancel: {
                    renameTarget = nil
                },
                onConfirm: {
                    confirmRename(commandID: command.id)
                }
            )
        }
        .sheet(item: $iconEditTarget) { command in
            CommandIconEditorSheet(
                commandName: command.name,
                emojiDraft: $emojiDraft,
                selectedGradientID: $gradientDraftID,
                onOpenEmojiPicker: {
                    NSApp.orderFrontCharacterPalette(nil)
                },
                onCancel: {
                    iconEditTarget = nil
                },
                onConfirm: {
                    confirmIconEdit(commandID: command.id)
                }
            )
        }
        .alert("确认删除 Tab？", isPresented: $showingDeleteTabConfirmation, presenting: tabPendingDelete) { tabName in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                deleteTab(tabName)
            }
        } message: { tabName in
            Text("将删除「\(tabName)」及其全部 command，此操作不可恢复。")
        }
    }

    private var leftPanel: some View {
        VStack(spacing: 14) {
            topSearchBar
            commandZone
            tabBar
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(isWindowActive ? Color.white.opacity(0.54) : Color.white.opacity(0.34), lineWidth: 1.0)

                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(isWindowActive ? Color.black.opacity(0.1) : Color.black.opacity(0.06), lineWidth: 0.7)
            }
        )
        .compositingGroup()
        .shadow(color: panelOuterShadowPrimaryColor, radius: isWindowActive ? 14 : 10, x: 0, y: isWindowActive ? 5 : 3)
        .shadow(color: panelOuterShadowSecondaryColor, radius: isWindowActive ? 28 : 20, x: 0, y: isWindowActive ? 11 : 7)
        .onDrop(of: acceptedDropTypes, isTargeted: $isDropTargeted) { providers in
            guard canDropIntoCurrentTab else { return false }
            return handleDrop(providers: providers)
        }
        .dropDestination(for: URL.self, action: { urls, _ in
            guard canDropIntoCurrentTab else { return false }
            return handleDroppedURLs(urls)
        }, isTargeted: { targeted in
            isDropTargeted = canDropIntoCurrentTab && targeted
        })
        .contextMenu {
            Button("清空所有命令", role: .destructive) {
                appState.clearCommands()
            }
        }
    }

    private var topSearchBar: some View {
        HStack(spacing: 10) {
            Button {
                toggleRunningCommandsPanel()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 12, weight: .semibold))
                    Text("运行中 \(appState.runningCommands.count)")
                        .font(Theme.captionFont.weight(.semibold))
                }
                .foregroundColor(showingRunningCommands ? Theme.appleBlue : Theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(showingRunningCommands ? Theme.appleBlue.opacity(0.15) : Theme.white.opacity(0.62))
                )
            }
            .buttonStyle(.plain)
            .help("点击查看正在运行的 command")

            Spacer(minLength: 0)
            Button {
                withAnimation(.easeInOut(duration: 0.24)) {
                    isLogExpanded.toggle()
                }
            } label: {
                Image(systemName: isLogExpanded ? "arrow.right.to.line" : "arrow.left.to.line")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(LogToggleButtonStyle(isExpanded: isLogExpanded))
        }
        .frame(height: 28)
    }

    private var commandZone: some View {
        ZStack {
            if showingRunningCommands {
                runningCommandsPanel
            } else if visibleCommands.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 22) {
                        ForEach(visibleCommands) { command in
                            CommandTile(
                                command: command,
                                isLastRun: command.id == appState.lastRunCommandID,
                                onRun: { appState.run(command: command) },
                                onReveal: { revealInFinder(command: command) },
                                onRename: { beginRename(command) },
                                onEditIcon: { beginIconEdit(command) },
                                onDelete: { appState.removeCommand(commandID: command.id) }
                            )
                            .help(command.command)
                        }
                    }
                    .padding(.vertical, 18)
                    .padding(.horizontal, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.001))
        .onHover { hovering in
            guard showingRunningCommands else { return }

            if hovering {
                didEnterRunningZone = true
            } else if didEnterRunningZone {
                withAnimation(.easeOut(duration: 0.18)) {
                    showingRunningCommands = false
                }
                didEnterRunningZone = false
            }
        }
        .overlay {
            if !showingRunningCommands && canDropIntoCurrentTab && isDropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.appleBlue.opacity(0.82), style: StrokeStyle(lineWidth: 1.5, dash: [7]))
                    .overlay(alignment: .topLeading) {
                        Text("拖到这里添加")
                            .font(Theme.microFont.weight(.semibold))
                            .foregroundColor(Theme.appleBlue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Theme.white.opacity(0.82))
                            )
                            .padding(10)
                    }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 30, weight: .regular))
                .foregroundColor(Theme.quaternaryText)

            if selectedCategory == AppState.allTabName {
                Text("请选择/创建一个 tab后，拖入 command")
                    .font(Theme.headingFont)
                    .foregroundColor(Theme.nearBlack)
                    .kerning(-0.2)
                Text("ALL 仅用于查看汇总，不允许新增")
                    .font(Theme.bodyFont)
                    .foregroundColor(Theme.secondaryText)
                    .kerning(-0.3)
            } else {
                Text("拖入你的 .command 文件")
                    .font(Theme.headingFont)
                    .foregroundColor(Theme.nearBlack)
                    .kerning(-0.2)
                Text("拖进来即可显示并可点击启动")
                    .font(Theme.bodyFont)
                    .foregroundColor(Theme.secondaryText)
                    .kerning(-0.3)
            }
        }
    }

    private var runningCommandsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("正在运行的 command")
                    .font(Theme.bodyFont.weight(.semibold))
                    .foregroundColor(Theme.nearBlack)

                Spacer(minLength: 0)

                Text("\(appState.runningCommands.count) 个")
                    .font(Theme.microFont)
                    .foregroundColor(Theme.tertiaryText)

                Button {
                    appState.refreshRunningCommands(showLoading: true)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: appState.isRefreshingRunningCommands ? "arrow.clockwise.circle.fill" : "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text(appState.isRefreshingRunningCommands ? "刷新中" : "刷新")
                            .font(Theme.microFont.weight(.semibold))
                    }
                    .foregroundColor(Theme.secondaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.66))
                    )
                }
                .buttonStyle(.plain)
                .disabled(appState.isRefreshingRunningCommands || appState.isStoppingAllCommands)
                .opacity((appState.isRefreshingRunningCommands || appState.isStoppingAllCommands) ? 0.6 : 1)

                Button(appState.isStoppingAllCommands ? "停止中…" : "一键停止") {
                    appState.stopAllRunningCommands()
                }
                .buttonStyle(.plain)
                .font(Theme.microFont.weight(.semibold))
                .foregroundColor(Color.red.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.66))
                )
                .disabled(appState.runningCommands.isEmpty || appState.isStoppingAllCommands)
                .opacity((appState.runningCommands.isEmpty || appState.isStoppingAllCommands) ? 0.45 : 1)
            }

            if appState.runningCommands.isEmpty {
                Text("当前没有检测到运行中的 command")
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.secondaryText)
                    .padding(.top, 6)
            } else {
                HStack(spacing: 10) {
                    Text("命令名")
                        .font(Theme.microFont.weight(.semibold))
                        .foregroundColor(Theme.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("来源")
                        .font(Theme.microFont.weight(.semibold))
                        .foregroundColor(Theme.tertiaryText)
                        .frame(width: 78, alignment: .center)

                    Text("PID")
                        .font(Theme.microFont.weight(.semibold))
                        .foregroundColor(Theme.tertiaryText)
                        .frame(width: 70, alignment: .trailing)

                    Text("端口")
                        .font(Theme.microFont.weight(.semibold))
                        .foregroundColor(Theme.tertiaryText)
                        .frame(width: 96, alignment: .leading)

                    Text("运行时长")
                        .font(Theme.microFont.weight(.semibold))
                        .foregroundColor(Theme.tertiaryText)
                        .frame(width: 82, alignment: .trailing)

                    Text("操作")
                        .font(Theme.microFont.weight(.semibold))
                        .foregroundColor(Theme.tertiaryText)
                        .frame(width: 62, alignment: .center)
                }
                .padding(.horizontal, 10)

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(appState.runningCommands) { record in
                            runningCommandRow(record)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func runningCommandRow(_ record: RunningCommandRecord) -> some View {
        HStack(spacing: 10) {
            Text(record.commandName)
                .font(Theme.captionFont)
                .foregroundColor(Theme.nearBlack)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(record.sourceTag)
                .font(Theme.microFont.weight(.semibold))
                .foregroundColor(Theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Theme.white.opacity(0.68))
                )
                .frame(width: 78, alignment: .center)

            Text("\(record.pid)")
                .font(Theme.monoFont)
                .foregroundColor(Theme.secondaryText)
                .frame(width: 70, alignment: .trailing)

            Text(portsText(for: record))
                .font(Theme.monoFont)
                .foregroundColor(Theme.secondaryText)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)

            Text(record.uptime)
                .font(Theme.monoFont)
                .foregroundColor(Theme.secondaryText)
                .frame(width: 82, alignment: .trailing)

            if appState.stoppingCommandIDs.contains(record.commandID) {
                Text("停止中…")
                    .font(Theme.microFont.weight(.semibold))
                    .foregroundColor(Theme.secondaryText)
                    .frame(width: 62, alignment: .center)
            } else {
                Button("停止") {
                    appState.stopRunningCommand(record)
                }
                .buttonStyle(.plain)
                .font(Theme.microFont.weight(.semibold))
                .foregroundColor(Color.red.opacity(0.9))
                .frame(width: 62, alignment: .center)
                .disabled(appState.isStoppingAllCommands)
                .opacity(appState.isStoppingAllCommands ? 0.45 : 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.white.opacity(0.56))
        )
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(tabsWithAll, id: \.self) { category in
                HStack(spacing: 6) {
                    Text(category)
                        .font(Theme.captionFont)
                        .foregroundColor(Theme.nearBlack)
                        .fontWeight(selectedCategory == category ? .semibold : .regular)
                    Text("\(count(for: category))")
                        .font(Theme.microFont)
                        .foregroundColor(Theme.tertiaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    ZStack {
                        if selectedCategory == category {
                            Capsule(style: .continuous)
                                .fill(Theme.appleBlue.opacity(0.16))
                                .matchedGeometryEffect(id: "tab-selection-pill", in: tabSelectionNamespace)
                        } else if hoveredTab == category {
                            Capsule(style: .continuous)
                                .fill(Theme.appleBlue.opacity(0.07))
                        }
                    }
                )
                .contentShape(Capsule(style: .continuous))
                .onHover { hovering in
                    if hovering {
                        hoveredTab = category
                        scheduleHoverSwitch(to: category)
                    } else if hoveredTab == category {
                        hoveredTab = nil
                        tabHoverSwitchWorkItem?.cancel()
                    }
                }
                .contextMenu {
                    if category != AppState.allTabName {
                        Button("删除 Tab…", role: .destructive) {
                            requestDeleteTab(category)
                        }
                    }
                }
            }

            Button {
                showingAddTabSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .background(
                Circle()
                    .fill(Theme.white.opacity(0.6))
            )
            .help("新增 Tab")

            Spacer(minLength: 0)

            Text("Design By Leo")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.secondaryText.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Theme.white.opacity(0.45))
                )
        }
        .animation(.interactiveSpring(response: 0.26, dampingFraction: 0.86), value: selectedCategory)
        .animation(.easeOut(duration: 0.18), value: hoveredTab)
    }

    private var rightLogPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(isWindowActive ? Color.white.opacity(0.54) : Color.white.opacity(0.34), lineWidth: 1.0)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(isWindowActive ? Color.black.opacity(0.1) : Color.black.opacity(0.06), lineWidth: 0.7)
                }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("运行日志")
                        .font(Theme.bodyFont.weight(.semibold))
                        .foregroundColor(Theme.nearBlack)

                    Spacer(minLength: 0)

                    Button("清空") {
                        appState.clearConsole()
                    }
                    .buttonStyle(LogCapsuleButtonStyle())
                }

                ScrollView {
                    Text(appState.consoleText.isEmpty ? "暂无日志" : appState.consoleText)
                        .font(Theme.monoFont)
                        .foregroundColor(Theme.nearBlack.opacity(0.86))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(16)
        }
        .frame(width: 312)
        .compositingGroup()
        .shadow(color: panelOuterShadowPrimaryColor, radius: isWindowActive ? 13 : 9, x: 0, y: isWindowActive ? 5 : 3)
        .shadow(color: panelOuterShadowSecondaryColor, radius: isWindowActive ? 26 : 18, x: 0, y: isWindowActive ? 10 : 6)
        .opacity(isLogExpanded ? 1 : 0)
        .allowsHitTesting(isLogExpanded)
        .contextMenu {
            Button("清空日志") {
                appState.clearConsole()
            }
        }
    }

    private func scheduleHoverSwitch(to category: String) {
        tabHoverSwitchWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            guard hoveredTab == category else { return }
            guard selectedCategory != category else { return }
            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.86)) {
                selectedCategory = category
            }
        }

        tabHoverSwitchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func syncSelectedTabOnLaunch() {
        let preferred = appState.preferredTabForLaunch()
        if preferred == AppState.allTabName, let first = appState.tabs.first {
            selectedCategory = first
            appState.rememberSelectedTab(first)
            return
        }
        selectedCategory = preferred
    }

    private func syncSelectedTabAfterTabChanges() {
        if selectedCategory == AppState.allTabName { return }
        guard !appState.tabs.contains(selectedCategory) else { return }

        if let first = appState.tabs.first {
            selectedCategory = first
            appState.rememberSelectedTab(first)
        } else {
            selectedCategory = AppState.allTabName
        }
    }

    private func createTab() {
        guard let tab = appState.addTab(name: newTabName) else {
            addTabErrorText = "Tab 名称不能为空，且不能是 ALL"
            return
        }

        newTabName = ""
        addTabErrorText = nil
        showingAddTabSheet = false
        selectedCategory = tab
        appState.rememberSelectedTab(tab)
    }

    private func requestDeleteTab(_ tab: String) {
        guard tab != AppState.allTabName else { return }
        tabPendingDelete = tab
        showingDeleteTabConfirmation = true
    }

    private func beginRename(_ command: CommandItem) {
        renameDraft = command.name
        renameTarget = command
    }

    private func confirmRename(commandID: UUID) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appState.renameCommand(commandID: commandID, newName: trimmed)
        renameTarget = nil
    }

    private func beginIconEdit(_ command: CommandItem) {
        emojiDraft = command.iconEmoji ?? ""
        gradientDraftID = CommandIconGradientPreset.byID(command.iconGradientID).id
        iconEditTarget = command
    }

    private func confirmIconEdit(commandID: UUID) {
        let normalizedEmoji = normalizeEmoji(emojiDraft)
        appState.updateCommandIcon(
            commandID: commandID,
            emoji: normalizedEmoji,
            gradientID: gradientDraftID
        )
        iconEditTarget = nil
    }

    private func normalizeEmoji(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        return String(first)
    }

    private func deleteTab(_ tab: String) {
        appState.removeTab(name: tab)
        if let first = appState.tabs.first {
            selectedCategory = first
            appState.rememberSelectedTab(first)
        } else {
            selectedCategory = AppState.allTabName
        }
    }

    private func count(for category: String) -> Int {
        if category == AppState.allTabName {
            return appState.commands.count
        }
        return appState.commands.filter { $0.category == category }.count
    }

    private func toggleRunningCommandsPanel() {
        appState.refreshRunningCommands()
        didEnterRunningZone = false
        withAnimation(.easeInOut(duration: 0.2)) {
            showingRunningCommands.toggle()
        }
    }

    private func portsText(for record: RunningCommandRecord) -> String {
        guard !record.ports.isEmpty else { return "-" }
        return record.ports.map(String.init).joined(separator: ",")
    }

    private func launchFirstVisibleCommand() {
        guard let first = visibleCommands.first else { return }
        appState.run(command: first)
    }

    private func revealInFinder(command: CommandItem) {
        guard command.kind == .file else { return }
        let url = URL(fileURLWithPath: command.command)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func parseSearch(_ text: String) -> (keyword: String, pathOnly: Bool, categoryKeyword: String?) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var pathOnly = false
        var categoryKeyword: String?

        if trimmed.hasPrefix("/") {
            pathOnly = true
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if trimmed.hasPrefix("#") {
            let body = String(trimmed.dropFirst())
            let chunks = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if let first = chunks.first {
                categoryKeyword = String(first)
            }
            trimmed = chunks.count > 1 ? String(chunks[1]) : ""
        }

        return (trimmed.lowercased(), pathOnly, categoryKeyword)
    }

    private func matchScore(for item: CommandItem, keyword: String, pathOnly: Bool) -> Int? {
        if keyword.isEmpty { return 0 }

        let candidates = pathOnly
            ? [item.command.lowercased()]
            : [item.name.lowercased(), item.command.lowercased()]

        var best: Int?
        for value in candidates {
            if value == keyword {
                best = min(best ?? Int.max, 0)
                continue
            }
            if value.hasPrefix(keyword) {
                let score = 8 + max(0, value.count - keyword.count)
                best = min(best ?? Int.max, score)
                continue
            }
            if let range = value.range(of: keyword) {
                let distance = value.distance(from: value.startIndex, to: range.lowerBound)
                let score = 24 + distance
                best = min(best ?? Int.max, score)
                continue
            }
            if let fuzzy = fuzzyMatchScore(query: keyword, text: value) {
                let score = 60 + fuzzy
                best = min(best ?? Int.max, score)
            }
        }

        return best
    }

    private func fuzzyMatchScore(query: String, text: String) -> Int? {
        if query.isEmpty { return 0 }
        if query.count > text.count { return nil }

        var queryIndex = query.startIndex
        var textIndex = text.startIndex
        var totalGaps = 0
        var lastMatchedOffset = -1

        while queryIndex < query.endIndex {
            var found = false
            while textIndex < text.endIndex {
                if text[textIndex] == query[queryIndex] {
                    let currentOffset = text.distance(from: text.startIndex, to: textIndex)
                    if lastMatchedOffset >= 0 {
                        totalGaps += max(0, currentOffset - lastMatchedOffset - 1)
                    } else {
                        totalGaps += currentOffset
                    }
                    lastMatchedOffset = currentOffset
                    query.formIndex(after: &queryIndex)
                    text.formIndex(after: &textIndex)
                    found = true
                    break
                }
                text.formIndex(after: &textIndex)
            }
            if !found { return nil }
        }

        totalGaps += max(0, text.count - (lastMatchedOffset + 1))
        return totalGaps
    }

    private func handleDroppedURLs(_ urls: [URL]) -> Bool {
        guard canDropIntoCurrentTab, !urls.isEmpty else { return false }

        var accepted = false
        for url in urls {
            accepted = addCommand(fromFileURL: url) || accepted
        }
        return accepted
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard canDropIntoCurrentTab else { return false }

        var handled = false
        let textTypes = [UTType.utf8PlainText.identifier, UTType.plainText.identifier, UTType.text.identifier]

        for provider in providers {
            var providerHandled = false

            if provider.canLoadObject(ofClass: URL.self) {
                providerHandled = true
                _ = provider.loadObject(ofClass: URL.self) { object, _ in
                    guard let url = object else { return }
                    _ = addCommand(fromFileURL: url)
                }
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                providerHandled = true

                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    _ = addCommand(fromFileURL: url)
                }

                _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, _, _ in
                    guard let url else { return }
                    _ = addCommand(fromFileURL: url)
                }

                _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, _ in
                    guard let url else { return }
                    _ = addCommand(fromFileURL: url)
                }

                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let url = extractURL(from: item) {
                        _ = addCommand(fromFileURL: url)
                    }
                }
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                providerHandled = true
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    if let url = extractURL(from: item) {
                        _ = addCommand(fromFileURL: url)
                    }
                }
            }

            for textType in textTypes where provider.hasItemConformingToTypeIdentifier(textType) {
                providerHandled = true
                provider.loadItem(forTypeIdentifier: textType, options: nil) { item, _ in
                    if let url = extractURL(from: item) {
                        _ = addCommand(fromFileURL: url)
                    }
                }
            }

            if !providerHandled {
                for typeID in provider.registeredTypeIdentifiers {
                    if typeID.contains("file-url") || typeID.contains("url") || typeID.contains("text") {
                        providerHandled = true
                        provider.loadItem(forTypeIdentifier: typeID, options: nil) { item, _ in
                            if let url = extractURL(from: item) {
                                _ = addCommand(fromFileURL: url)
                            }
                        }
                    }
                }
            }

            if providerHandled {
                handled = true
            }
        }

        return handled
    }

    private func extractURL(from item: Any?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let nsURL = item as? NSURL {
            return nsURL as URL
        }
        if let urls = item as? [URL] {
            return urls.first
        }
        if let nsURLs = item as? [NSURL], let first = nsURLs.first {
            return first as URL
        }
        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil) {
                return url
            }
            if let text = String(data: data, encoding: .utf8) {
                return extractURL(from: text)
            }
        }
        if let nsString = item as? NSString {
            return extractURL(from: nsString as String)
        }
        if let text = item as? String {
            return parseURLFromText(text)
        }
        return nil
    }

    private func parseURLFromText(_ text: String) -> URL? {
        let normalized = text.replacingOccurrences(of: "\0", with: "\n")
        let lines = normalized.components(separatedBy: .newlines)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("file://") {
                if let decoded = line.removingPercentEncoding,
                   let decodedURL = URL(string: decoded),
                   decodedURL.isFileURL {
                    return decodedURL
                }
                if let url = URL(string: line), url.isFileURL {
                    return url
                }
            }

            if line.hasPrefix("/") {
                return URL(fileURLWithPath: line)
            }
        }

        return nil
    }

    private func addCommand(fromFileURL rawURL: URL) -> Bool {
        guard canDropIntoCurrentTab else { return false }
        guard let normalizedURL = normalizeFileURL(rawURL) else { return false }

        let accessGranted = normalizedURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                normalizedURL.stopAccessingSecurityScopedResource()
            }
        }

        let ext = normalizedURL.pathExtension.lowercased()
        guard ["command", "sh", "app"].contains(ext) else { return false }
        guard FileManager.default.fileExists(atPath: normalizedURL.path) else { return false }

        let item = CommandItem(
            name: normalizedURL.lastPathComponent,
            command: normalizedURL.path,
            kind: .file,
            category: selectedCategory
        )

        DispatchQueue.main.async {
            appState.addCommand(item)
        }

        return true
    }

    private func normalizeFileURL(_ url: URL) -> URL? {
        var candidate = url

        if !candidate.isFileURL {
            if let decoded = candidate.absoluteString.removingPercentEncoding,
               decoded.hasPrefix("file://"),
               let decodedURL = URL(string: decoded),
               decodedURL.isFileURL {
                candidate = decodedURL
            } else if candidate.path.hasPrefix("/") {
                candidate = URL(fileURLWithPath: candidate.path)
            } else {
                return nil
            }
        }

        return candidate.standardizedFileURL.resolvingSymlinksInPath()
    }
}

private struct CommandTile: View {
    let command: CommandItem
    let isLastRun: Bool
    let onRun: () -> Void
    let onReveal: () -> Void
    let onRename: () -> Void
    let onEditIcon: () -> Void
    let onDelete: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button {
            if NSEvent.modifierFlags.contains(.option) {
                onReveal()
            } else {
                onRun()
            }
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(CommandIconGradientPreset.gradient(for: command.iconGradientID))
                        .frame(width: 86, height: 86)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(isHovering ? Theme.appleBlue.opacity(0.42) : Color.white.opacity(0.55), lineWidth: isHovering ? 1.6 : 1)
                        )
                        .shadow(
                            color: Theme.cardShadow.opacity(isHovering ? 0.72 : 0.45),
                            radius: isHovering ? 24 : 14,
                            x: 0,
                            y: isHovering ? 7 : 4
                        )

                    AppIconThumbnail(command: command)
                        .frame(width: 54, height: 54)
                }
                .frame(width: 86, height: 86)
                .overlay(alignment: .topTrailing) {
                    if isLastRun {
                        Circle()
                            .fill(Color(hex: "34C759"))
                            .frame(width: 9, height: 9)
                            .offset(x: 2, y: -2)
                    }
                }

                Text(command.name)
                    .font(Theme.microFont)
                    .foregroundColor(Theme.nearBlack)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 106, height: 34, alignment: .top)
                    .kerning(-0.12)
            }
            .frame(width: 110, height: 132, alignment: .top)
            .scaleEffect(isHovering ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button("运行") {
                onRun()
            }
            Button("在 Finder 中显示") {
                onReveal()
            }
            Divider()
            Button("重命名") {
                onRename()
            }
            Button("图标与背景") {
                onEditIcon()
            }
            Divider()
            Button("删除", role: .destructive) {
                onDelete()
            }
        }
    }
}

private struct AppIconThumbnail: View {
    let command: CommandItem

    var body: some View {
        if let emoji = command.iconEmoji, !emoji.isEmpty {
            Text(emoji)
                .font(.system(size: 36))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: 54, height: 54, alignment: .center)
        } else if command.kind == .file {
            Image(nsImage: NSWorkspace.shared.icon(forFile: command.command))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 46, height: 46, alignment: .center)
                .frame(width: 54, height: 54, alignment: .center)
        } else {
            Image(systemName: "terminal")
                .resizable()
                .scaledToFit()
                .foregroundColor(Theme.tertiaryText)
                .frame(width: 40, height: 40, alignment: .center)
                .frame(width: 54, height: 54, alignment: .center)
        }
    }
}

private struct LogToggleButtonStyle: ButtonStyle {
    let isExpanded: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .foregroundColor(isExpanded ? Theme.secondaryText : Theme.white)
            .background(
                Circle()
                    .fill(isExpanded ? Theme.white.opacity(0.55) : Theme.appleBlue)
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
    }
}

private struct LogCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.microFont.weight(.semibold))
            .foregroundColor(Theme.nearBlack.opacity(0.88))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.42 : 0.58))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.52), lineWidth: 1)
                    )
            )
    }
}

private struct RenameCommandSheet: View {
    let commandName: String
    @Binding var draftName: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("重命名启动器")
                .font(.system(size: 18, weight: .semibold))

            Text("原名称：\(commandName)")
                .font(.system(size: 12))
                .foregroundColor(Theme.tertiaryText)

            TextField("输入新名称", text: $draftName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("保存", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

private struct CommandIconEditorSheet: View {
    let commandName: String
    @Binding var emojiDraft: String
    @Binding var selectedGradientID: String
    let onOpenEmojiPicker: () -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("图标与背景")
                .font(.system(size: 18, weight: .semibold))

            Text(commandName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.secondaryText)
                .lineLimit(1)

            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(CommandIconGradientPreset.gradient(for: selectedGradientID))
                    .frame(width: 70, height: 70)
                    .overlay {
                        if let first = emojiDraft.trimmingCharacters(in: .whitespacesAndNewlines).first {
                            Text(String(first))
                                .font(.system(size: 30))
                        } else {
                            Image(systemName: "terminal")
                                .font(.system(size: 24))
                                .foregroundColor(.white.opacity(0.86))
                        }
                    }

                VStack(alignment: .leading, spacing: 8) {
                    TextField("输入 Emoji（可空）", text: $emojiDraft)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 8) {
                        Button("系统 Emoji") {
                            onOpenEmojiPicker()
                        }
                        Button("清空图标") {
                            emojiDraft = ""
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }

            Text("渐变背景")
                .font(.system(size: 13, weight: .semibold))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 90), spacing: 10)], spacing: 10) {
                ForEach(CommandIconGradientPreset.all) { preset in
                    Button {
                        selectedGradientID = preset.id
                    } label: {
                        VStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(CommandIconGradientPreset.gradient(for: preset.id))
                                .frame(height: 40)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(
                                            selectedGradientID == preset.id ? Theme.appleBlue : Color.white.opacity(0.5),
                                            lineWidth: selectedGradientID == preset.id ? 2 : 1
                                        )
                                )
                            Text(preset.name)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("保存", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430)
        .onChange(of: emojiDraft) { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = trimmed.first {
                emojiDraft = String(first)
            } else if !value.isEmpty {
                emojiDraft = ""
            }
        }
    }
}

private struct AddTabSheet: View {
    @Binding var tabName: String
    let errorText: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新增 Tab")
                .font(.system(size: 18, weight: .semibold))

            TextField("输入 Tab 名称", text: $tabName)
                .textFieldStyle(.roundedBorder)

            if let errorText {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("创建", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
