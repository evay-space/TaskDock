import AppKit
import SwiftUI
import TaskDockBrowserProtocol

@MainActor
final class RecentAppPopoverState: ObservableObject {
    @Published var isPresented = false
    @Published var runningApplicationIDs: Set<String> = []
    @Published var clickRequest = 0
    @Published var externalHovered = false
    @Published var anchorOffset: CGSize = .zero
    @Published var anchorSize: CGSize = .zero

}

private let favoriteShelfSeparatorColor = NSColor(calibratedWhite: 0.82, alpha: 0.55)

private let favoriteShelfBadgeColor = NSColor.systemRed

private func favoriteRunningIndicatorColor(isDark: Bool) -> NSColor {
    NSColor(calibratedWhite: isDark ? 0.88 : 0.12, alpha: 0.9)
}

private func favoritePressTint(_ pressed: Bool) -> Color {
    Color(white: pressed ? 1 - Double(FavoriteShelfInteractionMetrics.pressedOpacity) : 1)
}

enum MinimalTaskbarSizing {
    static let widthAnimationDuration: TimeInterval = 0.30
    static let contentInset: CGFloat = 6
    static let edgeInset: CGFloat = 8
    static let itemSpacing: CGFloat = 2
    static let separatorExtraSpacing: CGFloat = 6
    static let utilitiesWidth: CGFloat = 32 + iconSlotWidth + 2 * itemSpacing
    static func downloadLaneWidth(taskWidths: [CGFloat], fontSize: CGFloat, scale: CGFloat) -> CGFloat {
        if taskWidths.count > 3 {
            return TaskbarItemSizing.downloadGroupWidth(count: taskWidths.count, fontSize: fontSize, scale: scale)
                + itemSpacing * scale
        }
        return taskWidths.reduce(0, +) + CGFloat(taskWidths.count) * itemSpacing * scale
    }
    static let iconSlotWidth = FavoriteMagnificationLayout.itemStep - itemSpacing
    static let applicationIconSize = FavoriteMagnificationLayout.iconSize
    static let folderIconSize = FavoriteMagnificationLayout.iconSize
    static let distinctItemsKey = "taskdock.minimalDistinctItems"

    static func hoverSideClearance(for contentScale: CGFloat) -> CGFloat {
        ceil(42 * contentScale)
    }

}

private struct MinimalFavoriteDropDelegate: DropDelegate {
    let preview: (CGFloat?) -> Void
    let accept: ([NSItemProvider], CGFloat) -> Bool

    func dropEntered(info: DropInfo) { preview(info.location.x) }
    func dropExited(info: DropInfo) { preview(nil) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        preview(info.location.x)
        return DropProposal(operation: .copy)
    }
    func performDrop(info: DropInfo) -> Bool {
        preview(nil)
        return accept(info.itemProviders(for: ["public.file-url"]), info.location.x)
    }
}

private struct MinimalIconLaneOrigin: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

private struct MinimalIconHint: PreferenceKey {
    struct Target {
        let title: String
        let bounds: Anchor<CGRect>
    }

    static let defaultValue: Target? = nil

    static func reduce(value: inout Target?, nextValue: () -> Target?) {
        if value == nil { value = nextValue() }
    }
}

private extension View {
    func minimalIconHint(_ title: String, shown: Bool) -> some View {
        anchorPreference(key: MinimalIconHint.self, value: .bounds) { bounds in
            shown ? MinimalIconHint.Target(title: title, bounds: bounds) : nil
        }
    }
}

private struct MinimalInlineHint: NSViewRepresentable {
    let title: String
    let width: CGFloat
    let fontSize: CGFloat
    let arrowX: CGFloat

    func makeNSView(context: Context) -> FloatingBubbleHintView {
        FloatingBubbleHintView(title: title, width: width, fontSize: fontSize, arrowX: arrowX)
    }

    func updateNSView(_ view: FloatingBubbleHintView, context: Context) {
        view.update(title: title, width: width, fontSize: fontSize, arrowX: arrowX)
    }
}

private struct MinimalIconHover: Equatable {
    let slot: Int
    let pointerX: CGFloat
}

private struct MinimalIconWaveFrame: Equatable {
    var hover: MinimalIconHover?
    var pointer: MinimalIconHover?
    var progress: CGFloat = 0
}

private struct MinimalIconWaveView<Content: View>: View {
    let onMotion: (TimeInterval) -> Void
    let content: (MinimalIconWaveFrame, @escaping (MinimalIconWaveFrame) -> Void) -> Content
    @State private var frame = MinimalIconWaveFrame()

    var body: some View {
        content(frame, updateFrame)
    }

    private func updateFrame(_ next: MinimalIconWaveFrame) {
        guard frame != next else { return }
        if frame.progress > 0 || next.progress > 0 { onMotion(1.0 / 30) }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { frame = next }
    }
}

private struct MinimalIconMotion: Equatable {
    var horizontalOffset: CGFloat = 0
    var lift: CGFloat = 0
    var scale: CGFloat = 1

}

private struct MinimalIconButtonStyle: ButtonStyle {
    // AppKit handles short and long clicks for these icons.
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

struct TaskbarView: View {
    @StateObject private var edgeProfileAvatars = EdgeProfileAvatarStore()
    @State private var minimalContextMenuID: String?
    @AppStorage(MinimalTaskbarSizing.distinctItemsKey) private var minimalDistinctItems = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(TaskbarBlackBackgroundSettings.transparencyKey) private var blackBackgroundTransparency = 1.0
    @AppStorage("taskdock.magnificationPushesTasksV1") private var magnificationPushesTasks = false
    @AppStorage(RecentAppHoverBehavior.settingsKey) private var recentAppHoverBehavior = RecentAppHoverBehavior.nameBubble.rawValue
    let windows: [WindowModel]
    let trashWindow: WindowModel?
    @ObservedObject var recentAppPopoverState: RecentAppPopoverState
    let runningApplicationIDs: Set<String>
    @ObservedObject var favoriteBadges: FavoriteBadgeStore
    @ObservedObject var windowProgress: WindowProgressStore
    let isAccessibilityTrusted: Bool
    let minimalIdleWidth: CGFloat
    let minimalCanvasWidth: CGFloat?
    let canRestoreHiddenApplications: Bool
    let onRequestPermission: () -> Void
    let onSelect: (WindowModel) -> Void
    let onToggleAllApplications: () -> Void
    let onOpenTrash: () -> Void
    let onEmptyTrash: () -> Void
    let onRestoreLatestTrashItem: () -> Void
    let onOpenFolder: (FavoriteFolder) -> Void
    let onShowAppWindows: (WindowModel) -> Void
    let onBlockWindowType: (WindowModel) -> Void
    let onClose: (WindowModel) -> Void
    let onCloseGroup: ([WindowModel]) -> Void
    let onOpenFavorite: (FavoriteApp) -> Void
    let onPerformWindowAction: (@escaping () -> Void) -> Void
    let onQuitRecentApp: (FavoriteApp) -> Void
    let showsFavorites: Bool
    let showsControls: Bool
    let showsEmptyState: Bool
    @ObservedObject var settings: SettingsStore
    @ObservedObject var trashStatus: TrashStatusService
    let onSettingsChanged: () -> Void
    let onRecentPopoverVisibilityChanged: (Bool) -> Void
    let onAppDragChanged: (Bool) -> Void
    let onFavoriteHoverActivity: (Bool) -> Void
    let onMinimalHoverMotion: (TimeInterval) -> Void
    @State private var draggedAppKey: String?
    @State private var draggedIconMotion: MinimalIconMotion?
    @State private var minimalRemoval = FavoriteDragRemovalState()
    @State private var minimalRemovalTimer: DispatchWorkItem?
    @State private var minimalDragPreview: NSPanel?
    @State private var minimalDropGaps: [CGFloat: Int] = [:]
    @State private var minimalDropCounts: (apps: Int, folders: Int)?
    @State private var dragTranslation: CGFloat = 0
    @State private var dragStartAppKeys: [String]?
    @State private var dragStartGroupLayout: AppGroupLayout?
    @State private var hoverTargetAppKey: String?
    @State private var dragDirection: AppDragDirection?
    @State private var pendingDropCandidate: PendingDropCandidate?
    @State private var pendingDropToken: UUID?
    @State private var isSettlingAppDrag = false
    @State private var settlingAppOffsets: [String: CGFloat] = [:]
    @State private var favoriteMagnificationActive = false
    @State private var minimalIconLaneOrigin: CGFloat?
    @Namespace private var minimalIconLaneSpace
    @State private var hoveredWindowID: String?
    @State private var downloadsExpanded = false
    @State private var downloadButtonHovered = false
    @State private var pendingFocus: PendingTaskFocus?
    @State private var favoriteLeadingExtension: CGFloat = 0
    @State private var favoriteHoverTrailingSpace: CGFloat = 0

    private struct PendingTaskFocus {
        let token = UUID()
        let windowID: String
        let nativeWindowID: String
        let title: String
        let finderPID: pid_t?
        let selectsWindow: Bool
    }

    private var pendingFocusWindowID: String? {
        guard let pendingFocus else { return nil }
        guard pendingFocus.selectsWindow else { return "" }
        if windows.contains(where: { $0.id == pendingFocus.windowID }) { return pendingFocus.windowID }

        // Finder can replace a tab's row with a window row during restoration.
        let matches = windows.filter {
            $0.nativeWindowID == pendingFocus.nativeWindowID && $0.rawTitle == pendingFocus.title
        }
        if matches.count == 1 { return matches[0].id }
        if let finderPID = pendingFocus.finderPID {
            let finderMatches = windows.filter {
                $0.pid == finderPID && $0.rawTitle == pendingFocus.title
            }
            if finderMatches.count == 1 { return finderMatches[0].id }
        }
        return pendingFocus.windowID
    }

    private var confirmedPendingFocusToken: UUID? {
        guard let pendingFocus, let target = pendingFocusWindowID else { return nil }
        let focused = windows.first(where: \.isFocused)
        if pendingFocus.selectsWindow { return focused?.id == target ? pendingFocus.token : nil }
        return focused?.nativeWindowID == pendingFocus.nativeWindowID ? nil : pendingFocus.token
    }

    private func selectImmediately(_ window: WindowModel) {
        pendingFocus = PendingTaskFocus(windowID: window.id, nativeWindowID: window.nativeWindowID,
            title: window.rawTitle,
            finderPID: window.bundleIdentifier == "com.apple.finder" ? window.pid : nil,
            selectsWindow: !window.isFocused)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { onSelect(window) }
    }

    private var reducesTaskbarMotion: Bool {
        settings.layoutMode.isTaskbar && systemReduceMotion
    }

    private var taskbarVisualLift: CGFloat {
        settings.layoutMode.isTaskbar ? 4 : 0
    }

    private func isCollapsed(_ group: AppWindowGroup, autoCollapsed: Set<String> = []) -> Bool {
        if settings.layoutMode == .dockCompanion {
            return group.windows.count >= settings.dockCompanionCollapseThreshold
        }
        return settings.layoutMode.isTaskbar
            && (autoCollapsed.contains(group.id) || baseTaskbarCollapse(group))
    }

    private func baseTaskbarCollapse(_ group: AppWindowGroup) -> Bool {
        settings.singleIconAppIDs.contains(group.id)
            || (settings.taskbarCollapseSameAppWindows && group.windows.count >= 3)
    }

    var body: some View {
        taskbarView
            .task(id: windows.contains { $0.bundleIdentifier == EdgeProfileAvatarCatalog.bundleIdentifier }) {
                guard windows.contains(where: { $0.bundleIdentifier == EdgeProfileAvatarCatalog.bundleIdentifier })
                else { return }
                await edgeProfileAvatars.refreshWhileVisible()
            }
            .task(id: confirmedPendingFocusToken) {
                guard let token = confirmedPendingFocusToken else { return }
                // Wait for a stable focus report through the activation hand-off.
                try? await Task.sleep(nanoseconds: 160_000_000)
                guard !Task.isCancelled, pendingFocus?.token == token else { return }
                pendingFocus = nil
            }
            .task(id: pendingFocus?.token) {
                guard let token = pendingFocus?.token else { return }
                // If activation fails, fall back to the system's actual selection.
                try? await Task.sleep(nanoseconds: 650_000_000)
                guard !Task.isCancelled, pendingFocus?.token == token else { return }
                pendingFocus = nil
            }
    }

    @ViewBuilder
    private func windowGroup(_ group: AppWindowGroup, itemWidths: [String: CGFloat], autoCollapsed: Set<String>,
                             hoverMotion: @escaping (String) -> MinimalIconMotion = { _ in MinimalIconMotion() }) -> some View {
                                let itemWidth = itemWidths[group.windows[0].id] ?? 0
                                HStack(spacing: taskbarItemSpacing) {
                                    if isCollapsed(group, autoCollapsed: autoCollapsed) {
                                        let motion = hoverMotion(group.windows[0].id)
                                        TaskbarCollapsedAppView(
                                            windows: group.windows,
                                            profileAvatars: Dictionary(uniqueKeysWithValues: group.windows.compactMap { window in
                                                edgeProfileAvatars.avatar(for: window).map { (window.id, $0) }
                                            }),
                                            availableWidth: itemWidth,
                                            itemHeight: taskbarItemHeight,
                                            hitHeight: taskbarBaseHeight,
                                            motion: motion,
                                            visualLift: taskbarVisualLift,
                                            contentScale: taskbarContentScale,
                                            taskbarFontSize: settings.taskbarItemFontSize,
                                            iconOnly: settings.singleIconAppIDs.contains(group.id) && settings.layoutMode.isTaskbar,
                                            distinctStates: minimalDistinctItems,
                                            nonSelectedItemTransparency: settings.transparency(in: .taskbar),
                                            progress: group.windows.compactMap { windowProgress.values[$0.nativeWindowID] }.max(),
                                            onSelect: selectImmediately,
                                            onClose: onClose,
                                            contextMenuActions: collapsedGroupMenuActions(group),
                                            onContextMenuVisibilityChanged: onRecentPopoverVisibilityChanged,
                                            focusOverride: pendingFocusWindowID.map { id in group.windows.contains { $0.id == id } }
                                        )
                                        .frame(width: itemWidth, height: taskbarBaseHeight)
                                        .scaleEffect(x: motion.scale, y: 1)
                                        .offset(x: motion.horizontalOffset)
                                        .simultaneousGesture(taskbarReorderGesture(for: group.windows[0], itemWidths: itemWidths,
                                            autoCollapsed: autoCollapsed))
                                    } else {
                                    ForEach(group.windows) { window in
                                        let itemWidth = itemWidths[window.id] ?? 0
                                        let motion = hoverMotion(window.id)
                                        Button {
                                            selectImmediately(window)
                                        } label: {
                                            WindowTaskItemView(
                                                window: window,
                                                profileAvatar: edgeProfileAvatars.avatar(for: window),
                                                availableWidth: itemWidth,
                                                nonSelectedItemTransparency: settings.transparency(in: .taskbar),
                                                shortcutLabel: shortcutLabel(for: window),
                                                itemHeight: taskbarItemHeight,
                                                contentScale: taskbarContentScale,
                                                taskbarFontSize: settings.taskbarItemFontSize,
                                                    distinctStates: minimalDistinctItems,
                                                progress: windowProgress.values[window.nativeWindowID],
                                                visualLift: taskbarVisualLift,
                                                onShowAppWindows: { onShowAppWindows(window) },
                                                onBlockWindowType: { onBlockWindowType(window) },
                                                onClose: { onClose(window) },
                                                onToggleFavorite: { toggleFavorite(window) },
                                                favoriteActionTitle: favoriteMenuTitle(for: window),
                                                isHovered: hoveredWindowID == window.id,
                                                focusOverride: pendingFocusWindowID.map { $0 == window.id }
                                            )
                                            .scaleEffect(x: 1, y: motion.scale)
                                            .offset(y: -motion.lift)
                                            .frame(height: settings.layoutMode.isTaskbar
                                                ? taskbarBaseHeight : taskbarItemHeight)
                                            .background(Color.black.opacity(settings.layoutMode.isTaskbar ? 0.001 : 0))
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .frame(width: itemWidth, height: settings.layoutMode.isTaskbar
                                            ? taskbarBaseHeight : taskbarItemHeight)
                                        .background(Color.black.opacity(settings.layoutMode.isTaskbar ? 0.001 : 0))
                                        .contentShape(Rectangle())
                                        .scaleEffect(x: motion.scale, y: 1)
                                        .offset(x: motion.horizontalOffset)
                                        .simultaneousGesture(taskbarReorderGesture(for: window, itemWidths: itemWidths,
                                            autoCollapsed: autoCollapsed))
                                        .floatingBubbleContextMenu(actions: windowFavoriteMenuActions(window) + [
                                            FavoriteShelfMenuAction(title: "显示该 App 的所有窗口", perform: { onShowAppWindows(window) }),
                                            .separator,
                                            FavoriteShelfMenuAction(title: "屏蔽此类窗口", perform: { onBlockWindowType(window) }),
                                            .separator,
                                            FavoriteShelfMenuAction(title: "关闭此窗口", perform: { onClose(window) })
                                        ], iconCenterX: itemWidth < 72 * taskbarContentScale ? itemWidth / 2 : 17 * taskbarContentScale,
                                            onVisibilityChange: onRecentPopoverVisibilityChanged)
                                        .background(TaskbarPointerHoverTracker { inside in
                                            if inside {
                                                hoveredWindowID = window.id
                                            } else if hoveredWindowID == window.id {
                                                hoveredWindowID = nil
                                            }
                                        })
                                        .onHover { inside in
                                            if inside {
                                                hoveredWindowID = window.id
                                            } else if hoveredWindowID == window.id {
                                                hoveredWindowID = nil
                                            }
                                        }
                                        .accessibilityElement(children: .combine)
                                        .accessibilityValue(window.isFocused ? "当前焦点窗口"
                                            : hoveredWindowID == window.id ? "鼠标悬停" : "非焦点窗口")
                                    }
                                    }
                                }
                                .offset(x: taskbarItemOffset(for: group.id))
                                .animation(draggedAppKey == group.id ? nil : appReorderAnimation, value: hoverTargetAppKey)
                                .animation(draggedAppKey == group.id ? nil : appReorderAnimation, value: dragDirection)
                                .opacity(draggedAppKey == group.id ? 0.88 : 1)
                                .scaleEffect(isDropTarget(group.id) ? 0.98 : 1)
                                .zIndex(draggedAppKey == group.id ? 20 : 0)
                                .transaction { transaction in
                                    if draggedAppKey == group.id && !isSettlingAppDrag {
                                        transaction.animation = nil
                                        transaction.disablesAnimations = true
                                    }
                                }
    }

    private var minimalMode: Bool { settings.layoutMode == .minimal }
    private var effectiveSideInset: CGFloat { minimalMode ? MinimalTaskbarSizing.edgeInset : settings.taskbarSideInset }

    private func minimalAppButton(_ favorite: FavoriteApp, window: WindowModel?,
                                  itemWidths: [String: CGFloat], autoCollapsed: Set<String>,
                                  hovered: Bool, motion: MinimalIconMotion) -> some View {
        let favoriteIndex = settings.displayedFavoriteApps.firstIndex { $0.id == favorite.id }
        let favoriteShortcut = favoriteIndex.flatMap { index in
            let labels = OptionWindowHotKeyMonitor.favoriteShortcutLabels
            return labels.indices.contains(index) && settings.activeFavoriteShortcutIndices.contains(index + 1)
                ? labels[index] : nil
        }
        let shortcut = favoriteShortcut ?? window.flatMap { shortcutLabel(for: $0) }
        let open: () -> Void = {
            guard draggedAppKey == nil else { return }
            if let window, !settings.isFavorite(favorite.id) { selectImmediately(window) }
            else { onOpenFavorite(favorite) }
        }
        return Button(action: open) {
            FavoriteApplicationIcon(favorite: favorite, size: MinimalTaskbarSizing.applicationIconSize * taskbarContentScale)
                .edgeProfileAvatar(window.flatMap { edgeProfileAvatars.avatar(for: $0) },
                    iconSize: MinimalTaskbarSizing.applicationIconSize * taskbarContentScale)
                .colorMultiply(favoritePressTint(minimalContextMenuID == favorite.id))
                .minimalIconHint(favorite.applicationName, shown: hovered && minimalContextMenuID == nil)
                .overlay {
                    if let label = favoriteBadges.badges[favorite.id] {
                        let scale = taskbarContentScale
                        let iconSize = FavoriteMagnificationLayout.iconSize * scale
                        Text(label)
                            .font(.system(size: FavoriteShelfBadgeMetrics.fontSize * scale, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(width: FavoriteShelfBadgeMetrics.width(for: label) * scale,
                                height: FavoriteShelfBadgeMetrics.height * scale)
                            .background(Color(nsColor: favoriteShelfBadgeColor), in: Capsule())
                            .scaleEffect(FavoriteShelfBadgeMetrics.scale(for: motion.scale) / motion.scale)
                            .offset(x: iconSize * 0.38, y: -iconSize * 0.40)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .scaleEffect(motion.scale)
                .offset(x: motion.horizontalOffset,
                    y: favoriteIconRestOffset - motion.lift)
                .frame(width: MinimalTaskbarSizing.iconSlotWidth * taskbarContentScale, height: taskbarItemHeight)
                .offset(y: -taskbarVisualLift)
                .frame(height: taskbarBaseHeight)
                .overlay(alignment: .bottom) {
                    favoriteRunningIndicator(isRunning: window != nil || runningApplicationIDs.contains(favorite.id),
                        motion: motion)
                }
                .overlay(alignment: .topTrailing) {
                    if let shortcut { FavoriteShortcutBadge(label: shortcut, sizeScale: taskbarContentScale) }
                }
                .background(Color.black.opacity(0.001))
                .contentShape(Rectangle())
        }
        .buttonStyle(MinimalIconButtonStyle())
        .accessibilityLabel(favorite.applicationName)
        .floatingBubbleContextMenu(actions: minimalAppActions(favorite, window: window), onIconClick: open,
            onVisibilityChange: { setMinimalContextMenu(favorite.id, visible: $0) })
        .offset(x: taskbarItemOffset(for: favorite.id))
        .opacity(draggedAppKey == favorite.id && minimalRemoval.outsideSince != nil ? 0 : 1)
        .animation(draggedAppKey == favorite.id || isSettlingAppDrag ? nil : appReorderAnimation,
            value: hoverTargetAppKey)
        .transaction { transaction in
            if draggedAppKey == favorite.id && !isSettlingAppDrag {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
        .zIndex(draggedAppKey == favorite.id ? 20 : hovered ? 2 : 0)
        .simultaneousGesture(appReorderGesture(appKey: favorite.id, itemWidths: itemWidths,
            autoCollapsed: autoCollapsed, pickedUpIconMotion: motion))
    }

    private func setMinimalContextMenu(_ id: String, visible: Bool) {
        if visible { minimalContextMenuID = id }
        else if minimalContextMenuID == id { minimalContextMenuID = nil }
        onRecentPopoverVisibilityChanged(visible)
    }

    private var favoriteIconRestOffset: CGFloat {
        (taskbarItemHeight - FavoriteMagnificationLayout.iconSize * taskbarContentScale) / 2
            - FavoriteMagnificationLayout.iconBottomInset * taskbarContentScale
            + (taskbarBaseHeight - taskbarItemHeight) / 2
    }

    private func favoriteRunningIndicator(isRunning: Bool, motion: MinimalIconMotion) -> some View {
        let scale = taskbarContentScale
        let diameter = FavoriteMagnificationLayout.indicatorDiameter * scale
        let center = FavoriteMagnificationLayout.runningIndicatorCenter * scale
        let lift = -FavoriteMagnificationLayout.lift(for: motion.scale) * scale
        return Circle().fill(Color(nsColor: favoriteRunningIndicatorColor(isDark: colorScheme == .dark)))
            .frame(width: diameter, height: diameter)
            .scaleEffect(FavoriteMagnificationLayout.indicatorScale(for: motion.scale))
            .padding(.bottom, center - diameter / 2)
            .offset(x: motion.horizontalOffset, y: -taskbarVisualLift - lift)
            .opacity(isRunning ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func minimalAppActions(_ favorite: FavoriteApp, window: WindowModel?) -> [FavoriteShelfMenuAction] {
        var actions = [FavoriteShelfMenuAction(title: "打开", perform: { onOpenFavorite(favorite) })]
        if favorite.bundleIdentifier == "com.apple.finder" {
            let favorites = FinderSidebarFavoritesService.favorites()
            if !favorites.isEmpty {
                actions.append(.separator)
                for entry in favorites {
                    actions.append(FavoriteShelfMenuAction(title: entry.url == nil
                        ? "打开 \(entry.name)（当前不可用）" : "打开 \(entry.name)",
                        isEnabled: entry.url != nil, perform: {
                            if let url = entry.url { onPerformWindowAction { NSWorkspace.shared.open(url) } }
                        }))
                }
                actions.append(.separator)
            }
        }
        let running = favorite.bundleIdentifier.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
        }
        if running != nil {
            actions.append(FavoriteShelfMenuAction(title: "退出", perform: { onQuitRecentApp(favorite) }))
        }
        if let window {
            actions.append(FavoriteShelfMenuAction(title: "关闭此窗口", perform: { onClose(window) }))
        }
        actions.append(.separator)
        if !(settings.dockFavoritesSyncEnabled && favorite.bundleIdentifier == "com.apple.finder") {
            let pinned = settings.isFavorite(favorite.id)
            actions.append(FavoriteShelfMenuAction(title: pinned ? "取消收藏" : "固定到收藏", symbol: "star", perform: {
                if pinned { settings.removeFavorite(favorite) }
                else { _ = settings.addFavorite(favorite) }
                onSettingsChanged()
            }))
        }
        actions.append(singleIconMenuAction(for: favorite.id))
        return actions
    }

    private var minimalSlotWidth: CGFloat { MinimalTaskbarSizing.iconSlotWidth * taskbarContentScale + taskbarItemSpacing }

    private var favoritePeakScale: CGFloat {
        FavoriteMagnificationLayout.configuredScale(settings.favoriteMagnificationScale,
            enabled: settings.favoriteMagnificationEnabled, reducesMotion: reducesTaskbarMotion)
    }

    private func minimalHintOverlay(_ hint: MinimalIconHint.Target, in geometry: GeometryProxy) -> some View {
        let icon = geometry[hint.bounds]
        let fontSize = SmallBubbleMetrics.fontSize
        let width = SmallBubbleMetrics.width(for: hint.title, sizeScale: taskbarPanelScale)
        let placement = SmallBubbleMetrics.placement(width: width, iconCenter: icon.midX,
            horizontalBounds: 8...max(8, geometry.size.width - 8))
        let height = SmallBubbleMetrics.height
        let top = icon.minY - SmallBubbleMetrics.iconGap - height
        return MinimalInlineHint(title: hint.title, width: width, fontSize: fontSize, arrowX: placement.arrow)
            .frame(width: width, height: height)
            .position(x: placement.left + width / 2, y: top + height / 2)
    }

    private func minimalContent(availableWidth: CGFloat) -> some View {
        let folders = settings.favoriteFolders
        let hasApps = !appGroups.isEmpty || !settings.displayedFavoriteApps.isEmpty
        let separatorSpacing = MinimalTaskbarSizing.separatorExtraSpacing * taskbarPanelScale
        let folderSeparatorSpacing = hasApps && !folders.isEmpty ? separatorSpacing : 0
        let recentSeparatorSpacing = hasApps || !folders.isEmpty || !downloadTasks.isEmpty ? separatorSpacing : 0
        let controlsSeparatorSpacing = showsControls ? recentSeparatorSpacing + separatorSpacing : 0
        // The panel grows over a short animation after a new window appears.
        // Lay out against its target width so that temporary clipping cannot
        // be mistaken for a real task-item overflow and collapse an app group.
        let horizontalClearance = MinimalTaskbarSizing.hoverSideClearance(for: taskbarPanelScale)
        let screenWidth = NSScreen.screens.first?.frame.width ?? availableWidth
        let targetWidth = min(screenWidth, minimalIdleWidth + 2 * horizontalClearance)
        let layoutWidth = max(availableWidth, targetWidth)
        let clearance = max(0, min(horizontalClearance,
            (layoutWidth - minimalIdleWidth) / 2))
        let downloadsWidth = MinimalTaskbarSizing.downloadLaneWidth(
            taskWidths: downloadTasks.map(downloadItemWidth), fontSize: settings.taskbarItemFontSize, scale: taskbarPanelScale)
        let fixedWidth = (MinimalTaskbarSizing.utilitiesWidth + MinimalTaskbarSizing.contentInset)
            * taskbarPanelScale + downloadsWidth + controlsSeparatorSpacing
        let laneWidth = max(0, layoutWidth - 2 * clearance - fixedWidth - 2 * effectiveSideInset
            - 2 * MinimalTaskbarSizing.contentInset * taskbarPanelScale)
        let autoCollapsed = autoCollapsedAppKeys(for: max(0, laneWidth - folderSeparatorSpacing))
        let widths = taskItemWidths(for: laneWidth, autoCollapsed: autoCollapsed)
        let layout = taskbarAppGroupLayout(itemWidths: widths, autoCollapsed: autoCollapsed)
        let groupsByID = Dictionary(uniqueKeysWithValues: appGroups.map { ($0.id, $0) })
        var appSlots: [String: Int] = [:]
        var taskSlots: [String: Int] = [:]
        var yieldingTaskSlots = Set<Int>()
        var appCenters: [CGFloat?] = []
        var appWidths: [CGFloat] = []
        var appSlotWidths: [CGFloat] = []
        var stationaryTaskBounds: [Int: ClosedRange<CGFloat>] = [:]
        for index in layout.keys.indices {
            let key = layout.keys[index]
            if let group = groupsByID[key], group.windows.count > 1 {
                if settings.singleIconAppIDs.contains(key) {
                    let displayed = isCollapsed(group, autoCollapsed: autoCollapsed)
                        ? Array(group.windows.prefix(1)) : group.windows
                    var start = layout.minXs[index]
                    for window in displayed {
                        let width = widths[window.id] ?? 0
                        taskSlots[window.id] = appCenters.count
                        appCenters.append(start + width / 2)
                        appWidths.append(width)
                        appSlotWidths.append(width + taskbarItemSpacing)
                        start += width + taskbarItemSpacing
                    }
                } else {
                    let slot = appCenters.count
                    if magnificationPushesTasks { yieldingTaskSlots.insert(slot) }
                    stationaryTaskBounds[slot] = layout.minXs[index]...layout.maxXs[index]
                    for window in group.windows { taskSlots[window.id] = slot }
                    appCenters.append(nil)
                    appWidths.append(0)
                    appSlotWidths.append(0)
                }
            } else {
                appSlots[key] = appCenters.count
                appCenters.append((layout.minXs[index] + layout.maxXs[index]) / 2)
                appWidths.append(MinimalTaskbarSizing.applicationIconSize * taskbarContentScale)
                appSlotWidths.append(minimalSlotWidth)
            }
        }
        let folderStart = (layout.maxXs.last ?? -taskbarItemSpacing)
            + taskbarItemSpacing + folderSeparatorSpacing
        let folderStep = MinimalTaskbarSizing.iconSlotWidth * taskbarPanelScale + taskbarItemSpacing
        let folderCenters = folders.indices.map { index in
            folderStart + CGFloat(index) * folderStep + MinimalTaskbarSizing.iconSlotWidth * taskbarPanelScale / 2
        }
        let inset = MinimalTaskbarSizing.contentInset * taskbarPanelScale
        let origin = minimalIconLaneOrigin ?? clearance + inset
        let scrollWidth = clearance + 2 * inset + laneWidth
        let canvasWidth = max(0, availableWidth - 2 * effectiveSideInset)
        let contentEnd = folderCenters.last.map {
            $0 + MinimalTaskbarSizing.iconSlotWidth * taskbarPanelScale / 2
        } ?? (layout.maxXs.last ?? 0)
        let showsInlineControls = showsControls && contentEnd <= laneWidth + 0.5
        let separatesControls = !downloadTasks.isEmpty || (showsControls && !showsInlineControls)
        var slotCenters = (appCenters + folderCenters.map(Optional.some)).map { $0.map { $0 + origin } }
        var iconWidths = appWidths + Array(repeating: MinimalTaskbarSizing.folderIconSize * taskbarContentScale, count: folderCenters.count)
        var slotWidths = appSlotWidths + Array(repeating: minimalSlotWidth, count: folderCenters.count)
        var hitRanges: [Range<CGFloat>?] = zip(slotCenters, slotWidths).map { center, width in
            guard let center else { return nil }
            let lower = max(0, center - width / 2)
            let upper = min(scrollWidth, center + width / 2)
            return lower < upper ? lower..<upper : nil
        }
        if separatesControls {
            if magnificationPushesTasks, showsControls { yieldingTaskSlots.insert(slotCenters.count) }
            slotCenters.append(nil)
            iconWidths.append(0)
            slotWidths.append(0)
            hitRanges.append(nil)
        }
        let recentSlot = slotCenters.count
        let trashSlot = recentSlot + 1
        if showsControls {
            let controlsStart = showsInlineControls ? origin + contentEnd : scrollWidth
            let recentStart = controlsStart + taskbarItemSpacing + downloadsWidth + recentSeparatorSpacing
            let trashStart = recentStart + 32 * taskbarPanelScale + taskbarItemSpacing + separatorSpacing
            let trashSlotWidth = MinimalTaskbarSizing.iconSlotWidth * taskbarPanelScale
            slotCenters += [recentStart + 16 * taskbarPanelScale, trashStart + trashSlotWidth / 2]
            iconWidths += [27 * taskbarPanelScale, FavoriteMagnificationLayout.iconSize * taskbarContentScale]
            slotWidths += [32 * taskbarPanelScale, trashSlotWidth]
            let sharedHitBoundary = recentStart - (showsInlineControls && downloadTasks.isEmpty
                ? (taskbarItemSpacing + recentSeparatorSpacing) / 2 : 0)
            let trashHitBoundary = trashStart - (taskbarItemSpacing + separatorSpacing) / 2
            hitRanges += [sharedHitBoundary..<trashHitBoundary, trashHitBoundary..<(trashStart + trashSlotWidth)]
        }
        let dividerHalfGap = (taskbarItemSpacing + separatorSpacing) / 2
        var separatorDistances: [Int: CGFloat] = [:]
        if folderSeparatorSpacing > 0 {
            separatorDistances[appCenters.count] = MinimalTaskbarSizing.iconSlotWidth * taskbarPanelScale / 2 + dividerHalfGap
        }
        if showsControls {
            if showsInlineControls && downloadTasks.isEmpty && recentSeparatorSpacing > 0 {
                separatorDistances[recentSlot] = 16 * taskbarPanelScale + dividerHalfGap
            }
            separatorDistances[trashSlot] = MinimalTaskbarSizing.iconSlotWidth * taskbarPanelScale / 2 + dividerHalfGap
        }
        // Hand the hint straight to the next icon when crossing the spacing.
        for index in hitRanges.indices.dropFirst() {
            guard let previous = hitRanges[index - 1], let next = hitRanges[index],
                  next.lowerBound > previous.upperBound,
                  next.lowerBound - previous.upperBound <= taskbarItemSpacing + separatorSpacing + 0.001 else { continue }
            let boundary = (previous.upperBound + next.lowerBound) / 2
            hitRanges[index - 1] = previous.lowerBound..<boundary
            hitRanges[index] = boundary..<next.upperBound
        }
        let peakScale = favoritePeakScale
        let trailingReservations: [Int: CGFloat]
        if magnificationPushesTasks && peakScale > 1 {
            let runLengths = Set(slotCenters.split(whereSeparator: { $0 == nil }).map(\.count))
            trailingReservations = Dictionary(uniqueKeysWithValues: runLengths.map { length in
                (length, TaskbarFavoriteLaneLayout.hoverTrailingSpace(appCount: length, folderCount: 0,
                    showsTrash: false, sizeScale: taskbarContentScale, peakScale: peakScale))
            })
        } else {
            trailingReservations = [:]
        }
        let displayedFavorites = settings.displayedFavoriteApps
        let favoritesByID = Dictionary(uniqueKeysWithValues: displayedFavorites.map { ($0.id, $0) })
        let folderIcons = folders.map(FavoriteFolderIcon.image)
        let groupStarts = Dictionary(uniqueKeysWithValues: zip(layout.keys, layout.minXs))
        let folderIconWidth = MinimalTaskbarSizing.iconSlotWidth * taskbarPanelScale
        func insertion(at x: CGFloat) -> (app: Int, folder: Int) {
            let app = layout.keys.indices.filter { x >= (layout.minXs[$0] + layout.maxXs[$0]) / 2 }.count
            let folder = folderCenters.filter { x >= $0 }.count
            return (app, folder)
        }
        func updateInsertionPreview(at x: CGFloat?) {
            guard let x else {
                minimalDropCounts = nil
                minimalDropGaps = [:]
                return
            }
            let position = insertion(at: x)
            if minimalDropCounts == nil {
                let urls = NSPasteboard(name: .drag)
                    .readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                let supported = FavoriteShelfDrop.supportedURLs(urls)
                let apps = supported.filter { $0.pathExtension.lowercased() == "app" }.count
                minimalDropCounts = (apps, supported.count - apps)
            }
            let counts = minimalDropCounts ?? (0, 0)
            let unknown = counts.apps + counts.folders == 0
            var gaps: [CGFloat: Int] = [:]
            if counts.apps > 0 || (unknown && x < folderStart) {
                let appX: CGFloat
                if position.app < layout.keys.count {
                    appX = layout.minXs[position.app]
                } else {
                    appX = layout.maxXs.last.map { $0 + taskbarItemSpacing } ?? 0
                }
                gaps[appX, default: 0] += max(1, counts.apps)
            }
            if counts.folders > 0 || (unknown && x >= folderStart) {
                let folderX = folderStart + CGFloat(position.folder) * folderStep
                gaps[folderX, default: 0] += max(1, counts.folders)
            }
            if gaps != minimalDropGaps { minimalDropGaps = gaps }
        }
        func gapOffset(for x: CGFloat) -> CGFloat {
            CGFloat(minimalDropGaps.reduce(0) { $0 + ($1.key <= x + 0.001 ? $1.value : 0) })
                * minimalSlotWidth
        }
        let headroom = FavoriteMagnificationLayout.headroom(for: taskbarPanelScale, peakScale: peakScale)
        return MinimalIconWaveView(onMotion: onMinimalHoverMotion) { minimalIconWaveFrame, updateFrame in
            let activeHover = draggedAppKey == nil ? minimalIconWaveFrame.hover : nil
            let progress = minimalIconWaveFrame.progress
            let wave = minimalIconWaveFrame.pointer.flatMap { hover -> LinkedFavoriteWave? in
                guard peakScale > 1 else { return nil }
                return FavoriteMagnificationLayout.linkedIconWave(centers: slotCenters,
                    widths: iconWidths,
                    hoveredIndex: hover.slot, pointerX: hover.pointerX, slotWidth: minimalSlotWidth,
                    sizeScale: taskbarContentScale, peakScale: peakScale, leftClearance: clearance,
                    rightClearance: showsControls ? clearance : 0,
                    lastSlotWidth: showsControls ? MinimalTaskbarSizing.iconSlotWidth * taskbarPanelScale : nil,
                    itemSlotWidths: slotWidths,
                    separatorDistances: separatorDistances,
                    trailingReservations: trailingReservations,
                    yieldingTaskSlots: yieldingTaskSlots)
            }
            func motion(at slot: Int?, followsDrag: Bool = false) -> MinimalIconMotion {
                if followsDrag, let draggedIconMotion { return draggedIconMotion }
                guard let slot, let wave, wave.influences.indices.contains(slot) else { return MinimalIconMotion() }
                let scale = FavoriteMagnificationLayout.interpolate(1, wave.scales[slot], progress: progress)
                return MinimalIconMotion(horizontalOffset: followsDrag ? 0 : wave.offsets[slot] * progress,
                    lift: FavoriteMagnificationLayout.centerLift(for: scale,
                        iconHeight: iconWidths[slot], sizeScale: taskbarContentScale),
                    scale: scale)
            }
            func separator(before rightSlot: Int, after leftSlot: Int? = nil, leftOffset: CGFloat? = nil) -> some View {
                let right = motion(at: rightSlot)
                let left = motion(at: leftSlot)
                let rightEdgeOffset = right.horizontalOffset - iconWidths[rightSlot] * (right.scale - 1) / 2
                let leftEdgeOffset = leftSlot.map { left.horizontalOffset + iconWidths[$0] * (left.scale - 1) / 2 }
                    ?? leftOffset ?? rightEdgeOffset
                let offset = wave?.separatorOffsets[rightSlot].map { $0 * progress }
                    ?? (leftEdgeOffset + rightEdgeOffset) / 2
                return minimalSeparator(offset: offset, gap: taskbarItemSpacing + separatorSpacing)
            }
            let tailClearance = max(0, clearance - (wave?.trailingOverflow ?? 0) * progress)
            var folderReveal: CGFloat = 0
            var folderControlYield: CGFloat = 0
            if !showsInlineControls, let center = folderCenters.last,
               draggedAppKey == nil, minimalDropGaps.isEmpty {
                let folderMotion = motion(at: appCenters.count + folders.count - 1)
                let width = MinimalTaskbarSizing.folderIconSize * taskbarContentScale
                let offset = folderMotion.horizontalOffset
                folderReveal = FavoriteMagnificationLayout.trailingReveal(center: origin + center, iconWidth: width,
                    scale: folderMotion.scale, offset: offset, viewportEnd: scrollWidth, clearance: tailClearance)
                if showsControls, folderMotion.scale > 1, origin + center < scrollWidth {
                    let edge = origin + center + offset + width * folderMotion.scale / 2
                    let recent = motion(at: recentSlot)
                    let firstControlInset = downloadTasks.isEmpty
                        ? recentSeparatorSpacing + (32 - 27 * recent.scale) * taskbarPanelScale / 2
                            + recent.horizontalOffset
                        : (wave?.trailingTaskShift ?? 0) * progress
                    let controlStart = scrollWidth + taskbarItemSpacing + firstControlInset
                    folderControlYield = min(tailClearance, max(folderReveal, edge + taskbarItemSpacing - controlStart))
                }
            }
            let visibleScrollEnd = showsInlineControls ? canvasWidth : scrollWidth + folderReveal
            var leftEdge = CGFloat.infinity
            var rightEdge: CGFloat = 0
            func includeEdges(_ left: CGFloat, _ right: CGFloat, clippedAt limit: CGFloat) {
                let lower = max(0, left)
                let upper = min(limit, right)
                guard lower <= upper else { return }
                leftEdge = min(leftEdge, lower)
                rightEdge = max(rightEdge, upper)
            }
            for index in slotCenters.indices {
                let point = motion(at: index)
                let isControl = index >= recentSlot
                let limit = isControl ? canvasWidth : visibleScrollEnd
                let shift = point.horizontalOffset + (isControl ? folderControlYield : 0)
                if let center = slotCenters[index] {
                    let halfWidth = iconWidths[index] * point.scale / 2
                    includeEdges(center + shift - halfWidth, center + shift + halfWidth, clippedAt: limit)
                } else if let bounds = stationaryTaskBounds[index] {
                    includeEdges(origin + bounds.lowerBound + shift, origin + bounds.upperBound + shift,
                        clippedAt: limit)
                }
            }
            if showsControls, !downloadTasks.isEmpty {
                let start = (showsInlineControls ? origin + contentEnd : scrollWidth) + taskbarItemSpacing
                    + (wave?.trailingTaskShift ?? 0) * progress + folderControlYield
                includeEdges(start, start + downloadsWidth - taskbarItemSpacing, clippedAt: canvasWidth)
            }
            let glassInsets = leftEdge.isFinite
                ? FavoriteMagnificationLayout.edgeInsets(for: leftEdge...rightEdge, canvasWidth: canvasWidth, margin: inset)
                : CGSize(width: clearance, height: clearance)
            let controls = AnyView(HStack(spacing: taskbarItemSpacing) {
                if showsControls {
                    Group {
                        if downloadTasks.count > 3 {
                            downloadGroupButton
                        } else {
                            ForEach(downloadTasks) { downloadTaskTile($0) }
                        }
                    }
                    .offset(x: (wave?.trailingTaskShift ?? 0) * progress)
                    recentApplicationsButton(motion: motion(at: recentSlot),
                        showsInlineNameHint: activeHover?.slot == recentSlot && minimalContextMenuID == nil,
                        isFavoriteMagnifying: false)
                        .overlay(alignment: .leading) {
                            if recentSeparatorSpacing > 0 {
                                let lastLaneSlot = appCenters.count + folders.count - 1
                                separator(before: recentSlot,
                                    after: showsInlineControls && downloadTasks.isEmpty && lastLaneSlot >= 0 ? lastLaneSlot : nil,
                                    leftOffset: downloadTasks.isEmpty ? nil : (wave?.trailingTaskShift ?? 0) * progress)
                            }
                        }
                        .padding(.leading, recentSeparatorSpacing)
                    minimalTrashButton(motion: motion(at: trashSlot), hovered: activeHover?.slot == trashSlot)
                        .overlay(alignment: .leading) { separator(before: trashSlot, after: recentSlot) }
                        .padding(.leading, separatorSpacing)
                }
                }
                .fixedSize(horizontal: true, vertical: false))
            let appLane = AnyView(HStack(spacing: taskbarItemSpacing) {
                ForEach(layout.keys, id: \.self) { key in
                    let group = groupsByID[key]
                    let window = group?.windows.first
                    let favorite = favoritesByID[key] ?? window.map {
                        FavoriteApp(id: key, bundleIdentifier: $0.bundleIdentifier,
                            applicationName: $0.applicationName, bundlePath: nil)
                    }
                    let start = groupStarts[key] ?? 0
                    Group {
                        if let group, group.windows.count > 1 {
                            windowGroup(group, itemWidths: widths, autoCollapsed: autoCollapsed,
                                hoverMotion: { motion(at: taskSlots[$0], followsDrag: draggedAppKey == key) })
                        } else if let favorite {
                            let slot = appSlots[key]
                            minimalAppButton(favorite, window: window, itemWidths: widths,
                                autoCollapsed: autoCollapsed, hovered: slot != nil && slot == activeHover?.slot,
                                motion: motion(at: slot, followsDrag: draggedAppKey == key))
                        }
                    }
                    .offset(x: gapOffset(for: start))
                }
                ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                    let slot = appCenters.count + index
                    let key = folderDragKey(folder)
                    let followsDrag = draggedAppKey == key
                    minimalFolderButton(folder, icon: folderIcons[index], hovered: slot == activeHover?.slot,
                        motion: motion(at: slot, followsDrag: followsDrag))
                        .overlay(alignment: .leading) {
                            if index == 0 && folderSeparatorSpacing > 0 {
                                separator(before: slot, after: slot - 1)
                            }
                        }
                        .offset(x: taskbarItemOffset(for: key)
                            + gapOffset(for: folderCenters[index] - folderIconWidth / 2))
                        .opacity(followsDrag && minimalRemoval.outsideSince != nil ? 0 : 1)
                        .zIndex(followsDrag ? 20 : 0)
                        .animation(followsDrag ? nil : appReorderAnimation, value: hoverTargetAppKey)
                        .simultaneousGesture(appReorderGesture(appKey: key, itemWidths: widths,
                            autoCollapsed: autoCollapsed, pickedUpIconMotion: motion(at: slot), folder: folder))
                        .padding(.leading, index == 0 ? folderSeparatorSpacing : 0)
                }
            }
            .frame(minWidth: showsInlineControls ? nil : laneWidth, alignment: .leading)
            .frame(height: taskbarBaseHeight)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: MinimalIconLaneOrigin.self,
                        value: geometry.frame(in: .named(minimalIconLaneSpace)).minX)
                }
            }
            .overlay(alignment: .leading) {
                ForEach(minimalDropGaps.keys.sorted(), id: \.self) { x in
                    let count = minimalDropGaps[x] ?? 0
                    let width = CGFloat(count) * minimalSlotWidth
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: max(0, width - taskbarItemSpacing), height: taskbarItemHeight)
                        .offset(x: x + gapOffset(for: x) - width)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: ["public.file-url"], delegate: MinimalFavoriteDropDelegate(
                preview: updateInsertionPreview(at:),
                accept: { providers, x in
                    let position = insertion(at: x)
                    return acceptFileDrop(providers) { urls in
                        addFavoriteURLs(urls, appIndex: settings.favoriteApps.count, folderIndex: position.folder,
                            minimalOrder: layout.keys, at: position.app)
                    }
                })))
            return HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: taskbarItemSpacing) {
                        appLane
                        if showsInlineControls { controls }
                    }
                    .padding(.horizontal, MinimalTaskbarSizing.contentInset * taskbarPanelScale)
                    .padding(.leading, clearance)
                    .padding(.trailing, showsInlineControls ? clearance : 0)
                    .padding(.top, headroom)
                }
                .frame(height: taskbarBaseHeight + headroom)
                .frame(width: showsInlineControls ? canvasWidth : scrollWidth + folderReveal)
                .padding(.trailing, -folderReveal)
                .frame(height: taskbarBaseHeight, alignment: .bottom)
                if showsControls && !showsInlineControls {
                    controls
                        .padding(.leading, taskbarItemSpacing)
                        .padding(.trailing, inset + clearance)
                        .offset(x: folderControlYield)
                }
            }
            .frame(height: taskbarBaseHeight)
            .onDisappear {
                clearMinimalRemoval()
                updateInsertionPreview(at: nil)
            }
            .background(MinimalIconRowTracker(slotCenters: slotCenters, hitRanges: hitRanges,
                tracksPosition: peakScale > 1,
                isFrozen: minimalContextMenuID != nil,
                followsDrag: peakScale > 1 && draggedAppKey != nil && !isSettlingAppDrag, onFrame: updateFrame))
            .coordinateSpace(name: minimalIconLaneSpace)
            .onPreferenceChange(MinimalIconLaneOrigin.self) { minimalIconLaneOrigin = $0 }
            .overlayPreferenceValue(MinimalIconHint.self) { hint in
                if draggedAppKey == nil, let hint {
                    GeometryReader { geometry in
                        minimalHintOverlay(hint, in: geometry)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .background {
                taskbarSurface(glassInsets: glassInsets)
                    .animation(reducesTaskbarMotion ? nil
                        : .easeInOut(duration: MinimalTaskbarSizing.widthAnimationDuration),
                        value: minimalIdleWidth)
            }
        }
    }

    private func minimalSeparator(offset: CGFloat, gap: CGFloat) -> some View {
        let width = FavoriteShelfSeparator.width * taskbarPanelScale
        let height = FavoriteShelfSeparator.height * taskbarPanelScale
        let bottom = FavoriteShelfSeparator.bottomInset * taskbarPanelScale + taskbarVisualLift
        return Capsule().fill(Color(nsColor: favoriteShelfSeparatorColor))
            .frame(width: width, height: height)
            .offset(x: offset - (gap + width) / 2, y: taskbarBaseHeight / 2 - bottom - height / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func minimalFolderButton(_ folder: FavoriteFolder, icon: NSImage, hovered: Bool, motion: MinimalIconMotion) -> some View {
        let open = { onOpenFolder(folder) }
        return Button(action: open) {
            Image(nsImage: icon)
                .resizable().scaledToFit()
                .frame(width: MinimalTaskbarSizing.folderIconSize * taskbarContentScale,
                    height: MinimalTaskbarSizing.folderIconSize * taskbarContentScale)
                .colorMultiply(favoritePressTint(minimalContextMenuID == folder.id))
                .minimalIconHint(folder.name, shown: hovered && minimalContextMenuID == nil)
                .scaleEffect(motion.scale)
                .offset(x: motion.horizontalOffset,
                    y: favoriteIconRestOffset - motion.lift)
                .frame(width: MinimalTaskbarSizing.iconSlotWidth * taskbarPanelScale, height: taskbarItemHeight)
                .offset(y: -taskbarVisualLift)
                .frame(width: MinimalTaskbarSizing.iconSlotWidth * taskbarPanelScale, height: taskbarBaseHeight)
                .background(Color.black.opacity(0.001))
                .contentShape(Rectangle())
        }
        .buttonStyle(MinimalIconButtonStyle())
        .accessibilityLabel(folder.name)
        .floatingBubbleContextMenu(actions: [
            FavoriteShelfMenuAction(title: "打开", perform: { onOpenFolder(folder) }),
            .separator,
            FavoriteShelfMenuAction(title: "取消收藏", perform: {
                settings.removeFavoriteFolder(folder)
                onSettingsChanged()
            })
        ], onIconClick: open, onVisibilityChange: { setMinimalContextMenu(folder.id, visible: $0) })
    }

    private func minimalTrashButton(motion: MinimalIconMotion, hovered: Bool) -> some View {
        Button(action: onOpenTrash) {
            Image(nsImage: FavoriteShelfItem.trash(isFull: trashStatus.isFull).lightTrashIcon)
                .renderingMode(.original)
                .resizable().scaledToFit()
                .frame(width: FavoriteMagnificationLayout.iconSize * taskbarContentScale,
                    height: FavoriteMagnificationLayout.iconSize * taskbarContentScale)
                .colorMultiply(favoritePressTint(minimalContextMenuID == WindowModel.trashAppKey))
                .minimalIconHint("废纸篓", shown: hovered && minimalContextMenuID == nil)
                .scaleEffect(motion.scale)
                .offset(x: motion.horizontalOffset, y: favoriteIconRestOffset - taskbarVisualLift - motion.lift)
                .frame(width: MinimalTaskbarSizing.iconSlotWidth * taskbarPanelScale, height: taskbarBaseHeight)
                .overlay(alignment: .bottom) {
                    favoriteRunningIndicator(isRunning: trashWindow != nil, motion: motion)
                }
                .background(Color.black.opacity(0.001))
                .contentShape(Rectangle())
        }
        .buttonStyle(MinimalIconButtonStyle())
        .accessibilityLabel("废纸篓")
        .floatingBubbleContextMenu(actions: trashMenuActions(isFull: trashStatus.isFull, open: onOpenTrash,
            restore: onRestoreLatestTrashItem, empty: onEmptyTrash,
            close: trashWindow.map { window in { onClose(window) } }), onIconClick: onOpenTrash,
            onVisibilityChange: { setMinimalContextMenu(WindowModel.trashAppKey, visible: $0) })
        .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
            acceptFileDrop(providers) { urls in
                do {
                    _ = try TrashActions.moveToTrash(urls.filter(\.isFileURL))
                    trashStatus.refresh(force: true)
                } catch { NSAlert(error: error).runModal() }
            }
        }
    }

    private func downloadTaskTile(_ task: BrowserDownloadTask) -> some View {
        DownloadTaskItemView(task: task, width: downloadItemWidth(task),
            height: taskbarItemHeight, scale: taskbarContentScale,
            fontSize: settings.taskbarItemFontSize,
            highlightStyle: settings.taskItemHighlightStyle,
            transparency: settings.nonSelectedItemTransparency,
            onOpenDownloads: { onPerformWindowAction { BrowserDownloadNavigation.open(task.browser) } },
            onOpenFile: { finished in onPerformWindowAction {
                BrowserDownloadNavigation.openFile(task, reveal: false) { success in
                    if success { windowProgress.dismissDownload(task) }
                    finished(success)
                }
            } },
            onRevealFile: { finished in onPerformWindowAction {
                BrowserDownloadNavigation.openFile(task, reveal: true) { success in
                    if success { windowProgress.dismissDownload(task) }
                    finished(success)
                }
            } },
            onClose: { windowProgress.dismissDownload(task) })
        .floatingBubbleContextMenu(actions: task.download.isComplete ? [
            FavoriteShelfMenuAction(title: "移除此下载任务", perform: { windowProgress.dismissDownload(task) })
        ] : [], iconCenterX: 17 * taskbarContentScale,
            onVisibilityChange: onRecentPopoverVisibilityChanged)
        .frame(width: downloadItemWidth(task), height: taskbarBaseHeight)
        .offset(y: -taskbarVisualLift)
        .help("\(task.download.filename) · \(task.browser.label) · \(task.status)")
    }

    private var downloadGroupButton: some View {
        let allDownloadsComplete = downloadTasks.allSatisfy { $0.download.isComplete }
        return Button { downloadsExpanded.toggle() } label: {
            HStack(spacing: 5 * taskbarContentScale) {
                if allDownloadsComplete {
                    CompletedDownloadIcon(size: 18 * taskbarContentScale)
                        .frame(width: 21 * taskbarContentScale,
                            height: 21 * taskbarContentScale)
                } else {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 16 * taskbarContentScale, weight: .semibold))
                        .frame(width: 21 * taskbarContentScale,
                            height: 21 * taskbarContentScale)
                }
                Text(TaskbarItemSizing.downloadGroupTitle(downloadTasks.count))
                    .font(.system(size: max(9.5, settings.taskbarItemFontSize) * taskbarContentScale,
                        weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.up")
                    .font(.system(size: 9 * taskbarContentScale, weight: .semibold))
                    .frame(width: 14 * taskbarContentScale)
                    .foregroundStyle(Color.secondary)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 9 * taskbarContentScale)
            .frame(maxWidth: .infinity)
            .frame(height: taskbarItemHeight)
            .background {
                TaskbarReadableItemSurface(cornerRadius: 7 * taskbarContentScale,
                    isHovered: downloadButtonHovered, isFocused: downloadsExpanded,
                    transparency: settings.nonSelectedItemTransparency)
                RoundedRectangle(cornerRadius: 7 * taskbarContentScale)
                    .fill(Color.accentColor.opacity(downloadsExpanded ? 0.18
                        : downloadButtonHovered ? 0.10 : 0))
                RoundedRectangle(cornerRadius: 7 * taskbarContentScale)
                    .stroke(Color.accentColor.opacity(downloadsExpanded ? 0.46
                        : downloadButtonHovered ? 0.28 : 0), lineWidth: 0.7)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7 * taskbarContentScale))
        }
        .buttonStyle(.plain)
        .frame(width: TaskbarItemSizing.downloadGroupWidth(count: downloadTasks.count,
            fontSize: settings.taskbarItemFontSize, scale: taskbarContentScale))
        .onHover { downloadButtonHovered = $0 }
        .accessibilityLabel("\(downloadsExpanded ? "收起" : "展开") \(downloadTasks.count) 个下载任务")
        .floatingBubbleWindow(isPresented: $downloadsExpanded) {
            downloadListPopover
        }
        .onChange(of: downloadsExpanded) { onRecentPopoverVisibilityChanged($0) }
        .onChange(of: downloadTasks.count) { if $0 <= 3 { downloadsExpanded = false } }
        .onDisappear {
            downloadsExpanded = false
            downloadButtonHovered = false
            onRecentPopoverVisibilityChanged(false)
        }
        .frame(height: taskbarBaseHeight)
        .offset(y: -taskbarVisualLift)
    }

    private func acceptFileDrop(_ providers: [NSItemProvider], perform: @escaping ([URL]) -> Void) -> Bool {
        guard !providers.isEmpty else { return false }
        // Start every file request before the drop session is released by Finder.
        let group = DispatchGroup()
        var urls = Array<URL?>(repeating: nil, count: providers.count)
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    urls[index] = url
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let incoming = urls.compactMap { $0 }
            if !incoming.isEmpty { perform(incoming) }
        }
        return true
    }

    @discardableResult
    private func addFavoriteURLs(_ urls: [URL], appIndex: Int, folderIndex: Int,
                                 minimalOrder: [String] = [], at minimalIndex: Int? = nil) -> Bool {
        var visibleOrder = minimalOrder
        var nextPosition = minimalIndex
        var nextApp = appIndex
        var nextFolder = folderIndex
        for url in FavoriteShelfDrop.supportedURLs(urls) {
            if url.pathExtension.lowercased() == "app" {
                if settings.addFavorite(applicationURL: url, at: nextApp) {
                    if let position = nextPosition {
                        let key = settings.favoriteApps[min(nextApp, settings.favoriteApps.count - 1)].id
                        let oldIndex = visibleOrder.firstIndex(of: key)
                        if let oldIndex { visibleOrder.remove(at: oldIndex) }
                        let insertion = min(visibleOrder.count, position - (oldIndex.map { $0 < position } == true ? 1 : 0))
                        visibleOrder.insert(key, at: insertion)
                        nextPosition = insertion + 1
                    }
                    nextApp += 1
                }
            } else if settings.addFavoriteFolder(url, at: nextFolder) {
                nextFolder += 1
            }
        }
        let added = nextApp != appIndex || nextFolder != folderIndex
        if added {
            if minimalIndex != nil { settings.applyMinimalVisibleAppOrder(visibleOrder) }
            onSettingsChanged()
        }
        return added
    }

    private var downloadTasks: [BrowserDownloadTask] {
        settings.layoutMode.isTaskbar && showsControls ? windowProgress.downloads : []
    }

    private func downloadItemWidth(_ task: BrowserDownloadTask) -> CGFloat {
        TaskbarItemSizing.downloadWidth(title: task.download.filename, isComplete: task.download.isComplete,
            mode: settings.taskbarItemWidthMode, fontSize: settings.taskbarItemFontSize, scale: taskbarPanelScale)
    }

    private var extraSingleIconApps: [FavoriteApp] {
        guard settings.layoutMode == .taskbar, showsFavorites, !settings.singleIconAppIDs.isEmpty else { return [] }
        var seen = Set(settings.displayedFavoriteApps.map(\.id))
        return orderedWindows.compactMap { window in
            guard settings.singleIconAppIDs.contains(window.appKey), seen.insert(window.appKey).inserted else { return nil }
            return FavoriteApp(id: window.appKey, bundleIdentifier: window.bundleIdentifier,
                applicationName: window.applicationName,
                bundlePath: NSRunningApplication(processIdentifier: window.pid)?.bundleURL?.path)
        }
    }

    private var shelfApps: [FavoriteApp] {
        settings.layoutMode.isTaskbar ? settings.displayedFavoriteApps + extraSingleIconApps : settings.favoriteApps
    }

    private var showsRecentApps: Bool {
        settings.layoutMode == .taskbar && showsControls
    }

    private func recentApplicationsButton(motion: MinimalIconMotion = MinimalIconMotion(),
                                          showsInlineNameHint: Bool = false,
                                          isFavoriteMagnifying: Bool? = nil,
                                          embedsIcon: Bool = true) -> some View {
        RecentApplicationDockView(
            settings: settings,
            popoverState: recentAppPopoverState,
            sizeScale: taskbarPanelScale,
            isDark: colorScheme == .dark,
            visualLift: taskbarVisualLift,
            motion: motion,
            extendsHitToBottom: minimalMode,
            showsInlineNameHint: showsInlineNameHint,
            blurredByFavorites: (isFavoriteMagnifying ?? favoriteMagnificationActive) && !magnificationPushesTasks,
            embedsIcon: embedsIcon,
            onOpen: onOpenFavorite,
            onQuit: onQuitRecentApp,
            onFavorite: { app in
                let added = settings.addFavorite(app)
                if added { onSettingsChanged() }
                return added
            },
            onUnfavorite: { app in
                settings.removeFavorite(app)
                onSettingsChanged()
            },
            onPopoverVisibilityChanged: onRecentPopoverVisibilityChanged
        )
    }

    private var taskbarView: some View {
        GeometryReader { geometry in
            HStack(spacing: settings.layoutMode.isTaskbar ? 0 : 8) {
                if !isAccessibilityTrusted {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield")
                        Text("需要“辅助功能”权限才能读取和切换窗口")
                        Button("打开设置", action: onRequestPermission)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.leading, 14)
                    Spacer(minLength: 0)
                } else if minimalMode {
                    let width = minimalCanvasWidth ?? geometry.size.width
                    Color.clear
                        .frame(width: max(0, geometry.size.width - 2 * effectiveSideInset), height: taskbarBaseHeight)
                        .overlay(alignment: .bottom) {
                            minimalContent(availableWidth: width)
                                .frame(width: max(0, width - 2 * effectiveSideInset))
                        }
                } else {
                    if showsFavorites {
                        FavoriteDockView(
                            favorites: shelfApps,
                            transientAppIDs: Set((settings.dockTransientApps + extraSingleIconApps).map(\.id)),
                            folders: settings.layoutMode.isTaskbar && showsControls
                                ? settings.favoriteFolders : [],
                            showsTrash: settings.layoutMode.isTaskbar && showsControls,
                            showsApplications: showsRecentApps,
                            suppressApplicationsHoverLabel: recentAppPopoverState.isPresented
                                || recentAppHoverBehavior == RecentAppHoverBehavior.programList.rawValue,
                            isTrashFull: trashStatus.isFull,
                            runningApplicationIDs: trashWindow == nil ? runningApplicationIDs
                                : runningApplicationIDs.union([WindowModel.trashAppKey]),
                            badgeLabels: favoriteBadges.badges,
                            shortcutIndices: settings.layoutMode.isTaskbar
                                ? settings.activeFavoriteShortcutIndices : [],
                            hoverFeedbackEnabled: settings.favoriteMagnificationEnabled,
                            configuredPeakScale: settings.favoriteMagnificationScale,
                            keepsSystemFinder: settings.dockFavoritesSyncEnabled,
                            reducesMotion: reducesTaskbarMotion,
                            hitRegionWidth: settings.layoutMode.isTaskbar
                                ? TaskbarFavoriteLaneLayout.contentWidth(
                                    appCount: shelfApps.count,
                                    folderCount: showsControls ? settings.favoriteFolders.count : 0,
                                    showsTrash: showsControls,
                                    showsApplications: showsRecentApps) * taskbarPanelScale
                                : nil,
                            showsHoverLabel: settings.layoutMode.isTaskbar,
                            sizeScale: taskbarPanelScale,
                            visualLift: taskbarVisualLift,
                            onOpen: onOpenFavorite,
                            onPerformWindowAction: onPerformWindowAction,
                            onQuit: onQuitRecentApp,
                            onOpenTrash: onOpenTrash,
                            onCloseTrash: trashWindow.map { window in { onClose(window) } },
                            onEmptyTrash: onEmptyTrash,
                            onRestoreLatestTrashItem: onRestoreLatestTrashItem,
                            onOpenFolder: onOpenFolder,
                            onRemove: { favorite in
                                settings.removeFavorite(favorite)
                                onSettingsChanged()
                            },
                            onPinTransient: { favorite in
                                if settings.addFavorite(favorite) { onSettingsChanged() }
                            },
                            displayMenuActions: { app in
                                guard settings.layoutMode.isTaskbar else { return [] }
                                var actions = [singleIconMenuAction(for: app.id)]
                                if settings.singleIconAppIDs.contains(app.id),
                                   let window = orderedWindows.first(where: { $0.appKey == app.id }) {
                                    actions.append(FavoriteShelfMenuAction(title: "显示该 App 的所有窗口",
                                        perform: { onShowAppWindows(window) }))
                                }
                                return actions
                            },
                            onReorder: { orderedIDs in
                                settings.reorderFavorites(orderedIDs.filter { settings.isFavorite($0) })
                            },
                            onRemoveFolder: { folder in
                                settings.removeFavoriteFolder(folder)
                                onSettingsChanged()
                            },
                            onReorderFolders: { settings.reorderFavoriteFolders($0) },
                            onDropURLs: { urls, insertion in
                                addFavoriteURLs(urls, appIndex: insertion.appIndex, folderIndex: insertion.folderIndex)
                            },
                            onDragChanged: onAppDragChanged,
                            onHoverActivity: onFavoriteHoverActivity,
                            onMagnificationChange: { active in
                                if favoriteMagnificationActive != active {
                                    favoriteMagnificationActive = active
                                    let reservation = active && magnificationPushesTasks ? TaskbarFavoriteLaneLayout.hoverTrailingSpace(
                                        appCount: shelfApps.count,
                                        folderCount: showsControls ? settings.favoriteFolders.count : 0,
                                        showsTrash: showsControls,
                                        showsApplications: showsRecentApps,
                                        sizeScale: taskbarPanelScale,
                                        peakScale: favoritePeakScale) : 0
                                    withAnimation(reducesTaskbarMotion ? nil : .easeOut(duration: active
                                        ? FavoriteMagnificationTiming.entryDuration
                                        : FavoriteMagnificationTiming.exitDuration)) {
                                        favoriteHoverTrailingSpace = reservation
                                    }
                                }
                            },
                            onMagnificationBoundsChange: { leading, _ in
                                var transaction = Transaction(animation: nil)
                                transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    favoriteLeadingExtension = leading
                                }
                            },
                            onClickApplications: { anchorOffset, anchorSize in
                                recentAppPopoverState.anchorOffset = anchorOffset
                                recentAppPopoverState.anchorSize = anchorSize
                                recentAppPopoverState.clickRequest += 1
                            },
                            onHoverApplications: { hovered, anchorOffset, anchorSize in
                                if hovered {
                                    recentAppPopoverState.anchorOffset = anchorOffset
                                    recentAppPopoverState.anchorSize = anchorSize
                                }
                                if recentAppPopoverState.externalHovered != hovered {
                                    recentAppPopoverState.externalHovered = hovered
                                }
                            },
                            applicationsAnchorView: showsRecentApps
                                ? AnyView(recentApplicationsButton(isFavoriteMagnifying: false, embedsIcon: false))
                                : nil
                        )
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: settings.layoutMode.isTaskbar
                            ? TaskbarFavoriteLaneLayout.contentWidth(
                                appCount: shelfApps.count,
                                folderCount: showsControls ? settings.favoriteFolders.count : 0,
                                showsTrash: showsControls,
                                showsApplications: showsRecentApps) * taskbarPanelScale
                                + (magnificationPushesTasks ? favoriteHoverTrailingSpace : 0)
                            : nil, alignment: .leading)
                        .padding(.leading, settings.layoutMode.isTaskbar
                            ? 5 * taskbarPanelScale : 0)
                        .zIndex(settings.layoutMode.isTaskbar ? 2 : 0)

                        if !windows.isEmpty || !downloadTasks.isEmpty {
                            Divider()
                                .frame(height: FavoriteShelfSeparator.height * taskbarPanelScale)
                                .offset(y: -taskbarVisualLift)
                        }
                    }

                    if showsRecentApps && !showsFavorites {
                        recentApplicationsButton()
                        if !windows.isEmpty || !downloadTasks.isEmpty {
                            Divider()
                                .frame(height: FavoriteShelfSeparator.height * taskbarPanelScale)
                                .offset(y: -taskbarVisualLift)
                        }
                    }

                    if windows.isEmpty && downloadTasks.isEmpty && showsEmptyState {
                        Spacer(minLength: 0)
                    } else if !windows.isEmpty || !downloadTasks.isEmpty {
                        taskItemLane { availableWidth in
                        let autoCollapsed = autoCollapsedAppKeys(for: availableWidth)
                        let itemWidths = taskItemWidths(for: geometry.size.width
                            - (settings.layoutMode.isTaskbar ? 2 * effectiveSideInset : 0),
                            autoCollapsed: autoCollapsed)
                        HStack(spacing: taskbarItemSpacing) {
                            if downloadTasks.count > 3 { downloadGroupButton }
                            ForEach(downloadTasks.count > 3 ? [] : downloadTasks) { task in
                                downloadTaskTile(task)
                            }
                            ForEach(appGroups) { group in
                                windowGroup(group, itemWidths: itemWidths, autoCollapsed: autoCollapsed)
                            }
                        }
                        .padding(
                            .leading,
                            showsFavorites || showsRecentApps
                                ? 0
                                : (settings.layoutMode == .dockCompanion ? 2 : 8) * taskbarPanelScale
                        )
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }

                if showsControls && settings.layoutMode == .dockCompanion
                    && settings.dockCompanionShowsBottomBar {
                    HStack(spacing: 2 * taskbarPanelScale) {
                        TaskbarControlButton(
                            systemImage: canRestoreHiddenApplications ? "rectangle.stack" : "arrow.down.to.line",
                            help: canRestoreHiddenApplications ? "恢复刚才隐藏的 App" : "隐藏全部 App",
                            scale: taskbarContentScale,
                            isTaskbarMode: false,
                            action: onToggleAllApplications
                        )
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .padding(.horizontal, 8 * taskbarPanelScale)
                }
            }
            .frame(height: taskbarBaseHeight)
            .padding(.leading, settings.layoutMode.isTaskbar
                ? effectiveSideInset : 0)
            .padding(.trailing, settings.layoutMode.isTaskbar
                ? effectiveSideInset : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .background(alignment: .bottom) {
            if (!minimalMode || !isAccessibilityTrusted)
                && (settings.layoutMode.isTaskbar || !windows.isEmpty || (showsControls && settings.dockCompanionShowsBottomBar)) {
                taskbarSurface()
                    .padding(.leading, settings.layoutMode.isTaskbar
                        ? max(0, effectiveSideInset - favoriteLeadingExtension) : 0)
                    .padding(.trailing, settings.layoutMode.isTaskbar ? effectiveSideInset : 0)
            }
        }
        .padding(.horizontal, settings.layoutMode.isTaskbar ? 0 : 2)
        .padding(.top, 2)
        .padding(.bottom, settings.layoutMode.isTaskbar ? 0 : 2)
    }

    private func taskbarSurface(glassInsets: CGSize = .zero) -> some View {
        let cornerRadius = min(18, taskbarBaseHeight * 0.34)
        return TaskbarGlassOutline(insets: glassInsets, cornerRadius: cornerRadius,
            glassOpacity: 1 - settings.taskbarBackgroundTransparency,
            tintOpacity: 1 - blackBackgroundTransparency)
            .frame(height: taskbarBaseHeight)
            .offset(y: -taskbarVisualLift)
    }

    @ViewBuilder
    private func taskItemLane<Content: View>(@ViewBuilder content: @escaping (CGFloat) -> Content) -> some View {
        if settings.layoutMode.isTaskbar {
            TaskbarItemLane(content: content)
        } else {
            content(.infinity)
        }
    }

    private var downloadListPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("下载任务（\(downloadTasks.count)）")
                .font(.headline)
                .padding(.bottom, 4)
            if downloadTasks.isEmpty {
                Text("暂无下载任务")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(downloadTasks) { task in downloadPopoverRow(task) }
                    }
                }
                .frame(height: min(420, CGFloat(downloadTasks.count) * 32
                    + CGFloat(max(0, downloadTasks.count - 1)) * 4))
            }
        }
        .padding(12)
        .frame(width: 355)
    }

    private func downloadPopoverRow(_ task: BrowserDownloadTask) -> some View {
        DownloadBubbleRow(task: task,
            onOpenDownloads: {
                downloadsExpanded = false
                onPerformWindowAction { BrowserDownloadNavigation.open(task.browser) }
            },
            onOpenFile: { finished in
                downloadsExpanded = false
                onPerformWindowAction {
                    BrowserDownloadNavigation.openFile(task, reveal: false) { success in
                        if success { windowProgress.dismissDownload(task) }; finished(success)
                    }
                }
            },
            onRevealFile: { finished in
                downloadsExpanded = false
                onPerformWindowAction {
                    BrowserDownloadNavigation.openFile(task, reveal: true) { success in
                        if success { windowProgress.dismissDownload(task) }; finished(success)
                    }
                }
            },
            onClose: { windowProgress.dismissDownload(task) })
            .help("\(task.download.filename) · \(task.browser.label) · \(task.status)")
    }

    private func collapsedGroupMenuActions(_ group: AppWindowGroup) -> [FavoriteShelfMenuAction] {
        let representative = group.windows.first(where: \.isFocused) ?? group.windows[0]
        return windowFavoriteMenuActions(representative) + [
            FavoriteShelfMenuAction(title: "显示该 App 的所有窗口", perform: { onShowAppWindows(representative) }),
            .separator,
            FavoriteShelfMenuAction(title: "屏蔽此类窗口", perform: { onBlockWindowType(representative) }),
            .separator,
            FavoriteShelfMenuAction(title: "关闭该窗口组", perform: { onCloseGroup(group.windows) })
        ]
    }

    private func autoCollapsedAppKeys(for availableWidth: CGFloat) -> Set<String> {
        guard settings.layoutMode.isTaskbar, !appGroups.isEmpty else { return [] }
        let scale = taskbarPanelScale
        let precedingWidths: [CGFloat]
        if minimalMode {
            let idleFavorites = settings.displayedFavoriteApps.filter { favorite in
                !appGroups.contains { $0.id == favorite.id }
            }.count
            precedingWidths = Array(repeating: MinimalTaskbarSizing.iconSlotWidth * scale, count: idleFavorites + settings.favoriteFolders.count)
        } else if downloadTasks.count > 3 {
            precedingWidths = [TaskbarItemSizing.downloadGroupWidth(count: downloadTasks.count,
                fontSize: settings.taskbarItemFontSize, scale: taskbarContentScale)]
        } else {
            precedingWidths = downloadTasks.map(downloadItemWidth)
        }
        let groups = appGroups.map { group in
            let widths = group.windows.map { window in
                if minimalMode && group.windows.count == 1 { return MinimalTaskbarSizing.iconSlotWidth * scale }
                return taskbarWindowWidth(title: TaskbarItemSizing.displayTitle(window.title,
                    bundleIdentifier: window.bundleIdentifier))
            }
            return TaskbarOverflowGroup(
                id: group.id, windowCount: group.windows.count,
                expandedWidth: widths.reduce(0, +)
                    + CGFloat(max(widths.count - 1, 0)) * taskbarItemSpacing,
                collapsedWidth: settings.singleIconAppIDs.contains(group.id)
                    ? MinimalTaskbarSizing.iconSlotWidth * scale
                    : taskbarWindowWidth(title: "\(group.windows[0].applicationName) (\(group.windows.count))"),
                isAlreadyCollapsed: baseTaskbarCollapse(group),
                containsFocusedWindow: group.windows.contains(where: \.isFocused)
            )
        }
        return TaskbarOverflowLayout.additionalCollapsedIDs(
            groups: groups, precedingItemWidths: precedingWidths,
            availableWidth: availableWidth, spacing: taskbarItemSpacing,
            leadingPadding: minimalMode || showsFavorites || showsRecentApps ? 0 : 8 * scale
        )
    }

    private func taskbarWindowWidth(title: String) -> CGFloat {
        settings.taskbarWindowWidth(title: title, scale: taskbarPanelScale)
    }

    private func taskItemWidths(for totalWidth: CGFloat, autoCollapsed: Set<String>) -> [String: CGFloat] {
        let fusionWidth = settings.layoutMode == .dockCompanion ? taskbarItemWidth(for: totalWidth) : 0
        return Dictionary(uniqueKeysWithValues: appGroups.flatMap { group in
            group.windows.map { window in
                let width: CGFloat
                if settings.layoutMode == .dockCompanion {
                    width = fusionWidth
                } else if settings.singleIconAppIDs.contains(group.id) {
                    width = MinimalTaskbarSizing.iconSlotWidth * taskbarPanelScale
                } else {
                    let title = isCollapsed(group, autoCollapsed: autoCollapsed)
                        ? "\(window.applicationName) (\(group.windows.count))"
                        : TaskbarItemSizing.displayTitle(window.title, bundleIdentifier: window.bundleIdentifier)
                    width = taskbarWindowWidth(title: title)
                }
                return (window.id, width)
            }
        })
    }

    private func taskbarItemWidth(for totalWidth: CGFloat) -> CGFloat {
        guard !windows.isEmpty else { return 0 }
        let controlsAndPadding: CGFloat
        if settings.layoutMode == .dockCompanion {
            if !showsControls {
                controlsAndPadding = 0
            } else {
                controlsAndPadding = (settings.dockCompanionShowsBottomBar ? 48 : 8) * taskbarPanelScale
            }
        } else {
            controlsAndPadding = 16 * taskbarPanelScale
        }
        let favoriteItemCount = shelfApps.count
            + (settings.layoutMode.isTaskbar && showsControls ? 1 + settings.favoriteFolders.count : 0)
            + (showsRecentApps ? 1 : 0)
        let favoriteWidth: CGFloat
        if !showsFavorites || favoriteItemCount == 0 {
            favoriteWidth = 0
        } else if settings.layoutMode.isTaskbar {
            favoriteWidth = TaskbarFavoriteLaneLayout.contentWidth(
                appCount: shelfApps.count,
                folderCount: showsControls ? settings.favoriteFolders.count : 0,
                showsTrash: showsControls,
                showsApplications: showsRecentApps) * taskbarPanelScale
                + 5 * taskbarPanelScale
        } else {
            favoriteWidth = (CGFloat(favoriteItemCount) * 32
                + CGFloat(max(favoriteItemCount - 1, 0)) * 2 + 14) * taskbarPanelScale
                + FavoriteMagnificationLayout.idleSideClearance(for: taskbarPanelScale)
        }
        let recentApplicationWidth: CGFloat = showsRecentApps && !showsFavorites ? 40 * taskbarPanelScale : 0
        let displayCount = appGroups.reduce(0) { $0 + (isCollapsed($1) ? 1 : $1.windows.count) }
        let totalSpacing = CGFloat(max(displayCount - 1, 0)) * taskbarItemSpacing
        let available = max(
            totalWidth - controlsAndPadding - favoriteWidth - recentApplicationWidth - totalSpacing,
            0
        )
        let maximumWidth = settings.layoutMode == .dockCompanion
            ? DockCompanionSizing.maximumItemWidth(for: settings.dockCompanionHeight)
            : 148 * taskbarPanelScale
        let minimumWidth = settings.layoutMode == .dockCompanion
            ? DockCompanionSizing.minimumItemWidth(for: settings.dockCompanionHeight)
            : 27 * taskbarPanelScale
        return min(maximumWidth, max(minimumWidth, available / CGFloat(displayCount)))
    }

    private var taskbarBaseHeight: CGFloat {
        settings.layoutMode == .dockCompanion ? settings.dockCompanionHeight : settings.taskbarHeight
    }

    private var taskbarPanelScale: CGFloat {
        settings.layoutMode == .dockCompanion
            ? DockCompanionSizing.scale(for: settings.dockCompanionHeight)
            : settings.taskbarHeight / SettingsStore.layoutReferenceTaskbarHeight
    }

    private var taskbarContentScale: CGFloat {
        settings.layoutMode == .dockCompanion
            ? DockCompanionSizing.contentScale(for: settings.dockCompanionHeight)
            : settings.taskbarHeight / SettingsStore.layoutReferenceTaskbarHeight
    }

    private var taskbarItemHeight: CGFloat {
        taskbarBaseHeight - 7 * taskbarPanelScale
    }

    private var taskbarItemSpacing: CGFloat {
        switch settings.layoutMode {
        case .dockCompanion: return DockCompanionSizing.itemSpacing(for: settings.dockCompanionHeight)
        case .minimal: return MinimalTaskbarSizing.itemSpacing * taskbarPanelScale
        case .taskbar: return 4 * taskbarPanelScale
        }
    }

    private var appReorderAnimation: Animation {
        reducesTaskbarMotion ? .easeOut(duration: 0.08) : settings.layoutMode.isTaskbar
            ? .spring(response: 0.30, dampingFraction: 0.86)
            : .easeOut(duration: 0.16)
    }

    private var orderedWindows: [WindowModel] {
        settings.orderedWindows(windows)
    }

    private func shortcutLabel(for window: WindowModel) -> String? {
        let isCompanionLeft = settings.layoutMode == .dockCompanion && !showsControls
        let labels = isCompanionLeft
            ? OptionWindowHotKeyMonitor.favoriteShortcutLabels.prefix(8).map { $0 }
            : settings.layoutMode == .dockCompanion
                ? OptionWindowHotKeyMonitor.windowShortcutLabels.prefix(5).map { $0 }
                : OptionWindowHotKeyMonitor.windowShortcutLabels
        let registeredIndices = isCompanionLeft
            ? settings.activeFavoriteShortcutIndices : settings.activeTaskbarShortcutIndices
        let shortcutWindows = settings.layoutMode == .dockCompanion
            ? fusionShortcutWindows : orderedWindows
        guard let index = shortcutWindows.prefix(labels.count)
                .firstIndex(where: { $0.id == window.id }),
              registeredIndices.contains(index + 1) else { return nil }
        return labels[index]
    }

    private func singleIconMenuAction(for appID: String) -> FavoriteShelfMenuAction {
        let singleIcon = settings.singleIconAppIDs.contains(appID)
        return FavoriteShelfMenuAction(title: singleIcon ? "恢复任务项显示" : "显示为单图标",
            symbol: singleIcon ? "rectangle.split.2x1" : "app", perform: {
                settings.toggleSingleIcon(for: appID)
                onSettingsChanged()
            })
    }

    private func windowFavoriteMenuActions(_ window: WindowModel) -> [FavoriteShelfMenuAction] {
        guard !window.isTrashWindow else { return [] }
        var actions = [FavoriteShelfMenuAction(title: favoriteMenuTitle(for: window), symbol: "star",
            perform: { toggleFavorite(window) })]
        if settings.layoutMode.isTaskbar { actions.append(singleIconMenuAction(for: window.appKey)) }
        actions.append(.separator)
        return actions
    }

    private func favoriteMenuTitle(for window: WindowModel) -> String {
        settings.isFavorite(window.appKey) ? "取消收藏" : "固定到收藏"
    }

    private func toggleFavorite(_ window: WindowModel) {
        settings.toggleFavorite(for: window)
        onSettingsChanged()
    }

    private var appGroups: [AppWindowGroup] {
        let grouped = Dictionary(grouping: orderedWindows, by: \.appKey)
        var seen = Set<String>()
        return orderedWindows.compactMap { window in
            if settings.layoutMode == .taskbar, showsFavorites, settings.singleIconAppIDs.contains(window.appKey) {
                return nil
            }
            guard seen.insert(window.appKey).inserted,
                  let groupedWindows = grouped[window.appKey] else { return nil }
            return AppWindowGroup(id: window.appKey, windows: groupedWindows)
        }
    }

    private var fusionShortcutWindows: [WindowModel] {
        var result: [WindowModel] = []
        for group in appGroups {
            if group.windows.count >= settings.dockCompanionCollapseThreshold {
                result.append(group.windows.first(where: \.isFocused) ?? group.windows[0])
            } else {
                result.append(contentsOf: group.windows)
            }
        }
        return result
    }

    private func taskbarReorderGesture(for window: WindowModel, itemWidths: [String: CGFloat],
                                       autoCollapsed: Set<String>) -> some Gesture {
        appReorderGesture(appKey: window.appKey, itemWidths: itemWidths, autoCollapsed: autoCollapsed)
    }

    private func appReorderGesture(appKey: String, itemWidths: [String: CGFloat],
                                   autoCollapsed: Set<String>, pickedUpIconMotion: MinimalIconMotion? = nil,
                                   folder: FavoriteFolder? = nil) -> some Gesture {
        // A slightly larger threshold keeps normal clicks with small hand motion
        // from being interpreted as app-reordering drags.
        DragGesture(minimumDistance: FavoriteShelfInteractionMetrics.dragDistance, coordinateSpace: .global)
            .onChanged { value in
                guard !isSettlingAppDrag, !NSEvent.modifierFlags.contains(.option) else { return }
                if draggedAppKey == nil {
                    let groups = folder == nil
                        ? taskbarAppGroupLayout(itemWidths: itemWidths, autoCollapsed: autoCollapsed)
                        : minimalFolderDragLayout()
                    guard groups.keys.contains(appKey) else { return }
                    draggedIconMotion = pickedUpIconMotion.map { motion in
                        // A quick drag can begin before the first hover frame arrives.
                        guard motion.scale == 1 else { return motion }
                        var result = motion
                        result.scale = favoritePeakScale
                        let iconSize = folder == nil ? MinimalTaskbarSizing.applicationIconSize : MinimalTaskbarSizing.folderIconSize
                        result.lift = FavoriteMagnificationLayout.centerLift(for: result.scale,
                            iconHeight: iconSize * taskbarContentScale, sizeScale: taskbarContentScale)
                        return result
                    }
                    draggedAppKey = appKey
                    dragStartAppKeys = groups.keys
                    dragStartGroupLayout = groups
                    onAppDragChanged(true)
                }

                guard draggedAppKey == appKey else { return }
                dragTranslation = value.translation.width
                let isFixedFinder = settings.dockFavoritesSyncEnabled && appKey == "com.apple.finder"
                if minimalMode, folder != nil || (settings.isFavorite(appKey) && !isFixedFinder) {
                    updateMinimalRemoval(appKey: appKey, folder: folder)
                }
                if let dragStartGroupLayout {
                    updateDropTarget(in: dragStartGroupLayout)
                }
            }
            .onEnded { value in
                guard draggedAppKey == appKey else { return }
                let outside = minimalRemoval.outsideSince != nil && isOutsideMinimalShelf()
                let shouldRemove = minimalRemoval.shouldRemove(onReleaseOutside: outside,
                    now: ProcessInfo.processInfo.systemUptime)
                clearMinimalRemoval()
                if shouldRemove {
                    if let folder { settings.removeFavoriteFolder(folder) }
                    else if let favorite = settings.favoriteApps.first(where: { $0.id == appKey }) {
                        settings.removeFavorite(favorite)
                    }
                    draggedAppKey = nil
                    draggedIconMotion = nil
                    dragTranslation = 0
                    dragStartAppKeys = nil
                    dragStartGroupLayout = nil
                    hoverTargetAppKey = nil
                    dragDirection = nil
                    pendingDropToken = nil
                    pendingDropCandidate = nil
                    onAppDragChanged(false)
                    onSettingsChanged()
                    return
                }
                if outside {
                    pendingDropToken = nil
                    pendingDropCandidate = nil
                    hoverTargetAppKey = nil
                    dragDirection = nil
                }
                finishAppReorder(in: dragStartGroupLayout
                    ?? taskbarAppGroupLayout(itemWidths: itemWidths, autoCollapsed: autoCollapsed),
                    spacing: taskbarItemSpacing, reordersFolders: folder != nil)
            }
    }

    private func folderDragKey(_ folder: FavoriteFolder) -> String { "utility:folder:\(folder.id)" }

    private func minimalFolderDragLayout() -> AppGroupLayout {
        let keys = settings.favoriteFolders.map(folderDragKey)
        let starts = keys.indices.map { CGFloat($0) * minimalSlotWidth }
        return AppGroupLayout(keys: keys, minXs: starts,
            maxXs: starts.map { $0 + MinimalTaskbarSizing.iconSlotWidth * taskbarPanelScale })
    }

    private func isOutsideMinimalShelf() -> Bool {
        guard let panel = NSApp.windows.first(where: {
            $0.isVisible && $0.contentView is TaskbarNativeContentView
        }) else { return false }
        let frame = CGRect(x: panel.frame.minX, y: panel.frame.minY, width: panel.frame.width,
            height: taskbarBaseHeight).insetBy(dx: -10, dy: -10)
        return !frame.contains(NSEvent.mouseLocation)
    }

    private func updateMinimalRemoval(appKey: String, folder: FavoriteFolder?) {
        let outside = isOutsideMinimalShelf()
        if !outside {
            if minimalRemoval.outsideSince != nil { clearMinimalRemoval() }
            return
        }
        if minimalRemoval.outsideSince == nil {
            minimalRemoval.update(isOutside: true, now: ProcessInfo.processInfo.systemUptime)
            let icon = folder.map(FavoriteFolderIcon.image)
                ?? settings.favoriteApps.first(where: { $0.id == appKey })
                    .map { FavoriteApplicationIcon.image(for: $0, date: Date()) }
            let preview = FavoriteDragPreviewView(icon: icon,
                iconSize: FavoriteMagnificationLayout.iconSize * taskbarContentScale * (draggedIconMotion?.scale ?? 1))
            let panel = NSPanel(contentRect: preview.bounds,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = preview
            minimalDragPreview = panel
            let work = DispatchWorkItem { [weak preview] in
                if isOutsideMinimalShelf() { preview?.setReady(true) }
            }
            minimalRemovalTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + FavoriteDragRemovalState.delay, execute: work)
        }
        if let panel = minimalDragPreview {
            let mouse = NSEvent.mouseLocation
            panel.setFrameOrigin(NSPoint(x: mouse.x - panel.frame.width / 2, y: mouse.y - panel.frame.height / 2))
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    private func clearMinimalRemoval() {
        minimalRemovalTimer?.cancel()
        minimalRemovalTimer = nil
        minimalRemoval.cancel()
        minimalDragPreview?.orderOut(nil)
        minimalDragPreview = nil
    }

    private func finishAppReorder(in groups: AppGroupLayout, spacing: CGFloat, reordersFolders: Bool) {
        let priorPreviewOffsets = minimalMode ? Dictionary(uniqueKeysWithValues: groups.keys.map {
            ($0, reorderOffset(for: $0, spacing: spacing))
        }) : [:]
        isSettlingAppDrag = true
        // Dwell only delays the preview. An explicit drop uses the final target.
        if pendingDropToken != nil {
            hoverTargetAppKey = pendingDropCandidate?.appKey
            dragDirection = pendingDropCandidate?.direction
        }
        pendingDropCandidate = nil
        pendingDropToken = nil
        var positionChange: CGFloat = 0
        if let sourceKey = draggedAppKey,
           let targetKey = hoverTargetAppKey,
           let direction = dragDirection,
           var keys = dragStartAppKeys,
           let sourceIndex = keys.firstIndex(of: sourceKey) {
            keys.remove(at: sourceIndex)
            if let targetIndex = keys.firstIndex(of: targetKey) {
                let insertionIndex = direction == .left ? targetIndex : targetIndex + 1
                keys.insert(sourceKey, at: min(insertionIndex, keys.count))
                if let oldIndex = groups.keys.firstIndex(of: sourceKey),
                   let newIndex = keys.firstIndex(of: sourceKey) {
                    let widths = Dictionary(uniqueKeysWithValues: groups.keys.indices.map {
                        (groups.keys[$0], groups.maxXs[$0] - groups.minXs[$0])
                    })
                    let newMinX = keys.prefix(newIndex).reduce(groups.minXs.first ?? CGFloat.zero) {
                        $0 + (widths[$1] ?? 0) + spacing
                    }
                    positionChange = newMinX - groups.minXs[oldIndex]
                }
                let postDropOffsets: [String: CGFloat]
                if minimalMode {
                    let originalPositions = Dictionary(uniqueKeysWithValues: groups.keys.indices.map {
                        (groups.keys[$0], groups.minXs[$0])
                    })
                    let widths = Dictionary(uniqueKeysWithValues: groups.keys.indices.map {
                        (groups.keys[$0], groups.maxXs[$0] - groups.minXs[$0])
                    })
                    var nextPosition = groups.minXs.first ?? 0
                    var offsets: [String: CGFloat] = [:]
                    for key in keys {
                        if key != sourceKey, let original = originalPositions[key] {
                            offsets[key] = original + (priorPreviewOffsets[key] ?? 0) - nextPosition
                        }
                        nextPosition += (widths[key] ?? 0) + spacing
                    }
                    postDropOffsets = offsets
                } else {
                    postDropOffsets = [:]
                }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragTranslation -= positionChange
                    settlingAppOffsets = postDropOffsets
                    hoverTargetAppKey = nil
                    dragDirection = nil
                    if reordersFolders {
                        let folderIDs = Dictionary(uniqueKeysWithValues: settings.favoriteFolders.map { (folderDragKey($0), $0.id) })
                        settings.reorderFavoriteFolders(keys.compactMap { folderIDs[$0] })
                    } else if minimalMode {
                        settings.applyMinimalVisibleAppOrder(keys)
                    } else {
                        settings.applyVisibleAppOrder(keys)
                    }
                }
            }
        }
        let duration = FavoriteShelfInteractionMetrics.dragSettleDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            withAnimation(.easeOut(duration: duration)) {
                draggedIconMotion = nil
                dragTranslation = 0
                settlingAppOffsets = [:]
                hoverTargetAppKey = nil
                dragDirection = nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.04) {
            draggedAppKey = nil
            dragStartAppKeys = nil
            dragStartGroupLayout = nil
            isSettlingAppDrag = false
            onAppDragChanged(false)
        }
    }

    private func updateDropTarget(in groups: AppGroupLayout) {
        guard let sourceKey = draggedAppKey,
              let sourceIndex = groups.keys.firstIndex(of: sourceKey),
              dragTranslation != 0 else {
            pendingDropCandidate = nil
            pendingDropToken = nil
            hoverTargetAppKey = nil
            dragDirection = nil
            return
        }

        let sourceWidth = groups.maxXs[sourceIndex] - groups.minXs[sourceIndex]
        if minimalMode && groups.keys.indices.allSatisfy({
            abs(groups.maxXs[$0] - groups.minXs[$0] - sourceWidth) < 0.001
        }) {
            pendingDropCandidate = nil
            pendingDropToken = nil
            let index = FavoriteShelfReorderTarget.index(source: sourceIndex, count: groups.keys.count,
                translation: dragTranslation, itemStep: sourceWidth + taskbarItemSpacing,
                previewIndex: hoverTargetAppKey.flatMap { groups.keys.firstIndex(of: $0) })
            hoverTargetAppKey = index.map { groups.keys[$0] }
            dragDirection = index.map { $0 < sourceIndex ? .left : .right }
            return
        }

        let direction: AppDragDirection = dragTranslation < 0 ? .left : .right
        let targetIndex: Int?

        if direction == .left {
            let draggedLeadingEdge = groups.minXs[sourceIndex] + dragTranslation
            targetIndex = groups.keys.indices
                .filter { $0 < sourceIndex }
                .filter {
                    let width = groups.maxXs[$0] - groups.minXs[$0]
                    return draggedLeadingEdge <= groups.minXs[$0] + width * 0.50
                }
                .min()
        } else {
            let draggedTrailingEdge = groups.maxXs[sourceIndex] + dragTranslation
            targetIndex = groups.keys.indices
                .filter { $0 > sourceIndex }
                .filter {
                    let width = groups.maxXs[$0] - groups.minXs[$0]
                    return draggedTrailingEdge >= groups.maxXs[$0] - width * 0.50
                }
                .max()
        }

        let candidate = targetIndex.map { PendingDropCandidate(appKey: groups.keys[$0], direction: direction) }
        if hoverTargetAppKey == candidate?.appKey && dragDirection == candidate?.direction {
            // Returning to the confirmed slot cancels a pending change.
            pendingDropCandidate = nil
            pendingDropToken = nil
            return
        }
        if pendingDropToken != nil && pendingDropCandidate == candidate { return }

        // Keep the previous preview while crossing other items. Change it only
        // after dwelling on one target, including returning to the original slot.
        pendingDropCandidate = candidate
        let token = UUID()
        pendingDropToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard pendingDropToken == token,
                  pendingDropCandidate == candidate,
                  draggedAppKey == sourceKey,
                  !isSettlingAppDrag else { return }
            hoverTargetAppKey = candidate?.appKey
            dragDirection = candidate?.direction
            pendingDropCandidate = nil
            pendingDropToken = nil
        }
    }

    private func taskbarItemOffset(for appKey: String) -> CGFloat {
        reorderOffset(for: appKey, spacing: taskbarItemSpacing)
    }

    private func reorderOffset(for appKey: String, spacing: CGFloat) -> CGFloat {
        if appKey == draggedAppKey { return dragTranslation }
        if let offset = settlingAppOffsets[appKey] { return offset }
        guard let draggedAppKey,
              let hoverTargetAppKey,
              let layout = dragStartGroupLayout,
              let sourceIndex = layout.keys.firstIndex(of: draggedAppKey),
              let targetIndex = layout.keys.firstIndex(of: hoverTargetAppKey),
              let itemIndex = layout.keys.firstIndex(of: appKey) else { return 0 }

        let draggedWidth = layout.maxXs[sourceIndex] - layout.minXs[sourceIndex]
        let displacement = draggedWidth + spacing
        if sourceIndex < targetIndex, (sourceIndex + 1...targetIndex).contains(itemIndex) {
            return -displacement
        }
        if targetIndex < sourceIndex, (targetIndex..<sourceIndex).contains(itemIndex) {
            return displacement
        }
        return 0
    }

    private func isDropTarget(_ appKey: String) -> Bool {
        draggedAppKey != nil && appKey == hoverTargetAppKey && appKey != draggedAppKey
    }

    private func taskbarAppGroupLayout(itemWidths: [String: CGFloat], autoCollapsed: Set<String>) -> AppGroupLayout {
        if minimalMode {
            let groups = appGroups
            let keys = settings.orderedMinimalAppKeys(with: groups.map(\.id))
            let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
            let widths: [[CGFloat]] = keys.map { key in
                guard let group = groupsByID[key], group.windows.count > 1 else {
                    return [MinimalTaskbarSizing.iconSlotWidth * taskbarContentScale]
                }
                let displayed = isCollapsed(group, autoCollapsed: autoCollapsed)
                    ? Array(group.windows.prefix(1)) : group.windows
                return displayed.map { itemWidths[$0.id] ?? 0 }
            }
            let frames = TaskbarItemSizing.groupFrames(widths: widths, spacing: taskbarItemSpacing)
            return AppGroupLayout(keys: keys, minXs: frames.map(\.minX), maxXs: frames.map(\.maxX))
        }
        let groups = appGroups
        let widths = groups.map { group in
            let displayed = isCollapsed(group, autoCollapsed: autoCollapsed)
                ? Array(group.windows.prefix(1)) : group.windows
            return displayed.map { itemWidths[$0.id] ?? 0 }
        }
        let frames = TaskbarItemSizing.groupFrames(widths: widths, spacing: taskbarItemSpacing)
        return AppGroupLayout(keys: groups.map(\.id), minXs: frames.map(\.minX), maxXs: frames.map(\.maxX))
    }

}

private struct AppWindowGroup: Identifiable {
    let id: String
    let windows: [WindowModel]
}

private enum AppDragDirection: Equatable {
    case left
    case right
}

private struct PendingDropCandidate: Equatable {
    let appKey: String
    let direction: AppDragDirection
}

private struct AppGroupLayout {
    let keys: [String]
    let minXs: [CGFloat]
    let maxXs: [CGFloat]
}

private struct TaskbarGlassOutline: View, Animatable {
    var insets: CGSize
    let cornerRadius: CGFloat
    let glassOpacity: Double
    let tintOpacity: Double

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(insets.width, insets.height) }
        set { insets = CGSize(width: newValue.first, height: newValue.second) }
    }

    var body: some View {
        ZStack {
            TaskbarGlassSurface(cornerRadius: cornerRadius, opacity: glassOpacity,
                leadingInset: insets.width, trailingInset: insets.height)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(tintOpacity))
                .padding(.leading, insets.width)
                .padding(.trailing, insets.height)
                .allowsHitTesting(false)
        }
    }
}

/// Keep native glass outside SwiftUI's compositing hierarchy.
private struct TaskbarGlassSurface: NSViewRepresentable {
    let cornerRadius: CGFloat
    let opacity: Double
    let leadingInset: CGFloat
    let trailingInset: CGFloat

    func makeNSView(context: Context) -> TaskbarGlassAnchorView {
        TaskbarGlassAnchorView()
    }

    func updateNSView(_ view: TaskbarGlassAnchorView, context: Context) {
        view.configure(cornerRadius: cornerRadius, opacity: opacity,
            leadingInset: leadingInset, trailingInset: trailingInset)
    }

    static func dismantleNSView(_ view: TaskbarGlassAnchorView, coordinator: ()) {
        view.detachGlass()
    }
}

private struct TaskbarApplicationIcon: View {
    let bundleIdentifier: String?
    let fallbackIcon: NSImage
    let size: CGFloat

    var body: some View {
        Group {
            if bundleIdentifier == "com.apple.iCal" {
                TimelineView(.periodic(from: .now, by: 20)) { context in
                    Image(nsImage: CalendarLiveIcon.image(for: context.date))
                        .resizable()
                }
            } else {
                Image(nsImage: fallbackIcon)
                    .resizable()
            }
        }
        .frame(width: size, height: size)
    }
}

private struct TaskItemProgressBar: View {
    let value: Double
    let scale: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.36))
                Capsule()
                    .fill(Color(red: 0.36, green: 0.96, blue: 0.36))
                    .frame(width: geometry.size.width * CGFloat(value))
                    .shadow(color: .green.opacity(0.45), radius: 2)
            }
            .clipShape(Capsule())
        }
        .frame(height: 2.5 * scale)
        .padding(.horizontal, 1.5 * scale)
        .padding(.bottom, 0.5 * scale)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.linear(duration: 0.18), value: value)
    }
}

private struct TaskItemProgressFill: View {
    let value: Double
    let cornerRadius: CGFloat

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color(red: 0.20, green: 0.65, blue: 0.28))
                .frame(width: geometry.size.width * CGFloat(min(max(value, 0), 1)))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.linear(duration: 0.18), value: value)
    }
}

private struct TaskItemProgressLabel: View {
    let value: Double
    let scale: CGFloat
    private var percent: Int { min(99, max(0, Int((value * 100).rounded()))) }

    var body: some View {
        Text("\(percent)%")
            .font(.system(size: 11 * scale, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("进度 \(percent)%")
    }
}

/// Polls the actual pointer position because nonactivating taskbar panels can miss
/// SwiftUI hover transitions when another application owns the key window.
struct TaskbarPointerHoverTracker: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverView {
        HoverView()
    }

    func updateNSView(_ view: HoverView, context: Context) {
        view.onHover = onHover
    }

    static func dismantleNSView(_ view: HoverView, coordinator: ()) {
        view.stopTracking()
    }

    final class HoverView: NSView {
        var onHover: ((Bool) -> Void)?
        private var timer: Timer?
        private var wasInside = false
        private var hoverTrackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
            let area = NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(area)
            hoverTrackingArea = area
        }
        override func mouseEntered(with event: NSEvent) { reportHover(true) }
        override func mouseExited(with event: NSEvent) { reportHover(false) }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            timer?.invalidate()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate()
            timer = nil
            if window != nil {
                updateHover()
            } else {
                reportHover(false)
            }
        }

        func stopTracking() {
            timer?.invalidate()
            timer = nil
            reportHover(false)
        }

        private func updateHover() {
            guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else {
                reportHover(false)
                return
            }
            let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            reportHover(bounds.contains(point))
        }

        private func reportHover(_ inside: Bool) {
            if inside {
                if timer == nil, window != nil {
                    let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                        self?.updateHover()
                    }
                    t.tolerance = 0.03
                    RunLoop.main.add(t, forMode: .common)
                    timer = t
                }
            } else {
                timer?.invalidate()
                timer = nil
            }
            guard inside != wasInside else { return }
            wasInside = inside
            onHover?(inside)
        }
    }
}

/// A stable reading surface above the clear outer glass; labels retain semantic colors.
private struct TaskbarReadableItemSurface: View {
    @ObservedObject private var overlapAppearance = TaskbarOverlapAppearance.shared
    let cornerRadius: CGFloat
    var isHovered = false
    var isFocused = false
    var usesSubtleHoverPill = false
    var distinctStates = false
    var transparency: Double = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(TaskbarItemHazeSettings.strengthKey) private var hazeStrength = 1.0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if overlapAppearance.usesTemporaryItemBackground {
                shape.fill(Color.black.opacity(isFocused ? 0.55 : isHovered ? 0.40 : 0.30))
            } else if distinctStates {
                shape.fill(isFocused ? Color.black.opacity(reduceTransparency ? 0.80 : 0.45)
                    : Color.white.opacity(isHovered ? 0.20 : 0.09))
                shape.strokeBorder(Color.white.opacity(isFocused ? 0.26 : 0.10), lineWidth: 0.7)
            } else if usesSubtleHoverPill {
                if isFocused || isHovered {
                    if reduceTransparency {
                        shape.fill(Color(white: isFocused ? 0.25 : 0.36))
                    } else {
                        shape.fill(isFocused
                            ? Color.black.opacity(0.24 * hazeStrength)
                            : Color.white.opacity(0.12 * hazeStrength))
                    }
                }
            } else if isFocused {
                shape.fill(colorScheme == .dark
                    ? Color(white: 0.30).opacity((reduceTransparency ? 1 : 0.96) * hazeStrength)
                    : Color.white.opacity((reduceTransparency ? 1 : 0.96) * hazeStrength))
            } else if reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor))
            } else {
                shape.fill(.thinMaterial).opacity(isHovered ? 0.72 : 0.40)
                shape.fill(Color(nsColor: .controlBackgroundColor)
                    .opacity(isHovered ? 0.18 : 0.06))
            }
            if !usesSubtleHoverPill {
                shape.strokeBorder(Color.primary.opacity(
                    isFocused ? 0.20 : isHovered ? 0.10 : 0.035), lineWidth: 0.7)
            }
        }
        .opacity(overlapAppearance.usesTemporaryItemBackground || reduceTransparency || isFocused ? 1 : 1 - transparency * 0.4)
        .allowsHitTesting(false)
    }
}

private struct TaskbarFocusIndicator: View {
    let iconWidth: CGFloat
    let scale: CGFloat

    var body: some View {
        Capsule().fill(Color(nsColor: .controlAccentColor))
            .frame(width: iconWidth * 0.88, height: 3.5 * scale)
            .padding(.bottom, 2 * scale)
            .allowsHitTesting(false)
    }
}

private struct TaskbarCollapsedAppView: View {
    let windows: [WindowModel]
    let profileAvatars: [String: EdgeProfileAvatar]
    let availableWidth: CGFloat
    let itemHeight: CGFloat
    let hitHeight: CGFloat
    let motion: MinimalIconMotion
    let visualLift: CGFloat
    let contentScale: CGFloat
    let taskbarFontSize: CGFloat
    var iconOnly = false
    var distinctStates = false
    let nonSelectedItemTransparency: Double
    let progress: Double?
    let onSelect: (WindowModel) -> Void
    let onClose: (WindowModel) -> Void
    let contextMenuActions: [FavoriteShelfMenuAction]
    let onContextMenuVisibilityChanged: (Bool) -> Void
    var focusOverride: Bool? = nil
    private var isFocused: Bool { focusOverride ?? windows.contains(where: \.isFocused) }
    @State private var isShowingWindows = false
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sharedProfileAvatar: EdgeProfileAvatar? {
        guard profileAvatars.count == windows.count, let avatar = profileAvatars.values.first,
              profileAvatars.values.allSatisfy({ $0 == avatar }) else { return nil }
        return avatar
    }

    var body: some View {
        let representative = windows.first(where: \.isFocused) ?? windows[0]
        let compact = iconOnly || availableWidth < 70 * contentScale
        let baseIconSize = (iconOnly ? FavoriteMagnificationLayout.iconSize
            : (compact ? 18.0 : 22.0)) * contentScale
        let iconSize = iconOnly ? baseIconSize : baseIconSize + 2 * contentScale
        let capsuleRadius = 7 * contentScale
        let trailingInset = iconOnly ? 0 : (compact ? 2 : 7) * contentScale
        let leadingInset = trailingInset
        Button { isShowingWindows.toggle() } label: {
            HStack(spacing: 7 * contentScale) {
                TaskbarApplicationIcon(
                    bundleIdentifier: representative.bundleIdentifier,
                    fallbackIcon: representative.applicationIcon
                        ?? NSImage(named: NSImage.applicationIconName)
                        ?? NSImage(size: NSSize(width: 24, height: 24)),
                    size: iconSize
                )
                    .edgeProfileAvatar(sharedProfileAvatar, iconSize: iconSize)
                    .overlay(alignment: .topTrailing) {
                        if compact && windows.count > 1 {
                            Text("\(windows.count)")
                                .font(.system(size: 8 * contentScale, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(2 * contentScale)
                                .background(Color.accentColor, in: Circle())
                                .offset(x: 4 * contentScale, y: -4 * contentScale)
                        }
                    }
                if !compact {
                    Text(representative.applicationName)
                        .font(.system(size: taskbarFontSize * contentScale, weight: isFocused ? .semibold : .medium))
                        .foregroundStyle(Color.primary)
                        .shadow(color: isFocused ? .clear : Color.black.opacity(0.8), radius: 1.5)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(windows.count)")
                        .font(.system(size: 10 * contentScale, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.82))
                        .padding(.horizontal, 5 * contentScale)
                        .padding(.vertical, 2 * contentScale)
                        .background(Color.white.opacity(0.18), in: Capsule())
                    if let progress, availableWidth >= 125 * contentScale {
                        TaskItemProgressLabel(value: progress, scale: contentScale)
                    }
                }
            }
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .frame(maxWidth: .infinity, minHeight: itemHeight, maxHeight: itemHeight)
            .background {
                if !iconOnly {
                    ZStack {
                        TaskbarReadableItemSurface(cornerRadius: capsuleRadius,
                            isHovered: isHovered, isFocused: isFocused,
                            usesSubtleHoverPill: true, distinctStates: distinctStates)
                        if let progress {
                            TaskItemProgressFill(value: progress, cornerRadius: capsuleRadius)
                        }
                    }
                    .frame(height: itemHeight)
                        }
            }
            .overlay(alignment: .bottomLeading) {
                if (progress == nil || iconOnly) && isFocused {
                    TaskbarFocusIndicator(iconWidth: iconOnly ? iconSize * 0.65 : baseIconSize,
                        scale: contentScale)
                        .frame(width: iconSize)
                        .padding(.leading, leadingInset)
                }
            }
            .overlay(alignment: .bottom) {
                if let progress, !iconOnly { TaskItemProgressBar(value: progress, scale: contentScale) }
            }
            .scaleEffect(x: 1, y: motion.scale)
            .offset(y: -visualLift - motion.lift)
            .frame(height: hitHeight)
            .background(Color.black.opacity(0.001))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isFocused || isHovered
            ? 1 : 1 - nonSelectedItemTransparency * 0.2)
        .animation(nil, value: isHovered)
        .background(TaskbarPointerHoverTracker { isHovered = $0 })
        .onHover { isHovered = $0 }
        .help("\(representative.applicationName)：\(windows.count) 个窗口，点击选择"
              + (progress.map { "；进度 \(Int($0 * 100))%" } ?? ""))
        .accessibilityLabel("\(representative.applicationName)，\(windows.count) 个窗口，点击选择")
        .accessibilityValue(isFocused ? "当前焦点窗口"
            : isHovered ? "鼠标悬停" : "非焦点窗口")
        .floatingBubbleContextMenu(actions: contextMenuActions,
            iconCenterX: availableWidth < 72 * contentScale ? availableWidth / 2 : 17 * contentScale,
            onVisibilityChange: { isOpen in
                if isOpen { isShowingWindows = false }
                onContextMenuVisibilityChanged(isOpen)
            })
        .floatingBubbleWindow(isPresented: $isShowingWindows) {
            VStack(alignment: .leading, spacing: 6) {
                Text(representative.applicationName).font(.headline)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(windows) { window in
                            FloatingBubbleWindowChoiceRow(
                                title: TaskbarItemSizing.displayTitle(window.title, bundleIdentifier: window.bundleIdentifier),
                                profileAvatar: profileAvatars[window.id],
                                isMinimized: window.isMinimized,
                                isFocused: window.isFocused,
                                onSelect: {
                                    isShowingWindows = false
                                    onSelect(window)
                                },
                                onClose: { onClose(window) })
                        }
                    }
                }
                .frame(height: min(360, CGFloat(windows.count) * 32))
            }
            .padding(12)
            .frame(width: 280)
        }
    }
}

private struct DownloadBubbleRow: View {
    let task: BrowserDownloadTask
    let onOpenDownloads: () -> Void
    let onOpenFile: (@escaping (Bool) -> Void) -> Void
    let onRevealFile: (@escaping (Bool) -> Void) -> Void
    let onClose: () -> Void
    @State private var hovered = false
    @State private var isOpening = false

    private func open(reveal: Bool) {
        guard !isOpening else { return }
        isOpening = true
        (reveal ? onRevealFile : onOpenFile) { _ in isOpening = false }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if task.download.isComplete { open(reveal: false) }
                else { onOpenDownloads() }
            } label: {
                HStack(spacing: 9) {
                    if task.download.isComplete {
                        CompletedDownloadIcon(size: 26)
                    } else {
                        Image(nsImage: DownloadFileIcon.image(for: task.download.filename))
                            .resizable().scaledToFit()
                            .frame(width: 26, height: 26)
                    }
                    Text(isOpening ? "正在打开…" : task.download.filename)
                        .font(.system(size: 13, weight: .regular))
                        .lineLimit(1)
                        .foregroundStyle(hovered ? Color.white : Color.primary)
                    Spacer(minLength: 0)
                    if !task.download.isComplete {
                        if task.download.paused {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 11))
                        } else if let progress = task.progress {
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dockMenuFocusAppearance()
            .disabled(isOpening)
            .accessibilityLabel(task.download.isComplete
                ? "打开文件：\(task.download.filename)" : "下载：\(task.download.filename)")

            if task.download.isComplete {
                Button { open(reveal: true) } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 22, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .dockMenuFocusAppearance()
                .disabled(isOpening)
                .accessibilityLabel("打开文件夹")
                .help("打开文件夹并选中文件")

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 22, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .dockMenuFocusAppearance()
                .accessibilityLabel("关闭下载任务")
                .help("关闭下载任务，不删除文件")
            }
        }
        .foregroundStyle(hovered ? Color.white : Color.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background {
            if hovered {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

private struct CompletedDownloadIcon: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "arrow.down.to.line")
            .font(.system(size: size * 0.68, weight: .medium))
            .foregroundStyle(Color.primary)
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .offset(x: size * 0.08, y: -size * 0.08)
            }
            .accessibilityHidden(true)
    }
}

private struct DownloadTaskItemView: View {
    private enum HoverRegion { case file, folder, close }
    let task: BrowserDownloadTask
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat
    let fontSize: CGFloat
    let highlightStyle: TaskItemHighlightStyle
    let transparency: Double
    let onOpenDownloads: () -> Void
    let onOpenFile: (@escaping (Bool) -> Void) -> Void
    let onRevealFile: (@escaping (Bool) -> Void) -> Void
    let onClose: () -> Void
    @State private var hovered = false
    @State private var hoveredRegion: HoverRegion?
    @State private var isOpening = false
    private var highlight: Color { .accentColor }

    private func open(reveal: Bool) {
        guard !isOpening else { return }
        isOpening = true
        let action = reveal ? onRevealFile : onOpenFile
        action { _ in isOpening = false }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if task.download.isComplete { open(reveal: false) }
                else { onOpenDownloads() }
            } label: {
                HStack(spacing: 7 * scale) {
                    if task.download.isComplete {
                        CompletedDownloadIcon(size: 18 * scale)
                    } else {
                        Image(nsImage: DownloadFileIcon.image(for: task.download.localPath ?? task.download.filename))
                        .resizable().scaledToFit()
                        .frame(width: 18 * scale, height: 18 * scale)
                        .accessibilityHidden(true)
                    }
                    Text(isOpening ? "正在打开…" : task.download.filename)
                        .font(.system(size: fontSize * scale, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !task.download.isComplete {
                        if task.download.paused {
                            Image(systemName: "pause.fill").font(.system(size: 10 * scale))
                        } else if let progress = task.progress, width >= 105 * scale {
                            TaskItemProgressLabel(value: progress, scale: scale)
                        } else { ProgressView().controlSize(.mini) }
                    }
                }
                .padding(.leading, 8 * scale).padding(.trailing, 4 * scale)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .background(Color.white.opacity(hoveredRegion == .file ? 0.10 : 0),
                    in: RoundedRectangle(cornerRadius: 5 * scale))
                .contentShape(Rectangle())
            }
            .accessibilityLabel(task.download.isComplete ? "打开文件：\(task.download.filename)" : "下载：\(task.download.filename)")
            .help(task.download.isComplete ? "打开文件：\(task.download.filename)"
                : task.browser == .safari ? "切换到 Safari 查看下载" : "打开浏览器下载列表")
            .onHover { inside in updateHoverRegion(.file, inside: inside) }
            if task.download.isComplete {
                Button { open(reveal: true) } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 13 * scale, weight: .medium))
                        .frame(width: 28 * scale, height: height)
                        .background(Color.white.opacity(hoveredRegion == .folder ? 0.16 : 0),
                            in: RoundedRectangle(cornerRadius: 5 * scale))
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("打开文件夹").help("打开文件夹并选中文件")
                .onHover { inside in updateHoverRegion(.folder, inside: inside) }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .frame(width: 24 * scale, height: height)
                        .background(Color.white.opacity(hoveredRegion == .close ? 0.16 : 0),
                            in: RoundedRectangle(cornerRadius: 5 * scale))
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("关闭下载任务").help("关闭下载任务，不删除文件")
                .onHover { inside in updateHoverRegion(.close, inside: inside) }
            }
        }
        .buttonStyle(DownloadTaskButtonStyle(scale: scale))
        .disabled(isOpening)
        .foregroundStyle(Color.primary)
        .frame(width: width, height: height)
        .background {
            TaskbarReadableItemSurface(cornerRadius: 7 * scale, isHovered: hovered, transparency: transparency)
            RoundedRectangle(cornerRadius: 7 * scale)
                .fill(highlight.opacity(hovered ? (highlightStyle == .systemAccent ? 0.13 : 0.18) : 0))
            if let progress = task.progress {
                TaskItemProgressFill(value: progress, cornerRadius: 7 * scale)
            RoundedRectangle(cornerRadius: 7 * scale)
                .stroke(highlight.opacity(hovered ? 0.56 : task.progress == nil ? 0 : 0.14), lineWidth: 0.7)
            }
        }

        .clipShape(RoundedRectangle(cornerRadius: 7 * scale))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private func updateHoverRegion(_ region: HoverRegion, inside: Bool) {
        if inside { hoveredRegion = region }
        else if hoveredRegion == region { hoveredRegion = nil }
    }
}

private struct DownloadTaskButtonStyle: ButtonStyle {
    let scale: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.24 : 0),
                        in: RoundedRectangle(cornerRadius: 5 * scale))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.07), value: configuration.isPressed)
    }
}

struct WindowTaskItemView: View {
    let window: WindowModel
    var profileAvatar: EdgeProfileAvatar? = nil
    let availableWidth: CGFloat
    var nonSelectedItemTransparency: Double = 0
    var shortcutLabel: String? = nil
    var itemHeight: CGFloat = 31
    var contentScale: CGFloat = 1
    var taskbarFontSize: CGFloat = SettingsStore.defaultTaskbarItemFontSize
    var distinctStates = false
    var progress: Double? = nil
    var visualLift: CGFloat = 0
    let onShowAppWindows: () -> Void
    let onBlockWindowType: () -> Void
    let onClose: () -> Void
    let onToggleFavorite: () -> Void
    let favoriteActionTitle: String
    var isHovered = false
    var focusOverride: Bool? = nil
    private var isFocused: Bool { focusOverride ?? window.isFocused }

    private var taskItemTitle: String {
        TaskbarItemSizing.displayTitle(window.title, bundleIdentifier: window.bundleIdentifier)
    }

    var body: some View {
        let capsuleRadius = 7 * contentScale
        let showsTitle = availableWidth >= textVisibilityWidth
        let trailingInset = (showsTitle ? 8 : 3) * contentScale
        let leadingInset = trailingInset
        return HStack(alignment: .center, spacing: availableWidth < textVisibilityWidth ? 0 : 7 * contentScale) {
            TaskbarApplicationIcon(
                bundleIdentifier: window.bundleIdentifier,
                fallbackIcon: window.applicationIcon ?? fallbackIcon,
                size: iconSize
            )
                .edgeProfileAvatar(profileAvatar, iconSize: iconSize)
                .overlay(alignment: .topTrailing) {
                    if let shortcutLabel {
                        Text(shortcutLabel)
                            .font(.system(size: 10 * contentScale, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 14 * contentScale, height: 14 * contentScale)
                            .background(Color.accentColor, in: Circle())
                            .offset(x: 4 * contentScale, y: -4 * contentScale)
                            .accessibilityHidden(true)
                    }
                }
                .opacity(1)
            if availableWidth >= textVisibilityWidth {
                VStack(alignment: .leading, spacing: 0) {
                    Text(taskItemTitle)
                        .font(.system(
                            size: taskbarFontSize * contentScale,
                            weight: isFocused ? .semibold : .medium
                        ))
                        .foregroundStyle(Color.primary)
                        .shadow(color: !isFocused
                            ? Color.black.opacity(0.8) : .clear, radius: 1.5)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let progress, availableWidth >= 105 * contentScale {
                TaskItemProgressLabel(value: progress, scale: contentScale)
            }
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .frame(maxWidth: .infinity, minHeight: itemHeight, maxHeight: itemHeight, alignment: availableWidth < textVisibilityWidth ? .center : .leading)
        .background {
            ZStack {
                TaskbarReadableItemSurface(cornerRadius: capsuleRadius,
                    isHovered: isHovered, isFocused: isFocused, usesSubtleHoverPill: true, distinctStates: distinctStates)
                if let progress {
                    TaskItemProgressFill(value: progress, cornerRadius: capsuleRadius)
                }
            }
            .frame(height: itemHeight)
        }
        .overlay(alignment: .bottomLeading) {
            if progress == nil && isFocused {
                TaskbarFocusIndicator(iconWidth: baseIconSize, scale: contentScale)
                    .frame(width: iconSize)
                    .padding(.leading, leadingInset)
            }
        }
        .overlay(alignment: .bottom) {
            if let progress {
                TaskItemProgressBar(value: progress, scale: contentScale)
            }
        }
        .opacity(isFocused || isHovered ? 1 : 1 - nonSelectedItemTransparency * 0.2)
        .zIndex(isHovered ? 2 : (isFocused ? 1 : 0))
        .animation(nil, value: isHovered)
        .offset(y: -visualLift)
        .help("点击显示窗口；再次点击当前焦点窗口会收起到任务栏；拖动可调整 App 顺序"
              + (progress.map { "；进度 \(Int($0 * 100))%" } ?? ""))
    }

    private var fallbackIcon: NSImage {
        NSImage(named: NSImage.applicationIconName) ?? NSImage(size: NSSize(width: 24, height: 24))
    }

    private var iconSize: CGFloat { baseIconSize + 3 * contentScale }

    private var baseIconSize: CGFloat {
        (availableWidth < 48 * contentScale ? 16.0 : 18.0) * contentScale
    }

    private var textVisibilityWidth: CGFloat {
        72 * contentScale
    }

}

private struct TaskbarControlButton: View {
    let systemImage: String
    let help: String
    var scale: CGFloat = 1
    var isTaskbarMode = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12 * scale, weight: .medium))
                .frame(width: 28 * scale, height: 28 * scale)
                .contentShape(Rectangle())
                .background(
                    Color.primary.opacity(isHovered ? 0.09 : 0),
                    in: RoundedRectangle(cornerRadius: 7 * scale)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(
            isTaskbarMode ? .easeInOut(duration: 0.24) : .easeOut(duration: 0.12),
            value: isHovered
        )
        .help(help)
    }
}

private enum InstalledApplicationCatalog {
    static func load() -> [FavoriteApp] {
        let manager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true),
            manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true)
        ]
        var applications: [FavoriteApp] = []
        var seen = Set<String>()
        for root in roots {
            guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: [.localizedNameKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in entries where url.pathExtension.lowercased() == "app" {
                guard let bundle = Bundle(url: url.resolvingSymlinksInPath()) else { continue }
                let fileName = manager.displayName(atPath: url.path)
                let id = bundle.bundleIdentifier ?? "name:\(fileName)"
                let name = chineseDisplayName(for: bundle)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? fileName
                guard seen.insert(id).inserted else { continue }
                applications.append(FavoriteApp(id: id, bundleIdentifier: bundle.bundleIdentifier,
                    applicationName: name, bundlePath: url.path))
            }
        }
        return applications.sorted { $0.applicationName.localizedStandardCompare($1.applicationName) == .orderedAscending }
    }

    private static func chineseDisplayName(for bundle: Bundle) -> String? {
        guard let resources = bundle.resourceURL else { return nil }
        let table = NSDictionary(contentsOf: resources.appendingPathComponent("InfoPlist.loctable"))
            as? [String: Any] ?? [:]
        let localizations = Set(bundle.localizations).union(table.keys).filter {
            let language = $0.lowercased().replacingOccurrences(of: "_", with: "-")
            return language == "zh" || language.hasPrefix("zh-")
        }.sorted()
        let preferred = Bundle.preferredLocalizations(from: localizations, forPreferences: ["zh-Hans", "zh-Hant"])
        for localization in preferred + localizations.filter({ !preferred.contains($0) }) {
            let stringsURL = resources.appendingPathComponent("\(localization).lproj/InfoPlist.strings")
            let strings = NSDictionary(contentsOf: stringsURL) as? [String: String] ?? [:]
            let tableStrings = table[localization] as? [String: Any]
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = strings[key] ?? (tableStrings?[key] as? String), !name.isEmpty { return name }
            }
        }
        return nil
    }
}

private struct ApplicationsGridIcon: View {
    let highlighted: Bool

    private static let idleImage = makeImage(backgroundWhite: 0.27)
    private static let highlightedImage = makeImage(backgroundWhite: 0.34)
    static let idleNSImage: NSImage = {
        guard let cgImage = idleImage else {
            return NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: nil) ?? NSImage()
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: 108, height: 108))
    }()

    var body: some View {
        if let image = highlighted ? Self.highlightedImage : Self.idleImage {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "square.grid.2x2.fill")
                .resizable().scaledToFit()
                .foregroundStyle(.white)
                .accessibilityHidden(true)
        }
    }

    // Render the background and all four marks at a fixed resolution. Only the
    // resulting image is translated and scaled by the taskbar's hover animation.
    private static func makeImage(backgroundWhite: CGFloat) -> CGImage? {
        let pixels = 108
        guard let context = CGContext(data: nil, width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: 4, y: -4)
        let background = CGPath(roundedRect: CGRect(x: 0.35, y: 0.35, width: 26.3, height: 26.3),
            cornerWidth: 8, cornerHeight: 8, transform: nil)
        context.setFillColor(red: backgroundWhite, green: backgroundWhite, blue: backgroundWhite, alpha: 0.88)
        context.addPath(background)
        context.fillPath()
        context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.18)
        context.setLineWidth(0.7)
        context.addPath(background)
        context.strokePath()

        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.setLineWidth(1.35)
        for row in 0..<2 {
            for column in 0..<2 {
                let tile = CGRect(x: 5.45 + 9.3 * CGFloat(column), y: 5.45 + 9.3 * CGFloat(row),
                    width: 6.8, height: 6.8)
                let outlined = row == 1 && column == 1
                let rect = outlined ? tile.insetBy(dx: 0.675, dy: 0.675) : tile
                let radius: CGFloat = outlined ? 1.125 : 1.8
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                if outlined { context.strokePath() }
                else { context.fillPath() }
            }
        }
        return context.makeImage()
    }
}

private struct RecentApplicationDockView: View {
    @AppStorage(RecentAppHoverBehavior.settingsKey) private var hoverBehavior = RecentAppHoverBehavior.nameBubble.rawValue
    @ObservedObject var settings: SettingsStore
    @ObservedObject var popoverState: RecentAppPopoverState
    let sizeScale: CGFloat
    let isDark: Bool
    let visualLift: CGFloat
    let motion: MinimalIconMotion
    let extendsHitToBottom: Bool
    let showsInlineNameHint: Bool
    let blurredByFavorites: Bool
    var embedsIcon: Bool = true
    let onOpen: (FavoriteApp) -> Void
    let onQuit: (FavoriteApp) -> Void
    let onFavorite: (FavoriteApp) -> Bool
    let onUnfavorite: (FavoriteApp) -> Void
    let onPopoverVisibilityChanged: (Bool) -> Void
    @State private var isButtonHovered = false
    @State private var hoveredApplicationID: String?
    @State private var hoverDismissTask: DispatchWorkItem?
    @State private var draggedPinID: String?
    @State private var searchQuery = ""
    @State private var installedApplications: [FavoriteApp]?
    @State private var searchFocusRequest: UUID?
    @State private var keepsListOpenForSearch = false

    private static let applicationsFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)
    private static let applicationsFolderIcon = NSWorkspace.shared.icon(forFile: applicationsFolder.path)

    private var normalizedQuery: String { searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var matchingApplications: [FavoriteApp] {
        return (installedApplications ?? []).filter {
            $0.applicationName.localizedStandardContains(normalizedQuery)
                || URL(fileURLWithPath: $0.bundlePath ?? "").deletingPathExtension().lastPathComponent
                    .localizedStandardContains(normalizedQuery)
        }
    }

    private func openList() {
        hoverDismissTask?.cancel()
        guard !popoverState.isPresented else { return }
        searchQuery = ""
        installedApplications = nil
        popoverState.isPresented = true
        hoveredApplicationID = nil
    }

    private func scheduleHoverDismissal() {
        guard hoverBehavior == RecentAppHoverBehavior.programList.rawValue, !keepsListOpenForSearch else { return }
        hoverDismissTask?.cancel()
        let task = DispatchWorkItem { popoverState.isPresented = false }
        hoverDismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }

    var body: some View {
        let slotWidth = (embedsIcon ? 32 : 30) * sizeScale
        let slotHeight = SettingsStore.layoutReferenceTaskbarHeight * sizeScale
        let shownSize = 27 * sizeScale * motion.scale
        let lift = visualLift + motion.lift
        let nameHintEnabled = !blurredByFavorites && !popoverState.isPresented
            && hoverBehavior != RecentAppHoverBehavior.programList.rawValue
        let resolvedAnchorOffset = embedsIcon
            ? CGSize(width: motion.horizontalOffset, height: lift)
            : (popoverState.anchorSize == .zero ? CGSize(width: 0, height: visualLift) : popoverState.anchorOffset)
        let resolvedAnchorSize = embedsIcon
            ? CGSize(width: shownSize, height: shownSize)
            : (popoverState.anchorSize == .zero ? CGSize(width: 27 * sizeScale, height: 27 * sizeScale) : popoverState.anchorSize)
        return Group {
            if embedsIcon {
                Button {
                    if popoverState.isPresented && keepsListOpenForSearch {
                        popoverState.isPresented = false
                    } else {
                        openList()
                        keepsListOpenForSearch = true
                        searchFocusRequest = UUID()
                    }
                } label: {
                    ApplicationsGridIcon(highlighted: (extendsHitToBottom ? showsInlineNameHint : isButtonHovered)
                        || popoverState.isPresented)
                        .frame(width: 27 * sizeScale, height: 27 * sizeScale)
                        .minimalIconHint("应用程序", shown: showsInlineNameHint && nameHintEnabled)
                        .blur(radius: blurredByFavorites ? 7 * sizeScale : 0)
                        .opacity(blurredByFavorites ? 0.38 : 1)
                        .animation(.easeOut(duration: 0.14), value: blurredByFavorites)
                        .scaleEffect(motion.scale)
                        .offset(x: motion.horizontalOffset, y: -lift)
                        .frame(width: extendsHitToBottom ? slotWidth : nil, height: extendsHitToBottom ? slotHeight : nil)
                        .background(Color.black.opacity(extendsHitToBottom ? 0.001 : 0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered in
                    isButtonHovered = hovered && !blurredByFavorites
                    if isButtonHovered {
                        hoverDismissTask?.cancel()
                        if hoverBehavior == RecentAppHoverBehavior.programList.rawValue { openList() }
                    } else {
                        scheduleHoverDismissal()
                    }
                }
                .frame(width: slotWidth, height: slotHeight)
                .background {
                    if !extendsHitToBottom {
                        MinimalNameHintAnchor(title: "应用程序", enabled: nameHintEnabled,
                            presented: isButtonHovered, topOffset: (slotHeight - shownSize) / 2 - lift,
                            horizontalOffset: motion.horizontalOffset)
                    }
                }
                .accessibilityLabel("应用程序；点击展开列表")
            } else {
                Color.clear
                    .frame(width: slotWidth, height: slotHeight)
                    .allowsHitTesting(false)
                    .onChange(of: popoverState.clickRequest) { _ in
                        if popoverState.isPresented && keepsListOpenForSearch {
                            popoverState.isPresented = false
                        } else {
                            openList()
                            keepsListOpenForSearch = true
                            searchFocusRequest = UUID()
                        }
                    }
                    .onChange(of: popoverState.externalHovered) { hovered in
                        if hovered {
                            hoverDismissTask?.cancel()
                            if hoverBehavior == RecentAppHoverBehavior.programList.rawValue { openList() }
                        } else {
                            scheduleHoverDismissal()
                        }
                    }
            }
        }
        .floatingBubbleWindow(isPresented: $popoverState.isPresented,
            anchorOffset: resolvedAnchorOffset,
            anchorSize: resolvedAnchorSize,
            locksPositionWhileVisible: true) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        RecentApplicationSearchField(query: $searchQuery, focusRequest: searchFocusRequest)
                    }
                    .font(.system(size: 14))
                    .padding(.horizontal, 9)
                    .frame(height: 34)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    Button {
                        popoverState.isPresented = false
                        NSWorkspace.shared.open(Self.applicationsFolder)
                    } label: {
                        Image(nsImage: Self.applicationsFolderIcon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 21, height: 21)
                            .frame(width: 32, height: 28)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .dockMenuFocusAppearance()
                    .help("在 Finder 中打开应用程序文件夹")
                    .accessibilityLabel("打开应用程序文件夹")
                }
                Divider().padding(.vertical, 6)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if normalizedQuery.isEmpty {
                            appSection("置顶", applications: settings.appGroupPins, empty: "暂无置顶 App", showsPin: true)
                            Divider().padding(.vertical, 3)
                            appSection("最近打开", applications: recentUnpinnedApplications,
                                empty: "暂无最近打开的 App", canRemoveRecentRecord: true)
                        } else {
                            appSection("所有 App · 搜索结果", applications: matchingApplications,
                                empty: installedApplications == nil ? "正在读取 App…" : "没有匹配的 App")
                        }
                    }
                    .padding(.trailing, 14)
                }
                .frame(height: 440)
                let rowCount = normalizedQuery.isEmpty
                    ? settings.appGroupPins.count + recentUnpinnedApplications.count : matchingApplications.count
                Label("滚动查看更多", systemImage: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .opacity(rowCount > (normalizedQuery.isEmpty ? 9 : 10) ? 1 : 0)
                    .accessibilityHidden(rowCount <= (normalizedQuery.isEmpty ? 9 : 10))
            }
            .frame(width: 315)
            .padding(12)
            .background {
                TaskbarPointerHoverTracker { hovered in
                    if hovered { hoverDismissTask?.cancel() }
                    else { scheduleHoverDismissal() }
                }
            }
        }
        .task(id: popoverState.isPresented) {
            guard popoverState.isPresented else { return }
            let catalog = await Task.detached(priority: .userInitiated) { InstalledApplicationCatalog.load() }.value
            guard !Task.isCancelled else { return }
            installedApplications = catalog
        }
        .onChange(of: hoverBehavior) { _ in
            hoverDismissTask?.cancel()
            popoverState.isPresented = false
            isButtonHovered = false
        }
        .onDisappear {
            hoverDismissTask?.cancel()
            popoverState.isPresented = false
        }
        .onChange(of: popoverState.isPresented) { isShowing in
            onPopoverVisibilityChanged(isShowing)
            if !isShowing {
                searchFocusRequest = nil
                keepsListOpenForSearch = false
                hoveredApplicationID = nil
            }
        }
    }

    private var recentUnpinnedApplications: [FavoriteApp] {
        let excluded = Set(settings.favoriteApps.map(\.id) + settings.appGroupPins.map(\.id))
        return RecentAppDisplayPolicy.visible(from: settings.recentAppsByClosingTime, excluding: { excluded.contains($0.id) })
    }

    private func appSection(_ title: String, applications: [FavoriteApp], empty: String,
                            showsPin: Bool = false, canRemoveRecentRecord: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                if showsPin {
                    Image(systemName: "pin")
                        .help("点击 App 旁的图钉，将它移到置顶区")
                        .accessibilityLabel("点击 App 旁的图钉可置顶")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 5)
            if applications.isEmpty {
                Text(empty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 5)
                    .padding(.vertical, 4)
            } else {
                ForEach(applications) { application in
                    if showsPin {
                        appRow(application, canRemoveRecentRecord: false)
                            .onDrag {
                                draggedPinID = application.id
                                return NSItemProvider(object: application.id as NSString)
                            }
                            .onDrop(of: [.plainText], isTargeted: nil) { _ in
                                guard let draggedPinID else { return false }
                                self.draggedPinID = nil
                                settings.moveAppGroupPin(draggedPinID, to: application.id)
                                return true
                            }
                    } else {
                        appRow(application, canRemoveRecentRecord: canRemoveRecentRecord)
                    }
                }
            }
        }
    }

    private func appRow(_ application: FavoriteApp, canRemoveRecentRecord: Bool) -> some View {
        let running = popoverState.runningApplicationIDs.contains(application.id)
        let highlighted = hoveredApplicationID == application.id
        let pinned = settings.appGroupPins.contains { $0.id == application.id }
        let favorited = settings.isFavorite(application.id)
        return HStack(spacing: 4) {
            Button {
                hoveredApplicationID = nil
                popoverState.isPresented = false
                onOpen(application)
            } label: {
                HStack(spacing: 7) {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(highlighted ? Color.white : Color.secondary)
                            .frame(width: 4, height: 4)
                            .opacity(running ? 1 : 0)
                            .accessibilityHidden(true)
                        FavoriteApplicationIcon(favorite: application)
                            .frame(width: 30, height: 30)
                    }
                    Text(application.applicationName)
                        .font(.system(size: 14))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(highlighted ? Color.white : Color.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开 \(application.applicationName)")
            .accessibilityValue(running ? "正在运行" : "未运行")
            .dockMenuFocusAppearance()

            HStack(spacing: 3) {
                rowAction(symbol: favorited ? "star.fill" : "star",
                    label: favorited ? "从任务栏收藏移除 \(application.applicationName)"
                        : "加入任务栏收藏 \(application.applicationName)") {
                    if favorited { onUnfavorite(application) }
                    else { _ = onFavorite(application) }
                }
                rowAction(symbol: pinned ? "pin.fill" : "pin",
                    label: pinned ? "取消置顶 \(application.applicationName)"
                        : "在应用程序列表中置顶 \(application.applicationName)") {
                    settings.toggleAppGroupPin(application)
                }
                if running {
                    rowAction(symbol: "xmark.circle.fill", label: "退出 \(application.applicationName)") {
                        onQuit(application)
                    }
                } else if canRemoveRecentRecord {
                    rowAction(symbol: "trash", label: "移除 \(application.applicationName) 的最近打开记录") {
                        guard !popoverState.runningApplicationIDs.contains(application.id) else { return }
                        hoveredApplicationID = nil
                        settings.removeRecentApp(id: application.id)
                    }
                }
            }
            .foregroundStyle(highlighted ? Color.white : Color.primary)
            .opacity(highlighted ? 1 : 0)
            .allowsHitTesting(highlighted)
            .accessibilityHidden(!highlighted)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if highlighted { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor) }
        }
        .contentShape(Rectangle())
        .onHover { isHovered in
            if isHovered {
                hoveredApplicationID = application.id
            } else if hoveredApplicationID == application.id {
                hoveredApplicationID = nil
            }
        }
    }

    private func rowAction(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 23, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .dockMenuFocusAppearance()
    }

}

private struct RecentApplicationSearchField: View {
    @Binding var query: String
    let focusRequest: UUID?
    @FocusState private var isFocused: Bool

    @ViewBuilder
    var body: some View {
        if #available(macOS 13, *) {
            field.defaultFocus($isFocused, focusRequest != nil)
        } else {
            field
        }
    }

    private var field: some View {
        TextField("搜索所有应用程序", text: $query)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .task(id: focusRequest) {
                guard focusRequest != nil else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                isFocused = true
            }
    }
}

private struct MinimalIconRowTracker: NSViewRepresentable {
    let slotCenters: [CGFloat?]
    let hitRanges: [Range<CGFloat>?]
    let tracksPosition: Bool
    let isFrozen: Bool
    let followsDrag: Bool
    let onFrame: (MinimalIconWaveFrame) -> Void

    func makeNSView(context: Context) -> Row { Row() }

    func updateNSView(_ view: Row, context: Context) {
        view.setFrameCallback(isFrozen ? nil : onFrame)
        view.updateSlots(centers: slotCenters, hitRanges: hitRanges, tracksPosition: tracksPosition)
        view.setFollowsDrag(followsDrag)
    }

    static func dismantleNSView(_ view: Row, coordinator: ()) { view.stopClock() }

    final class Row: NSView {
        private var onFrame: ((MinimalIconWaveFrame) -> Void)?
        private var needsFrameDelivery = false

        func setFrameCallback(_ callback: ((MinimalIconWaveFrame) -> Void)?) {
            let resumes = onFrame == nil && callback != nil
            onFrame = callback
            if resumes {
                needsFrameDelivery = true
                startClock()
            }
        }
        private var slotCenters: [CGFloat?] = []
        private var hitRanges: [Range<CGFloat>?] = []
        private var tracksPosition = false
        private var followsDrag = false
        private var hover: MinimalIconHover?
        private var frameState = MinimalIconWaveFrame()
        private var transitionStartedAt: TimeInterval = 0
        private var startProgress: CGFloat = 0
        private var waveDisplayLink: AnyObject?
        private var fallbackTimer: Timer?
        private var settledHoverTimer: Timer?
        private var tracking: NSTrackingArea?
        private weak var observedClipView: NSClipView?
        private var needsFrameReset = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard tracking == nil else { return }
            let area = NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self)
            addTrackingArea(area)
            tracking = area
            startClock()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            if window == nil {
                stopClock()
                needsFrameReset = true
            }
            observedClipView = window == nil ? nil : enclosingScrollView?.contentView
            if let clip = observedClipView {
                clip.postsBoundsChangedNotifications = true
                center.addObserver(self, selector: #selector(geometryChanged),
                    name: NSView.boundsDidChangeNotification, object: clip)
            }
            if let window {
                center.addObserver(self, selector: #selector(geometryChanged),
                    name: NSWindow.didMoveNotification, object: window)
                center.addObserver(self, selector: #selector(geometryChanged),
                    name: NSWindow.didChangeOcclusionStateNotification, object: window)
            }
            startClock()
        }

        func updateSlots(centers: [CGFloat?], hitRanges: [Range<CGFloat>?], tracksPosition: Bool) {
            guard slotCenters != centers || self.hitRanges != hitRanges
                    || self.tracksPosition != tracksPosition else { return }
            needsFrameReset = needsFrameReset || slotCenters != centers || self.tracksPosition != tracksPosition
            slotCenters = centers
            self.hitRanges = hitRanges
            self.tracksPosition = tracksPosition
            startClock()
        }

        func setFollowsDrag(_ followsDrag: Bool) {
            guard self.followsDrag != followsDrag else { return }
            self.followsDrag = followsDrag
            startClock()
        }

        override func mouseEntered(with event: NSEvent) { startClock() }
        override func mouseMoved(with event: NSEvent) { startClock() }
        override func mouseExited(with event: NSEvent) { startClock() }

        @objc private func geometryChanged(_ notification: Notification) { startClock() }

        private func sampleHover() -> MinimalIconHover? {
            guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return nil }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard visibleRect.contains(point),
                  let slot = hitRanges.firstIndex(where: { $0?.contains(point.x) == true }),
                  let center = slotCenters[slot] else { return nil }
            return MinimalIconHover(slot: slot, pointerX: tracksPosition ? point.x : center)
        }

        private func sameRun(_ lhs: MinimalIconHover?, _ rhs: MinimalIconHover) -> Bool {
            guard let lhs, slotCenters.indices.contains(lhs.slot), slotCenters.indices.contains(rhs.slot) else {
                return false
            }
            return slotCenters[min(lhs.slot, rhs.slot)...max(lhs.slot, rhs.slot)].allSatisfy { $0 != nil }
        }

        private func startClock() {
            guard window?.isVisible == true, waveDisplayLink == nil, fallbackTimer == nil else { return }
            settledHoverTimer?.invalidate()
            settledHoverTimer = nil
            if #available(macOS 14, *) {
                let link = displayLink(target: self, selector: #selector(displayTick(_:)))
                link.add(to: .main, forMode: .common)
                waveDisplayLink = link
            } else {
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick(at: CACurrentMediaTime()) }
                }
                fallbackTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }

        func stopClock() {
            if #available(macOS 14, *) { (waveDisplayLink as? CADisplayLink)?.invalidate() }
            waveDisplayLink = nil
            fallbackTimer?.invalidate()
            fallbackTimer = nil
            settledHoverTimer?.invalidate()
            settledHoverTimer = nil
        }

        private func watchSettledHover() {
            stopClock()
            guard hover != nil else { return }
            // A missed AppKit exit event must not leave the last enlarged frame on screen.
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkSettledHover() }
            }
            settledHoverTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func checkSettledHover() {
            guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor else {
                stopClock()
                hover = nil
                send(MinimalIconWaveFrame())
                return
            }
            if sampleHover() != hover { startClock() }
        }

        @available(macOS 14, *)
        @objc private func displayTick(_ link: CADisplayLink) {
            tick(at: link.targetTimestamp)
        }

        private func tick(at time: TimeInterval) {
            // Mouse events only wake the clock. Read one live position per frame,
            // so queued events cannot pull the wave backwards.
            let newHover = sampleHover()
            if !tracksPosition {
                hover = newHover
                needsFrameReset = false
                send(MinimalIconWaveFrame(hover: newHover))
                watchSettledHover()
                return
            }

            var pointer = frameState.pointer
            if needsFrameReset || newHover.map({ !sameRun(pointer, $0) }) == true {
                pointer = newHover
                startProgress = 0
                transitionStartedAt = time
                needsFrameReset = false
            } else if (hover == nil) != (newHover == nil) {
                startProgress = frameState.progress
                transitionStartedAt = time
            }
            hover = newHover
            let exiting = hover == nil
            let target: CGFloat = exiting ? 0 : 1
            let eased = FavoriteMagnificationTiming.progress(elapsed: time - transitionStartedAt, exiting: exiting)
            let progress = startProgress + (target - startProgress) * eased
            if let hover { pointer = hover }
            else if progress == 0 { pointer = nil }

            send(MinimalIconWaveFrame(hover: hover, pointer: pointer, progress: progress))
            // Drag gestures can consume mouse-moved events. Keep sampling until drop.
            if !followsDrag, eased == 1, pointer == hover { watchSettledHover() }
        }

        private func send(_ frame: MinimalIconWaveFrame) {
            guard frameState != frame || needsFrameDelivery else { return }
            needsFrameDelivery = false
            frameState = frame
            onFrame?(frame)
        }
    }
}

/// A separate, non-interactive hint can extend outside the scrolling icon row.
private struct MinimalNameHintAnchor: NSViewRepresentable {
    let title: String
    let enabled: Bool
    var presented: Bool? = nil
    var topOffset: CGFloat = 0
    var horizontalOffset: CGFloat = 0

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.title = title
        view.enabled = enabled
        view.presentation = presented
        view.topOffset = topOffset
        view.horizontalOffset = horizontalOffset
        if enabled && presented == true { view.showHint() }
        else if !enabled || presented == false { view.scheduleHideHint() }
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.hideHint() }

    final class Anchor: NSView {
        var title = ""
        var enabled = false
        var presentation: Bool?
        var topOffset: CGFloat = 0
        var horizontalOffset: CGFloat = 0
        private var tracking: NSTrackingArea?
        private static weak var hintOwner: Anchor?
        private static let hint: NSPanel = {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.animationBehavior = .none
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.level = .popUpMenu
            panel.contentView = FloatingBubbleHintView(title: "", width: 28,
                fontSize: SmallBubbleMetrics.fontSize, arrowX: 14)
            return panel
        }()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if presentation != nil {
                if let tracking { removeTrackingArea(tracking) }
                tracking = nil
                return
            }
            guard tracking == nil else { return }
            let area = NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) {
            if presentation == nil { showHint() }
        }

        func showHint() {
            guard enabled, let parent = window, parent.isVisible,
                  !visibleRect.isEmpty, let screen = parent.screen else { return }
            let target = parent.convertToScreen(convert(bounds, to: nil))
            let centerX = target.midX + horizontalOffset
            let font = NSFont.systemFont(ofSize: SmallBubbleMetrics.fontSize)
            let width = min(280, ceil((title as NSString).size(withAttributes: [.font: font]).width) + 28)
            let screenFrame = screen.visibleFrame
            let x = min(max(centerX - width / 2, screenFrame.minX + 4), screenFrame.maxX - width - 4)
            let frame = NSRect(x: x, y: target.maxY + SmallBubbleMetrics.iconGap - topOffset,
                width: width, height: SmallBubbleMetrics.height)
            let arrowX = min(max(centerX - x, 12), width - 12)
            let panel = Self.hint
            if let view = panel.contentView as? FloatingBubbleHintView {
                view.update(title: title, width: width, fontSize: font.pointSize, arrowX: arrowX)
            }
            if panel.frame != frame { panel.setFrame(frame, display: !panel.isVisible) }
            if panel.parent !== parent {
                panel.parent?.removeChildWindow(panel)
                parent.addChildWindow(panel, ordered: .above)
            }
            Self.hintOwner = self
            if !panel.isVisible { panel.orderFrontRegardless() }
        }

        override func mouseExited(with event: NSEvent) { if presentation == nil { hideHint() } }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { hideHint() }
            super.viewWillMove(toWindow: newWindow)
        }

        func scheduleHideHint() {
            guard Self.hintOwner === self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.enabled || self.presentation == false else { return }
                self.hideHint()
            }
        }

        func hideHint() {
            guard Self.hintOwner === self else { return }
            let panel = Self.hint
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            Self.hintOwner = nil
        }
    }
}

private func trashMenuActions(isFull: Bool, open: @escaping () -> Void,
                              restore: @escaping () -> Void, empty: @escaping () -> Void,
                              close: (() -> Void)? = nil) -> [FavoriteShelfMenuAction] {
    var actions = [
        FavoriteShelfMenuAction(title: "打开废纸篓", perform: open),
        .separator,
        FavoriteShelfMenuAction(title: "恢复上一次删除文件", isEnabled: isFull, perform: restore),
        FavoriteShelfMenuAction(title: "清空废纸篓", isEnabled: isFull, perform: empty)
    ]
    if let close {
        actions.insert(FavoriteShelfMenuAction(title: "关闭废纸篓窗口", perform: close), at: 1)
    }
    return actions
}

private enum FavoriteShelfItem: Identifiable {
    case app(FavoriteApp)
    case separator(String)
    case trash(isFull: Bool)
    case applications
    case folder(FavoriteFolder)
    case insertionGap(String)

    var id: String {
        switch self {
        case .app(let app): return app.id
        case .separator(let key): return "utility:separator:\(key)"
        case .trash: return WindowModel.trashAppKey
        case .applications: return "utility:applications"
        case .folder(let folder): return "utility:folder:\(folder.id)"
        case .insertionGap(let id): return "drop-gap:\(id)"
        }
    }

    var name: String {
        switch self {
        case .app(let app): return app.applicationName
        case .separator: return ""
        case .trash: return "废纸篓"
        case .applications: return "应用程序"
        case .folder(let folder): return folder.name
        case .insertionGap: return ""
        }
    }

    var app: FavoriteApp? {
        if case .app(let app) = self { return app }
        return nil
    }

    var isRemovable: Bool {
        switch self {
        case .app, .folder: return true
        case .separator, .trash, .applications, .insertionGap: return false
        }
    }

    var trashIsFull: Bool? {
        if case .trash(let isFull) = self { return isFull }
        return nil
    }

    var isSeparator: Bool {
        if case .separator = self { return true }
        return false
    }

    var lightTrashIcon: NSImage {
        let image = icon(for: Date())
        guard let appearance = NSAppearance(named: .aqua),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
        }
        let output = NSImage(size: NSSize(width: 128, height: 128))
        output.addRepresentation(bitmap)
        return output
    }

    func icon(for date: Date) -> NSImage {
        switch self {
        case .app(let app): return FavoriteApplicationIcon.image(for: app, date: date)
        case .separator: return NSImage()
        case .trash(let isFull):
            return NSImage(named: NSImage.Name(isFull ? "NSTrashFull" : "NSTrashEmpty"))
                ?? NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
                ?? NSImage()
        case .applications: return ApplicationsGridIcon.idleNSImage
        case .folder(let folder): return FavoriteFolderIcon.image(for: folder)
        case .insertionGap: return NSImage()
        }
    }
}

private struct FavoriteDockView: View {
    let favorites: [FavoriteApp]
    let transientAppIDs: Set<String>
    let folders: [FavoriteFolder]
    let showsTrash: Bool
    var showsApplications: Bool = false
    var suppressApplicationsHoverLabel: Bool = false
    let isTrashFull: Bool
    let runningApplicationIDs: Set<String>
    let badgeLabels: [String: String]
    let shortcutIndices: Set<Int>
    let hoverFeedbackEnabled: Bool
    let configuredPeakScale: CGFloat
    let keepsSystemFinder: Bool
    let reducesMotion: Bool
    let hitRegionWidth: CGFloat?
    let showsHoverLabel: Bool
    let sizeScale: CGFloat
    let visualLift: CGFloat
    let onOpen: (FavoriteApp) -> Void
    let onPerformWindowAction: (@escaping () -> Void) -> Void
    let onQuit: (FavoriteApp) -> Void
    let onOpenTrash: () -> Void
    let onCloseTrash: (() -> Void)?
    let onEmptyTrash: () -> Void
    let onRestoreLatestTrashItem: () -> Void
    let onOpenFolder: (FavoriteFolder) -> Void
    let onRemove: (FavoriteApp) -> Void
    let onPinTransient: (FavoriteApp) -> Void
    let displayMenuActions: (FavoriteApp) -> [FavoriteShelfMenuAction]
    let onReorder: ([String]) -> Void
    let onRemoveFolder: (FavoriteFolder) -> Void
    let onReorderFolders: ([String]) -> Void
    let onDropURLs: ([URL], FavoriteShelfInsertion) -> Bool
    let onDragChanged: (Bool) -> Void
    let onHoverActivity: (Bool) -> Void
    let onMagnificationChange: (Bool) -> Void
    var onMagnificationBoundsChange: (CGFloat, CGFloat) -> Void = { _, _ in }
    var onClickApplications: (CGSize, CGSize) -> Void = { _, _ in }
    var onHoverApplications: (Bool, CGSize, CGSize) -> Void = { _, _, _ in }
    var applicationsAnchorView: AnyView? = nil
    @State private var visualController = FavoriteDockVisualController()
    @State private var isApplicationsHovered = false
    @State private var draggedFavoriteID: String?
    @State private var dragStartIDs: [String]?
    @State private var dragTranslation: CGFloat = 0
    @State private var dragPointerX: CGFloat?
    @State private var dragStartLayoutOffset: CGFloat = 0
    @State private var hoverTargetID: String?
    @State private var isSettlingDrag = false
    @State private var isPointerInside = false
    @State private var externalInsertion: FavoriteShelfInsertion?
    @State private var calendarIconDate = Date()

    private var itemStep: CGFloat { FavoriteMagnificationLayout.itemStep * sizeScale }
    private var buttonSize: CGFloat { 30 * sizeScale }
    private var hoverSafetyWidth: CGFloat {
        FavoriteMagnificationLayout.sideClearance(for: sizeScale)
    }
    private var peakScale: CGFloat {
        FavoriteMagnificationLayout.configuredScale(configuredPeakScale,
            enabled: hoverFeedbackEnabled, reducesMotion: reducesMotion)
    }
    private var items: [FavoriteShelfItem] {
        var apps = favorites.map(FavoriteShelfItem.app)
        var folderItems = folders.map(FavoriteShelfItem.folder)
        if let insertion = externalInsertion {
            apps.insert(contentsOf: (0..<insertion.appCount).map { .insertionGap("app:\($0)") },
                        at: min(insertion.appIndex, apps.count))
            folderItems.insert(contentsOf: (0..<insertion.folderCount).map { .insertionGap("folder:\($0)") },
                               at: min(insertion.folderIndex, folderItems.count))
        }
        let hasUtilities = showsTrash || !folderItems.isEmpty
        let hasPreceding = !apps.isEmpty || hasUtilities
        return apps + (!apps.isEmpty && hasUtilities ? [.separator("utilities")] : [])
            + folderItems + (showsTrash ? [.trash(isFull: isTrashFull)] : [])
            + (showsApplications && hasPreceding ? [.separator("applications")] : [])
            + (showsApplications ? [.applications] : [])
    }

    private func applicationsAnchorMetrics() -> (offset: CGSize, size: CGSize) {
        let baseSize = FavoriteMagnificationLayout.iconSize * sizeScale
        guard let index = items.firstIndex(where: { $0.id == "utility:applications" }),
              let center = visualController.view?.iconCenter(for: "utility:applications"),
              let top = visualController.view?.iconTop(for: "utility:applications") else {
            return (CGSize(width: 0, height: visualLift), CGSize(width: baseSize, height: baseSize))
        }
        let separatorsBefore = items.prefix(index).filter(\.isSeparator).count
        let restingCenterX = (CGFloat(index) + 0.5) * itemStep - CGFloat(separatorsBefore) * 28 * sizeScale
        let shownSize = max(baseSize, (top.y - center.y) * 2)
        let slotHeight = SettingsStore.layoutReferenceTaskbarHeight * sizeScale
        return (
            CGSize(width: center.x - restingCenterX, height: center.y - slotHeight / 2),
            CGSize(width: shownSize, height: shownSize)
        )
    }

    var body: some View {
        HStack(spacing: itemStep - buttonSize) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if item.isSeparator {
                    Color.clear
                        .frame(width: FavoriteShelfSeparator.slotWidth * sizeScale, height: buttonSize)
                        .accessibilityHidden(true)
                } else if case .insertionGap = item {
                    Color.clear.frame(width: buttonSize, height: buttonSize)
                        .accessibilityHidden(true)
                } else {
                    FavoriteShelfButton(
                    item: item,
                    isRunning: runningApplicationIDs.contains(item.id),
                    badgeLabel: item.app.flatMap { badgeLabels[$0.id] },
                    shortcutLabel: item.app != nil && shortcutIndices.contains(index + 1)
                        ? OptionWindowHotKeyMonitor.favoriteShortcutLabels[index] : nil,
                    isMovable: item.isRemovable && !isFixedFinder(item) && !isTransient(item),
                    isTransient: isTransient(item),
                    sizeScale: sizeScale,
                    onOpen: {
                        guard draggedFavoriteID == nil else { return }
                        switch item {
                        case .app(let app): onOpen(app)
                        case .separator, .insertionGap: break
                        case .trash: onOpenTrash()
                        case .applications:
                            let anchor = applicationsAnchorMetrics()
                            onClickApplications(anchor.offset, anchor.size)
                        case .folder(let folder): onOpenFolder(folder)
                        }
                    }
                    )
                    .overlay {
                        if case .applications = item, let applicationsAnchorView {
                            applicationsAnchorView
                        }
                    }
                    .offset(y: -visualLift)
                    .offset(x: offset(for: item.id))
                    .animation(
                        draggedFavoriteID == item.id ? nil
                            : .easeOut(duration: reducesMotion ? 0.07 : 0.16),
                        value: hoverTargetID
                    )
                    .zIndex(draggedFavoriteID == item.id ? 20 : 0)
                    .transaction { transaction in
                        if draggedFavoriteID == item.id && !isSettlingDrag {
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        }
                    }
                }
            }
        }
        .frame(
            width: CGFloat(items.count) * itemStep
                - CGFloat(items.filter(\.isSeparator).count) * 28 * sizeScale,
            height: SettingsStore.layoutReferenceTaskbarHeight * sizeScale,
            alignment: .center
        )
        .background {
            FavoriteDockVisualView(
                items: items,
                calendarIconDate: calendarIconDate,
                runningApplicationIDs: runningApplicationIDs,
                badgeLabels: badgeLabels,
                sizeScale: sizeScale,
                peakScale: peakScale,
                visualLift: visualLift,
                dragOffsets: items.map { offset(for: $0.id) },
                dragSlotShifts: items.map { slotShift(for: $0.id) },
                draggedFavoriteID: draggedFavoriteID,
                isSettlingDrag: isSettlingDrag,
                showsHoverLabel: showsHoverLabel,
                suppressApplicationsHoverLabel: suppressApplicationsHoverLabel,
                controller: visualController,
                onMagnificationBoundsChange: onMagnificationBoundsChange
            )
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            FavoriteShelfInteractionView(
                shelfInset: hoverSafetyWidth,
                shelfWidth: hitRegionWidth ?? .greatestFiniteMagnitude,
                shelfHeight: SettingsStore.layoutReferenceTaskbarHeight * sizeScale,
                previewSize: FavoriteMagnificationLayout.iconSize * peakScale * sizeScale,
                onLocationChange: { location in
                    guard draggedFavoriteID == nil else { return }
                    let isHovered = location != nil
                    let isMagnifying = hoverFeedbackEnabled && draggedFavoriteID == nil && isHovered
                    if isPointerInside != isMagnifying { isPointerInside = isMagnifying }
                    onHoverActivity(isMagnifying)
                    // Pointer tracking also drives the name bubble when magnification is off.
                    guard let location else {
                        visualController.updatePointer(nil)
                        onMagnificationChange(false)
                        if isApplicationsHovered {
                            isApplicationsHovered = false
                            onHoverApplications(false, .zero, .zero)
                        }
                        return
                    }
                    let pointerX = FavoriteMagnificationLayout.clampedPointerX(
                        trackingX: location.x,
                        count: items.count,
                        sizeScale: sizeScale,
                        separatorCount: items.filter(\.isSeparator).count
                    )
                    visualController.updatePointer(pointerX)
                    onMagnificationChange(isMagnifying)
                    if showsApplications {
                        let hoveredID = visualController.view?.itemID(at: CGPoint(
                            x: location.x - hoverSafetyWidth,
                            y: location.y
                        ))
                        let hoveringApps = hoveredID == "utility:applications"
                        if hoveringApps != isApplicationsHovered {
                            isApplicationsHovered = hoveringApps
                            let anchor = hoveringApps ? applicationsAnchorMetrics() : (.zero, .zero)
                            onHoverApplications(hoveringApps, anchor.offset, anchor.size)
                        }
                    }
                },
                itemAt: { location in
                    visualController.view?.itemID(at: CGPoint(
                        x: location.x - hoverSafetyWidth,
                        y: location.y
                    ))
                },
                iconCenterForItem: { id in
                    guard let center = visualController.view?.iconCenter(for: id) else { return nil }
                    return CGPoint(x: center.x + hoverSafetyWidth, y: center.y)
                },
                iconTopForItem: { id in
                    guard let top = visualController.view?.iconTop(for: id) else { return nil }
                    return CGPoint(x: top.x + hoverSafetyWidth, y: top.y)
                },
                iconForItem: { id in items.first { $0.id == id }?.icon(for: calendarIconDate) },
                canDragItem: { id in
                    guard let item = items.first(where: { $0.id == id }) else { return false }
                    return item.isRemovable && !isFixedFinder(item) && !isTransient(item)
                },
                onClick: { id in
                    guard draggedFavoriteID == nil, let item = items.first(where: { $0.id == id }) else { return }
                    switch item {
                    case .app(let app): onOpen(app)
                    case .folder(let folder): onOpenFolder(folder)
                    case .trash: onOpenTrash()
                    case .applications:
                        let anchor = applicationsAnchorMetrics()
                        onClickApplications(anchor.offset, anchor.size)
                    case .separator, .insertionGap: break
                    }
                },
                onContextMenu: { id in
                    guard draggedFavoriteID == nil,
                          let item = items.first(where: { $0.id == id }) else { return [] }
                    return contextMenuActions(for: item)
                },
                onContextMenuVisibilityChange: { id in
                    visualController.view?.setContextMenuItem(id)
                    visualController.setMagnificationPaused(id != nil)
                },
                onDragUpdate: updateDrag,
                onDragEnd: { outside in
                    visualController.view?.hideDraggedItem(nil)
                    if outside { clearDropTarget() }
                    if outside { onMagnificationChange(false) }
                    finishReorder(outside: outside)
                },
                onRemove: { id in
                    guard let item = items.first(where: { $0.id == id }) else { return }
                    clearDropTarget()
                    dragTranslation = 0
                    dragPointerX = nil
                    dragStartLayoutOffset = 0
                    draggedFavoriteID = nil
                    dragStartIDs = nil
                    isSettlingDrag = false
                    visualController.view?.hideDraggedItem(nil)
                    onMagnificationChange(false)
                    remove(item)
                    onDragChanged(false)
                },
                onDropPreview: { urls, x in
                    if isTrashDropTarget(x: x) { externalInsertion = nil; return !urls.isEmpty }
                    let incoming = newDropURLs(FavoriteShelfDrop.supportedURLs(urls))
                    guard !incoming.isEmpty else { return false }
                    let insertion = insertionTarget(incoming, x: x)
                    if externalInsertion != insertion {
                        withAnimation(.easeOut(duration: 0.16)) { externalInsertion = insertion }
                    }
                    return true
                },
                onDropURLs: { urls, x in
                    if isTrashDropTarget(x: x) {
                        externalInsertion = nil
                        do {
                            try TrashActions.moveToTrash(urls)
                            return true
                        } catch {
                            let alert = NSAlert(error: error)
                            alert.runModal()
                            return false
                        }
                    }
                    let incoming = newDropURLs(FavoriteShelfDrop.supportedURLs(urls))
                    guard !incoming.isEmpty else { return false }
                    let insertion = insertionTarget(incoming, x: x)
                    externalInsertion = nil
                    return onDropURLs(incoming, insertion)
                },
                onExternalDragChanged: { active in
                    if !active { withAnimation(.easeOut(duration: 0.16)) { externalInsertion = nil } }
                    onDragChanged(active)
                }
            )
            .frame(width: CGFloat(items.count) * itemStep
                - CGFloat(items.filter(\.isSeparator).count) * 28 * sizeScale
                + 2 * hoverSafetyWidth,
                height: SettingsStore.layoutReferenceTaskbarHeight * sizeScale
                    + FavoriteMagnificationLayout.headroom(for: sizeScale, peakScale: peakScale))
        }
        .contentShape(Rectangle())
        .onChange(of: hoverFeedbackEnabled) { enabled in
            if !enabled {
                isPointerInside = false
                onHoverActivity(false)
                visualController.updatePointer(nil)
                onMagnificationChange(false)
            }
        }
        .onReceive(Timer.publish(every: 20, on: .main, in: .common).autoconnect()) { date in
            if CalendarLiveIcon.dayKey(for: calendarIconDate) != CalendarLiveIcon.dayKey(for: date) {
                calendarIconDate = date
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            calendarIconDate = Date()
        }
        .onDisappear {
            isPointerInside = false
            onHoverActivity(false)
            visualController.updatePointer(nil)
            onMagnificationChange(false)
        }
    }

    private func remove(_ item: FavoriteShelfItem) {
        guard !isFixedFinder(item), !isTransient(item) else { return }
        switch item {
        case .app(let app): onRemove(app)
        case .folder(let folder): onRemoveFolder(folder)
        case .separator, .trash, .applications, .insertionGap: break
        }
    }

    private func isFixedFinder(_ item: FavoriteShelfItem) -> Bool {
        keepsSystemFinder && item.app?.bundleIdentifier == "com.apple.finder"
    }

    private func isTransient(_ item: FavoriteShelfItem) -> Bool {
        transientAppIDs.contains(item.id)
    }

    private func contextMenuActions(for item: FavoriteShelfItem) -> [FavoriteShelfMenuAction] {
        func action(_ title: String, _ perform: @escaping () -> Void) -> FavoriteShelfMenuAction {
            FavoriteShelfMenuAction(title: title, perform: perform)
        }

        switch item {
        case .app(let app):
            var actions = [action("打开", { onOpen(app) })]
            if app.bundleIdentifier == "com.apple.finder" {
                let sidebarFavorites = FinderSidebarFavoritesService.favorites()
                if !sidebarFavorites.isEmpty {
                    actions.append(.separator)
                    for favorite in sidebarFavorites {
                        if let url = favorite.url {
                            actions.append(action("打开 \(favorite.name)", {
                                onPerformWindowAction { NSWorkspace.shared.open(url) }
                            }))
                        } else {
                            actions.append(FavoriteShelfMenuAction(
                                title: "打开 \(favorite.name)（当前不可用）",
                                isEnabled: false,
                                perform: {}
                            ))
                        }
                    }
                    actions.append(.separator)
                }
            }
            let runningApp = NSWorkspace.shared.runningApplications.first { running in
                if let bundleIdentifier = app.bundleIdentifier {
                    return running.bundleIdentifier == bundleIdentifier
                }
                guard let bundlePath = app.bundlePath else { return false }
                return running.bundleURL?.path == bundlePath
            }
            if runningApp != nil { actions.append(action("退出", { onQuit(app) })) }
            var displayActions: [FavoriteShelfMenuAction] = []
            if isTransient(item) {
                displayActions.append(action("固定到收藏", { onPinTransient(app) }))
            } else if !isFixedFinder(item) {
                displayActions.append(action("取消收藏", { onRemove(app) }))
            }
            displayActions += displayMenuActions(app)
            if !displayActions.isEmpty {
                actions.append(.separator)
                actions += displayActions
            }
            return actions
        case .folder(let folder):
            return [action("打开", { onOpenFolder(folder) }), .separator,
                action("取消收藏", { onRemoveFolder(folder) })]
        case .trash:
            return trashMenuActions(isFull: isTrashFull, open: onOpenTrash,
                restore: onRestoreLatestTrashItem, empty: onEmptyTrash, close: onCloseTrash)
        case .applications, .separator, .insertionGap:
            return []
        }
    }

    private func isTrashDropTarget(x: CGFloat) -> Bool {
        guard showsTrash, let center = visualController.view?.iconCenter(for: "utility:trash") else { return false }
        return abs(x - center.x) <= 16 * sizeScale
    }

    private func newDropURLs(_ urls: [URL]) -> [URL] {
        var seenApps = Set(favorites.map(\.id))
        var seenFolders = Set(folders.map { $0.url.resolvingSymlinksInPath().path })
        return urls.filter { url in
            if url.pathExtension.lowercased() == "app" {
                let bundle = Bundle(url: url)
                let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let id = bundle?.bundleIdentifier ?? "name:\(name)"
                return seenApps.insert(id).inserted
            }
            return seenFolders.insert(url.path).inserted
        }
    }

    private func insertionTarget(_ urls: [URL], x: CGFloat) -> FavoriteShelfInsertion {
        let appCount = urls.filter { $0.pathExtension.lowercased() == "app" }.count
        return FavoriteShelfInsertion.target(pointerX: x / sizeScale, appTotal: favorites.count,
            folderTotal: folders.count, hasUtilities: showsTrash || !folders.isEmpty || urls.count > appCount,
            incomingApps: appCount, incomingFolders: urls.count - appCount, preview: externalInsertion)
    }

    private func updateDrag(_ id: String, _ translation: CGSize, _ outside: Bool,
                            _ trackingX: CGFloat) {
        guard !isSettlingDrag, let item = items.first(where: { $0.id == id }),
              item.isRemovable, !isFixedFinder(item), !isTransient(item) else { return }
        if draggedFavoriteID == nil {
            draggedFavoriteID = id
            dragStartIDs = item.app != nil ? favorites.map(\.id)
                : folders.map { "utility:folder:\($0.id)" }
            let startPointerX = FavoriteMagnificationLayout.clampedPointerX(
                trackingX: trackingX - translation.width, count: items.count,
                sizeScale: sizeScale, separatorCount: items.filter(\.isSeparator).count)
            if let index = items.firstIndex(where: { $0.id == id }) {
                dragStartLayoutOffset = FavoriteMagnificationLayout(
                    count: items.count, pointerX: hoverFeedbackEnabled ? startPointerX : nil,
                    sizeScale: sizeScale,
                    separatorIndices: Set(items.indices.filter { items[$0].isSeparator }),
                    peakScale: peakScale
                ).offsets[index]
            }
            isPointerInside = false
            onHoverActivity(false)
            onDragChanged(true)
        }
        guard draggedFavoriteID == id else { return }
        onDragChanged(true)
        dragTranslation = outside ? 0 : translation.width
        dragPointerX = outside || !hoverFeedbackEnabled ? nil
            : FavoriteMagnificationLayout.clampedPointerX(
                trackingX: trackingX, count: items.count,
                sizeScale: sizeScale, separatorCount: items.filter(\.isSeparator).count)
        visualController.updatePointer(dragPointerX)
        onMagnificationChange(dragPointerX != nil)
        visualController.view?.hideDraggedItem(outside ? id : nil)
        if outside { clearDropTarget() } else { updateDropTarget() }
    }

    private func updateDropTarget() {
        guard let draggedFavoriteID,
              let keys = dragStartIDs,
              let sourceIndex = keys.firstIndex(of: draggedFavoriteID),
              let targetIndex = FavoriteShelfReorderTarget.index(
                source: sourceIndex, count: keys.count, translation: dragTranslation,
                itemStep: itemStep,
                previewIndex: hoverTargetID.flatMap { keys.firstIndex(of: $0) }) else {
            clearDropTarget()
            return
        }
        hoverTargetID = keys[targetIndex]
    }

    private func clearDropTarget() {
        hoverTargetID = nil
    }

    private func finishReorder(outside: Bool) {
        isSettlingDrag = true
        let releaseTargetIndex: Int? = {
            guard !outside, let draggedFavoriteID,
                  let keys = dragStartIDs,
                  let sourceIndex = keys.firstIndex(of: draggedFavoriteID) else { return nil }
            return FavoriteShelfReorderTarget.index(source: sourceIndex, count: keys.count,
                translation: dragTranslation, itemStep: itemStep,
                previewIndex: hoverTargetID.flatMap { keys.firstIndex(of: $0) })
        }()
        let dragLayout = dragPointerX.map { pointerX in
            FavoriteMagnificationLayout(
                count: items.count, pointerX: pointerX, sizeScale: sizeScale,
                separatorIndices: Set(items.indices.filter { items[$0].isSeparator }),
                peakScale: peakScale)
        }
        if let sourceID = draggedFavoriteID,
           let sourceItemIndex = items.firstIndex(where: { $0.id == sourceID }),
           let currentOffset = dragLayout?.offsets[sourceItemIndex] {
            dragTranslation += dragStartLayoutOffset - currentOffset
            dragStartLayoutOffset = currentOffset
        }
        if let sourceID = draggedFavoriteID,
           let targetIndex = releaseTargetIndex,
           var keys = dragStartIDs,
           let sourceIndex = keys.firstIndex(of: sourceID) {
            keys.remove(at: sourceIndex)
            keys.insert(sourceID, at: targetIndex)
            if let newIndex = keys.firstIndex(of: sourceID) {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    let shift = newIndex - sourceIndex
                    dragTranslation -= CGFloat(shift) * itemStep
                    if let sourceItemIndex = items.firstIndex(where: { $0.id == sourceID }),
                       let newOffset = dragLayout?.offsets[sourceItemIndex + shift] {
                        dragTranslation += dragStartLayoutOffset - newOffset
                        dragStartLayoutOffset = newOffset
                    }
                    hoverTargetID = nil
                    if sourceID.hasPrefix("utility:folder:") {
                        onReorderFolders(keys.map { String($0.dropFirst("utility:folder:".count)) })
                    } else {
                        onReorder(keys)
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            withAnimation(.easeOut(duration: FavoriteShelfInteractionMetrics.dragSettleDuration)) {
                dragTranslation = 0
                hoverTargetID = nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            draggedFavoriteID = nil
            dragStartIDs = nil
            dragPointerX = nil
            dragStartLayoutOffset = 0
            isSettlingDrag = false
            isPointerInside = !outside && hoverFeedbackEnabled
            onHoverActivity(isPointerInside)
            onDragChanged(false)
        }
    }

    private func offset(for id: String) -> CGFloat {
        if id == draggedFavoriteID {
            guard let dragPointerX,
                  let index = items.firstIndex(where: { $0.id == id }) else { return dragTranslation }
            let layout = FavoriteMagnificationLayout(
                count: items.count, pointerX: dragPointerX, sizeScale: sizeScale,
                separatorIndices: Set(items.indices.filter { items[$0].isSeparator }),
                peakScale: peakScale)
            return dragTranslation + dragStartLayoutOffset - layout.offsets[index]
        }
        guard let draggedFavoriteID,
              let hoverTargetID,
              let keys = dragStartIDs,
              let sourceIndex = keys.firstIndex(of: draggedFavoriteID),
              let targetIndex = keys.firstIndex(of: hoverTargetID),
              let itemIndex = keys.firstIndex(of: id),
              let visualIndex = items.firstIndex(where: { $0.id == id }) else { return 0 }
        let layout = FavoriteMagnificationLayout(
            count: items.count, pointerX: dragPointerX, sizeScale: sizeScale,
            separatorIndices: Set(items.indices.filter { items[$0].isSeparator }),
            peakScale: peakScale)
        if sourceIndex < targetIndex, (sourceIndex + 1...targetIndex).contains(itemIndex) {
            return layout.reorderPreviewOffset(from: visualIndex,
                to: visualIndex - 1, sizeScale: sizeScale)
        }
        if targetIndex < sourceIndex, (targetIndex..<sourceIndex).contains(itemIndex) {
            return layout.reorderPreviewOffset(from: visualIndex,
                to: visualIndex + 1, sizeScale: sizeScale)
        }
        return 0
    }

    private func slotShift(for id: String) -> Int {
        guard let draggedFavoriteID, id != draggedFavoriteID,
              let hoverTargetID, let keys = dragStartIDs,
              let source = keys.firstIndex(of: draggedFavoriteID),
              let target = keys.firstIndex(of: hoverTargetID),
              let index = keys.firstIndex(of: id) else { return 0 }
        if source < target, (source + 1...target).contains(index) { return -1 }
        if target < source, (target..<source).contains(index) { return 1 }
        return 0
    }
}

@MainActor
private final class FavoriteDockVisualController {
    weak var view: FavoriteDockVisualView.DrawingView?

    func updatePointer(_ x: CGFloat?) {
        view?.updatePointer(x)
    }

    func setMagnificationPaused(_ paused: Bool) {
        view?.setMagnificationPaused(paused)
    }

}

private struct FavoriteDockVisualView: NSViewRepresentable {
    let items: [FavoriteShelfItem]
    let calendarIconDate: Date
    let runningApplicationIDs: Set<String>
    let badgeLabels: [String: String]
    let sizeScale: CGFloat
    let peakScale: CGFloat
    let visualLift: CGFloat
    let dragOffsets: [CGFloat]
    let dragSlotShifts: [Int]
    let draggedFavoriteID: String?
    let isSettlingDrag: Bool
    let showsHoverLabel: Bool
    var suppressApplicationsHoverLabel: Bool = false
    let controller: FavoriteDockVisualController
    let onMagnificationBoundsChange: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> DrawingView {
        let view = DrawingView()
        controller.view = view
        view.onMagnificationBoundsChange = onMagnificationBoundsChange
        view.configure(
            items: items,
            calendarIconDate: calendarIconDate,
            runningApplicationIDs: runningApplicationIDs,
            badgeLabels: badgeLabels,
            sizeScale: sizeScale,
            peakScale: peakScale,
            visualLift: visualLift,
            dragOffsets: dragOffsets,
            dragSlotShifts: dragSlotShifts,
            draggedFavoriteID: draggedFavoriteID,
            isSettlingDrag: isSettlingDrag,
            showsHoverLabel: showsHoverLabel,
            suppressApplicationsHoverLabel: suppressApplicationsHoverLabel
        )
        return view
    }

    func updateNSView(_ view: DrawingView, context: Context) {
        controller.view = view
        view.onMagnificationBoundsChange = onMagnificationBoundsChange
        view.configure(
            items: items,
            calendarIconDate: calendarIconDate,
            runningApplicationIDs: runningApplicationIDs,
            badgeLabels: badgeLabels,
            sizeScale: sizeScale,
            peakScale: peakScale,
            visualLift: visualLift,
            dragOffsets: dragOffsets,
            dragSlotShifts: dragSlotShifts,
            draggedFavoriteID: draggedFavoriteID,
            isSettlingDrag: isSettlingDrag,
            showsHoverLabel: showsHoverLabel,
            suppressApplicationsHoverLabel: suppressApplicationsHoverLabel
        )
    }

    static func dismantleNSView(_ view: DrawingView, coordinator: ()) {
        view.onMagnificationBoundsChange = nil
        view.updatePointer(nil)
    }

    final class DrawingView: NSView {
        var onMagnificationBoundsChange: ((CGFloat, CGFloat) -> Void)?
        private var lastReportedBounds: (CGFloat, CGFloat)?
        private static func highResolutionIcon(for item: FavoriteShelfItem, date: Date) -> CGImage? {
            let image = item.icon(for: date)
            if item.trashIsFull != nil,
               let lightAppearance = NSAppearance(named: .aqua) {
                var lightTrashIcon: CGImage?
                lightAppearance.performAsCurrentDrawingAppearance {
                    guard let bitmap = NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                        isPlanar: false, colorSpaceName: .deviceRGB,
                        bytesPerRow: 0, bitsPerPixel: 0
                    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                        return
                    }
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    image.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256))
                    context.flushGraphics()
                    NSGraphicsContext.restoreGraphicsState()
                    lightTrashIcon = bitmap.cgImage
                }
                return lightTrashIcon
            }
            var proposedRect = NSRect(x: 0, y: 0, width: 128, height: 128)
            return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        }

        private struct EntryState {
            let iconPosition: CGPoint
            let iconScale: CGFloat
            let indicatorPosition: CGPoint
            let indicatorScale: CGFloat
        }

        private var iconLayers: [CALayer] = []
        private var pressOverlayLayers: [String: CALayer] = [:]
        private var indicatorLayers: [CALayer] = []
        private var badgeLayers: [CALayer] = []
        private let hoverLabelLayer = CAShapeLayer()
        private var hoverBubble: FloatingBubbleHintView?
        private var smallBubbleSettingsObserver: NSObjectProtocol?
        private let hoverLabelTextLayer = CATextLayer()
        private var favoriteIDs: [String] = []
        private var favoriteNames: [String] = []
        private var trashIsFull: Bool?
        private var calendarDayKey: String?
        private var isMagnificationPaused = false
        private var runningApplicationIDs: Set<String> = []
        private var badgeLabels: [String: String] = [:]
        private var sizeScale: CGFloat = 1
        private var peakScale: CGFloat = FavoriteMagnificationLayout.maximumScale
        private var visualLift: CGFloat = 0
        private var dragOffsets: [CGFloat] = []
        private var slotShiftStarts: [CGFloat] = []
        private var slotShiftTargets: [CGFloat] = []
        private var slotShiftStartedAt: CFTimeInterval?
        private var slotShiftTimer: Timer?
        private var draggedFavoriteID: String?
        private var isSettlingDrag = false
        private var showsHoverLabel = false
        private var displayedHoverLabel: String?
        private var hoverLabelWidth: CGFloat = 0
        private var hoverLabelSizeScale: CGFloat = 0
        private var pointerX: CGFloat?
        private var entryStates: [EntryState] = []
        private var entryStartedAt: CFTimeInterval?
        private var isExitingMagnification = false
        private var entryTimer: Timer?
        private var mouseDownMonitor: Any?
        private var mouseUpMonitor: Any?
        private var globalMouseUpMonitor: Any?
        private var pressedFavoriteID: String?
        private var contextMenuFavoriteID: String?
        private var pressGeneration = 0

        deinit {
            if let smallBubbleSettingsObserver { NotificationCenter.default.removeObserver(smallBubbleSettingsObserver) }
            entryTimer?.invalidate()
            slotShiftTimer?.invalidate()
            if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
            if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
            if let globalMouseUpMonitor { NSEvent.removeMonitor(globalMouseUpMonitor) }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = false
            hoverLabelLayer.zPosition = 30
            hoverLabelLayer.fillColor = NSColor(calibratedWhite: 0.96, alpha: 0.96).cgColor
            hoverLabelLayer.strokeColor = NSColor(calibratedWhite: 0.18, alpha: 0.20).cgColor
            hoverLabelLayer.lineWidth = 0.75
            hoverLabelLayer.shadowColor = NSColor.black.cgColor
            hoverLabelLayer.shadowOpacity = 0.20
            hoverLabelLayer.shadowRadius = 5
            hoverLabelLayer.shadowOffset = CGSize(width: 0, height: -2)
            hoverLabelLayer.opacity = 0
            hoverLabelTextLayer.alignmentMode = .center
            hoverLabelTextLayer.truncationMode = .end
            hoverLabelTextLayer.foregroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
            hoverLabelLayer.addSublayer(hoverLabelTextLayer)
            layer?.addSublayer(hoverLabelLayer)
            smallBubbleSettingsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
            ) { [weak self] _ in
                self?.updateLayers(animated: false)
            }
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let mouseDownMonitor {
                NSEvent.removeMonitor(mouseDownMonitor)
                self.mouseDownMonitor = nil
            }
            if let mouseUpMonitor {
                NSEvent.removeMonitor(mouseUpMonitor)
                self.mouseUpMonitor = nil
            }
            if let globalMouseUpMonitor {
                NSEvent.removeMonitor(globalMouseUpMonitor)
                self.globalMouseUpMonitor = nil
            }
            if window == nil { finishPress() }
            guard window != nil else { return }
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if let id = self.favoriteItemID(at: point, utilitiesOnly: false) {
                    self.beginPress(for: id)
                }
                return event
            }
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                self?.finishPress()
                return event
            }
            globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
                DispatchQueue.main.async { self?.finishPress() }
            }
        }

        func beginPress(for id: String) {
            guard let index = favoriteIDs.firstIndex(of: id),
                  !id.hasPrefix("utility:separator") else { return }
            finishPress()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (otherID, overlay) in pressOverlayLayers where otherID != id {
                overlay.removeAllAnimations()
                overlay.opacity = 0
            }
            CATransaction.commit()
            pressedFavoriteID = id
            pressGeneration += 1
            let icon = iconLayers[index]
            let overlay: CALayer
            if let existing = pressOverlayLayers[id] {
                overlay = existing
            } else {
                overlay = CALayer()
                overlay.backgroundColor = NSColor.black.cgColor
                overlay.opacity = 0
                let mask = CALayer()
                mask.contentsGravity = .resizeAspect
                overlay.mask = mask
                icon.addSublayer(overlay)
                pressOverlayLayers[id] = overlay
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlay.frame = icon.bounds
            overlay.mask?.frame = overlay.bounds
            overlay.mask?.contents = icon.contents
            CATransaction.commit()

            overlay.removeAllAnimations()
            overlay.opacity = Float(FavoriteShelfInteractionMetrics.pressedOpacity)
        }

        func setContextMenuItem(_ id: String?) {
            if let previous = contextMenuFavoriteID {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                pressOverlayLayers[previous]?.opacity = 0
                CATransaction.commit()
                pressedFavoriteID = nil
                pressGeneration += 1
            }
            contextMenuFavoriteID = nil
            if let id {
                beginPress(for: id)
                contextMenuFavoriteID = id
            }
        }

        private func finishPress() {
            guard contextMenuFavoriteID == nil else { return }
            guard let id = pressedFavoriteID else { return }
            pressedFavoriteID = nil
            pressGeneration += 1
            let generation = pressGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.pressGeneration == generation,
                      let overlay = self.pressOverlayLayers[id] else { return }
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.14)
                overlay.opacity = 0
                CATransaction.commit()
            }
        }

        func utilityItemID(at point: CGPoint) -> String? {
            favoriteItemID(at: point, utilitiesOnly: true)
        }

        func itemID(at point: CGPoint) -> String? {
            favoriteItemID(at: point, utilitiesOnly: false)
        }

        func iconCenter(for id: String) -> CGPoint? {
            guard let index = favoriteIDs.firstIndex(of: id),
                  iconLayers.indices.contains(index) else { return nil }
            let icon = iconLayers[index].presentation() ?? iconLayers[index]
            return CGPoint(x: icon.position.x,
                           y: icon.position.y + icon.bounds.height * icon.transform.m22 / 2)
        }

        func iconTop(for id: String) -> CGPoint? {
            guard let index = favoriteIDs.firstIndex(of: id), iconLayers.indices.contains(index) else { return nil }
            let icon = iconLayers[index].presentation() ?? iconLayers[index]
            return CGPoint(x: icon.position.x, y: icon.position.y + icon.bounds.height * icon.transform.m22)
        }

        private var hiddenDraggedItemID: String?

        func hideDraggedItem(_ id: String?) {
            hiddenDraggedItemID = id
            updateLayers(animated: false)
        }

        private func favoriteItemID(at point: CGPoint, utilitiesOnly: Bool) -> String? {
            var bottomCandidate: (id: String, scale: CGFloat, distance: CGFloat)?
            for index in iconLayers.indices.reversed() {
                let id = favoriteIDs[index]
                guard !id.hasPrefix("utility:separator"), !id.hasPrefix("drop-gap:"),
                      id != hiddenDraggedItemID else { continue }
                if utilitiesOnly,
                   id != "utility:trash" && id != "utility:applications" && !id.hasPrefix("utility:folder:") { continue }
                let icon = iconLayers[index].presentation() ?? iconLayers[index]
                let halfWidth = max(15 * sizeScale, icon.bounds.width * icon.transform.m11 / 2)
                let halfHeight = max(15 * sizeScale, icon.bounds.height * icon.transform.m22 / 2)
                let centerY = icon.position.y + icon.bounds.height * icon.transform.m22 / 2
                let horizontalDistance = abs(point.x - icon.position.x)
                guard horizontalDistance <= halfWidth else { continue }
                if abs(point.y - centerY) <= halfHeight {
                    return id
                }
                // Keep the visible icon's horizontal footprint clickable all
                // the way down to the screen edge, including while magnified.
                if point.y >= 0, point.y < centerY - halfHeight,
                   point.y <= SettingsStore.layoutReferenceTaskbarHeight * sizeScale {
                    let scale = icon.transform.m11
                    if let previous = bottomCandidate {
                        guard scale > previous.scale + 0.001
                            || (abs(scale - previous.scale) <= 0.001
                                && horizontalDistance < previous.distance) else { continue }
                    }
                    bottomCandidate = (id, scale, horizontalDistance)
                }
            }
            return bottomCandidate?.id
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateIndicatorColors()
        }

        func configure(
            items: [FavoriteShelfItem],
            calendarIconDate: Date,
            runningApplicationIDs: Set<String>,
            badgeLabels: [String: String],
            sizeScale: CGFloat,
            peakScale: CGFloat,
            visualLift: CGFloat,
            dragOffsets: [CGFloat],
            dragSlotShifts: [Int],
            draggedFavoriteID: String?,
            isSettlingDrag: Bool,
            showsHoverLabel: Bool,
            suppressApplicationsHoverLabel: Bool = false
        ) {
            let ids = items.map(\.id)
            let names = items.map { $0.id == "utility:applications" && suppressApplicationsHoverLabel ? "" : $0.name }
            let nextTrashIsFull = items.compactMap(\.trashIsFull).first
            let trashChanged = trashIsFull != nextTrashIsFull
            let nextCalendarDayKey = CalendarLiveIcon.dayKey(for: calendarIconDate)
            let calendarDayChanged = calendarDayKey != nextCalendarDayKey
            let favoritesChanged = ids != favoriteIDs
            let namesChanged = names != favoriteNames
            let indicatorsChanged = favoritesChanged || self.runningApplicationIDs != runningApplicationIDs
            let badgesChanged = favoritesChanged || self.badgeLabels != badgeLabels
            let sizeChanged = self.sizeScale != sizeScale || self.peakScale != peakScale
                || self.visualLift != visualLift
            let retainedIDs = Set(favoriteIDs)
            if favoritesChanged {
                stopEntryAnimation()
                stopSlotShiftAnimation()
                let oldIcons = Dictionary(uniqueKeysWithValues: zip(favoriteIDs, iconLayers))
                let oldIndicators = Dictionary(uniqueKeysWithValues: zip(favoriteIDs, indicatorLayers))
                let oldBadges = Dictionary(uniqueKeysWithValues: zip(favoriteIDs, badgeLayers))
                let nextIDs = Set(ids)
                for id in favoriteIDs where !nextIDs.contains(id) {
                    oldIcons[id]?.removeFromSuperlayer()
                    oldIndicators[id]?.removeFromSuperlayer()
                    oldBadges[id]?.removeFromSuperlayer()
                    pressOverlayLayers[id] = nil
                }
                iconLayers = items.map { item in
                    if let existing = oldIcons[item.id] { return existing }
                    let icon = CALayer()
                    if item.isSeparator {
                        icon.backgroundColor = favoriteShelfSeparatorColor.cgColor
                        icon.cornerRadius = FavoriteShelfSeparator.width * sizeScale / 2
                    } else {
                        icon.contents = Self.highResolutionIcon(for: item, date: calendarIconDate)
                    }
                    icon.contentsGravity = .resizeAspect
                    icon.magnificationFilter = .linear
                    icon.minificationFilter = .trilinear
                    icon.anchorPoint = CGPoint(x: 0.5, y: 0)
                    icon.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
                    layer?.addSublayer(icon)
                    return icon
                }
                indicatorLayers = items.map { item in
                    if let existing = oldIndicators[item.id] { return existing }
                    let indicator = CALayer()
                    indicator.zPosition = 0.5
                    layer?.addSublayer(indicator)
                    return indicator
                }
                badgeLayers = items.map { item in
                    if let existing = oldBadges[item.id] { return existing }
                    let badge = CALayer()
                    badge.zPosition = 22
                    badge.backgroundColor = favoriteShelfBadgeColor.cgColor
                    badge.masksToBounds = true
                    badge.opacity = 0
                    let text = CATextLayer()
                    text.alignmentMode = .center
                    text.foregroundColor = NSColor.white.cgColor
                    badge.addSublayer(text)
                    layer?.addSublayer(badge)
                    return badge
                }
                favoriteIDs = ids
                slotShiftStarts = Array(repeating: 0, count: ids.count)
                slotShiftTargets = slotShiftStarts
            }
            if trashChanged,
               let index = items.firstIndex(where: { $0.trashIsFull != nil }) {
                iconLayers[index].contents = Self.highResolutionIcon(
                    for: items[index], date: calendarIconDate)
            }
            if calendarDayChanged {
                for (index, item) in items.enumerated() {
                    guard let app = item.app, CalendarLiveIcon.isCalendar(app) else { continue }
                    iconLayers[index].contents = Self.highResolutionIcon(
                        for: item, date: calendarIconDate)
                }
            }
            calendarDayKey = nextCalendarDayKey
            trashIsFull = nextTrashIsFull
            favoriteNames = names
            let dragOffsetsChanged = self.dragOffsets != dragOffsets
            let nextSlotShifts = dragSlotShifts.map(CGFloat.init)
            let slotShiftsChanged = nextSlotShifts != slotShiftTargets
            guard indicatorsChanged || badgesChanged || namesChanged || trashChanged
                    || calendarDayChanged
                    || sizeChanged || dragOffsetsChanged || slotShiftsChanged
                    || self.draggedFavoriteID != draggedFavoriteID
                    || self.isSettlingDrag != isSettlingDrag
                    || self.showsHoverLabel != showsHoverLabel else { return }
            self.runningApplicationIDs = runningApplicationIDs
            self.badgeLabels = badgeLabels
            self.sizeScale = sizeScale
            self.peakScale = peakScale
            self.visualLift = visualLift
            self.dragOffsets = dragOffsets
            if slotShiftsChanged { animateSlotShifts(to: nextSlotShifts) }
            self.draggedFavoriteID = draggedFavoriteID
            self.isSettlingDrag = isSettlingDrag
            self.showsHoverLabel = showsHoverLabel
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let iconSize = FavoriteMagnificationLayout.iconSize * sizeScale
            for (index, icon) in iconLayers.enumerated() {
                let isSeparator = items[index].isSeparator
                icon.bounds = CGRect(
                    x: 0, y: 0,
                    width: isSeparator ? FavoriteShelfSeparator.width * sizeScale : iconSize,
                    height: isSeparator ? FavoriteShelfSeparator.height * sizeScale : iconSize
                )
                if isSeparator { icon.cornerRadius = FavoriteShelfSeparator.width * sizeScale / 2 }
            }
            for indicator in indicatorLayers {
                let diameter = FavoriteMagnificationLayout.indicatorDiameter * sizeScale
                indicator.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
                indicator.cornerRadius = diameter / 2
            }
            if badgesChanged || sizeChanged {
                for (index, badge) in badgeLayers.enumerated() {
                    configureBadge(badge, label: badgeLabels[ids[index]], sizeScale: sizeScale)
                }
            }
            hoverLabelTextLayer.contentsScale = window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor ?? 2
            if indicatorsChanged { updateIndicatorColors() }
            CATransaction.commit()
            updateLayers(animated: false, animateReorderIDs: favoritesChanged ? retainedIDs : [])
        }

        private func slotShiftProgress(at time: CFTimeInterval) -> CGFloat {
            guard let slotShiftStartedAt else { return 1 }
            let fraction = min(1, max(0, CGFloat((time - slotShiftStartedAt) / 0.16)))
            return 1 - pow(1 - fraction, 3)
        }

        private func currentSlotShift(at index: Int, time: CFTimeInterval) -> CGFloat {
            guard slotShiftTargets.indices.contains(index) else { return 0 }
            let progress = slotShiftProgress(at: time)
            return slotShiftStarts[index]
                + (slotShiftTargets[index] - slotShiftStarts[index]) * progress
        }

        private func animateSlotShifts(to targets: [CGFloat]) {
            let now = CACurrentMediaTime()
            slotShiftStarts = targets.indices.map { currentSlotShift(at: $0, time: now) }
            slotShiftTargets = targets
            slotShiftStartedAt = now
            if slotShiftTimer == nil {
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    if self.slotShiftProgress(at: CACurrentMediaTime()) >= 1 {
                        self.stopSlotShiftAnimation()
                    }
                    self.updateLayers(animated: false)
                }
                slotShiftTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }

        private func stopSlotShiftAnimation() {
            slotShiftTimer?.invalidate()
            slotShiftTimer = nil
            slotShiftStartedAt = nil
            slotShiftStarts = slotShiftTargets
        }

        private func updateIndicatorColors() {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            for indicator in indicatorLayers {
                indicator.backgroundColor = favoriteRunningIndicatorColor(isDark: isDark).cgColor
            }
        }

        private func configureBadge(_ badge: CALayer, label: String?, sizeScale: CGFloat) {
            guard let label, let text = badge.sublayers?.first as? CATextLayer else { return }
            let height = FavoriteShelfBadgeMetrics.height * sizeScale
            let width = FavoriteShelfBadgeMetrics.width(for: label) * sizeScale
            badge.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            badge.cornerRadius = height / 2
            text.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            text.font = NSFont.systemFont(ofSize: FavoriteShelfBadgeMetrics.fontSize * sizeScale, weight: .semibold)
            text.fontSize = FavoriteShelfBadgeMetrics.fontSize * sizeScale
            text.string = label
            text.frame = CGRect(x: 1, y: 1.5 * sizeScale,
                                width: width - 2, height: height - 2 * sizeScale)
        }

        func updatePointer(_ x: CGFloat?) {
            guard !isMagnificationPaused else { return }
            guard pointerX != x else { return }
            if (pointerX == nil) != (x == nil) {
                entryStates = zip(iconLayers, indicatorLayers).map { icon, indicator in
                    let visibleIcon = icon.presentation() ?? icon
                    let visibleIndicator = indicator.presentation() ?? indicator
                    return EntryState(
                        iconPosition: visibleIcon.position,
                        iconScale: visibleIcon.transform.m11,
                        indicatorPosition: visibleIndicator.position,
                        indicatorScale: visibleIndicator.transform.m11
                    )
                }
                (iconLayers + indicatorLayers + badgeLayers).forEach { $0.removeAllAnimations() }
                entryStartedAt = CACurrentMediaTime()
                isExitingMagnification = x == nil
                entryTimer?.invalidate()
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                    self?.advanceEntryAnimation()
                }
                RunLoop.main.add(timer, forMode: .common)
                entryTimer = timer
            }
            pointerX = x
            updateLayers(animated: false)
        }

        func setMagnificationPaused(_ paused: Bool) {
            guard isMagnificationPaused != paused else { return }
            if paused {
                hoverLabelLayer.opacity = 0
                hoverBubble?.isHidden = true
                stopEntryAnimation()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for icon in iconLayers + indicatorLayers + badgeLayers {
                    let visible = icon.presentation() ?? icon
                    let position = visible.position
                    let transform = visible.transform
                    icon.removeAllAnimations()
                    icon.position = position
                    icon.transform = transform
                }
                CATransaction.commit()
            }
            isMagnificationPaused = paused
            if !paused { updateLayers(animated: true) }
        }

        private func advanceEntryAnimation() {
            guard let entryStartedAt else { stopEntryAnimation(); return }
            let duration = isExitingMagnification
                ? FavoriteMagnificationTiming.exitDuration : FavoriteMagnificationTiming.entryDuration
            if CACurrentMediaTime() - entryStartedAt >= duration {
                stopEntryAnimation()
            }
            updateLayers(animated: false)
        }

        private func stopEntryAnimation() {
            entryTimer?.invalidate()
            entryTimer = nil
            entryStartedAt = nil
            entryStates = []
        }

        private func animateReorderPosition(_ target: CGPoint, on layer: CALayer) {
            guard layer.position != target else { return }
            let current = layer.presentation()?.position ?? layer.position
            layer.position = target
            let movement = CABasicAnimation(keyPath: "position")
            movement.fromValue = current
            movement.toValue = target
            movement.duration = 0.18
            movement.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(movement, forKey: "favorite-reorder-position")
        }

        private func updateLayers(animated: Bool, animateReorderIDs: Set<String> = []) {
            guard !isMagnificationPaused else { return }
            let layout = FavoriteMagnificationLayout(
                count: iconLayers.count,
                pointerX: pointerX,
                sizeScale: sizeScale,
                separatorIndices: Set(favoriteIDs.enumerated().compactMap { index, id in
                    id.hasPrefix("utility:separator") ? index : nil
                }),
                peakScale: peakScale
            )
            let entryProgress: CGFloat
            if let entryStartedAt {
                entryProgress = FavoriteMagnificationTiming.progress(
                    elapsed: CACurrentMediaTime() - entryStartedAt, exiting: isExitingMagnification)
            } else {
                entryProgress = 1
            }
            CATransaction.begin()
            CATransaction.setDisableActions(!animated)
            if animated {
                CATransaction.setAnimationDuration(0.14)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            }
            let hoveredIndex: Int? = pointerX.flatMap { x in
                guard showsHoverLabel, !favoriteNames.isEmpty else { return nil }
                if let draggedFavoriteID {
                    return favoriteIDs.firstIndex(of: draggedFavoriteID)
                }
                return FavoriteMagnificationLayout.hoveredItemIndex(
                    pointerX: x, count: favoriteNames.count, sizeScale: sizeScale,
                    separatorIndices: Set(favoriteIDs.enumerated().compactMap {
                        $0.element.hasPrefix("utility:separator") ? $0.offset : nil
                    }),
                    excludedIndices: Set(favoriteNames.enumerated().compactMap {
                        $0.element.isEmpty ? $0.offset : nil
                    })
                )
            }
            var hoveredIconTop: CGPoint?
            var visibleLeft = CGFloat.greatestFiniteMagnitude
            var visibleRight = -CGFloat.greatestFiniteMagnitude
            let slotTime = CACurrentMediaTime()
            for (index, icon) in iconLayers.enumerated() {
                let favoriteID = favoriteIDs[index]
                let isDragHidden = favoriteID == hiddenDraggedItemID
                icon.opacity = isDragHidden ? 0 : 1
                let isDragged = favoriteID == draggedFavoriteID && pointerX != nil
                let scale = isDragged ? peakScale : layout.scales[index]
                let isRunning = runningApplicationIDs.contains(favoriteID)
                let slotShift = currentSlotShift(at: index, time: slotTime)
                let slotDestination = index + (slotShift < 0 ? -1 : 1)
                let slotOffset = layout.reorderPreviewOffset(from: index,
                    to: slotDestination, sizeScale: sizeScale) * abs(slotShift)
                let geometry = layout.visualGeometry(
                    at: index,
                    sizeScale: sizeScale,
                    dragOffset: favoriteID == draggedFavoriteID
                        ? (dragOffsets.indices.contains(index) ? dragOffsets[index] : 0)
                        : slotOffset,
                    isNoWindow: true
                )
                let isSeparator = favoriteID.hasPrefix("utility:separator")
                let targetIconPosition = CGPoint(
                    x: geometry.centerX,
                    y: (isSeparator ? FavoriteShelfSeparator.bottomInset * sizeScale
                        : isDragged ? FavoriteMagnificationLayout.iconBottomInset * sizeScale
                            - FavoriteMagnificationLayout.lift(for: scale) * sizeScale
                        : geometry.iconBottomY) + visualLift
                )
                // The dragged icon already has a floating preview at its live
                // pointer position. Replaying its entry from the original slot
                // makes it visibly jump when the pointer returns to the shelf.
                let entry = favoriteID != draggedFavoriteID && entryStates.indices.contains(index)
                    ? entryStates[index] : nil
                let displayedScale = entry.map {
                    FavoriteMagnificationLayout.interpolate($0.iconScale, scale, progress: entryProgress)
                } ?? scale
                let displayedIconPosition = entry.map {
                    CGPoint(
                        x: $0.iconPosition.x + (targetIconPosition.x - $0.iconPosition.x) * entryProgress,
                        y: $0.iconPosition.y + (targetIconPosition.y - $0.iconPosition.y) * entryProgress
                    )
                } ?? targetIconPosition
                let animatePosition = animateReorderIDs.contains(favoriteID)
                    && (favoriteID != draggedFavoriteID || isSettlingDrag)
                if animatePosition {
                    animateReorderPosition(displayedIconPosition, on: icon)
                } else {
                    icon.position = displayedIconPosition
                }
                if isSeparator {
                    icon.transform = CATransform3DIdentity
                    icon.zPosition = 0
                    indicatorLayers[index].opacity = 0
                    badgeLayers[index].opacity = 0
                    continue
                }
                if !isDragHidden {
                    let halfWidth = FavoriteMagnificationLayout.iconSize * sizeScale * displayedScale / 2
                    visibleLeft = min(visibleLeft, displayedIconPosition.x - halfWidth)
                    visibleRight = max(visibleRight, displayedIconPosition.x + halfWidth)
                }
                icon.transform = CATransform3DMakeScale(displayedScale, displayedScale, 1)
                icon.zPosition = favoriteID == draggedFavoriteID ? 20 : displayedScale
                if index == hoveredIndex {
                    hoveredIconTop = CGPoint(
                        x: displayedIconPosition.x,
                        y: displayedIconPosition.y
                            + FavoriteMagnificationLayout.iconSize * sizeScale * displayedScale
                    )
                }

                let indicator = indicatorLayers[index]
                let targetIndicatorPosition = CGPoint(
                    x: geometry.centerX,
                    y: geometry.indicatorCenterY + visualLift
                )
                let indicatorScale = 1 + (scale - 1) * 0.5
                let displayedIndicatorPosition = entry.map {
                    CGPoint(
                        x: $0.indicatorPosition.x + (targetIndicatorPosition.x - $0.indicatorPosition.x) * entryProgress,
                        y: $0.indicatorPosition.y + (targetIndicatorPosition.y - $0.indicatorPosition.y) * entryProgress
                    )
                } ?? targetIndicatorPosition
                if animatePosition {
                    animateReorderPosition(displayedIndicatorPosition, on: indicator)
                } else {
                    indicator.position = displayedIndicatorPosition
                }
                let displayedIndicatorScale = entry.map {
                    $0.indicatorScale + (indicatorScale - $0.indicatorScale) * entryProgress
                } ?? indicatorScale
                indicator.transform = CATransform3DMakeScale(displayedIndicatorScale, displayedIndicatorScale, 1)
                indicator.opacity = isRunning && !isDragHidden ? 1 : 0

                let badge = badgeLayers[index]
                let badgePosition = CGPoint(
                    x: displayedIconPosition.x
                        + FavoriteMagnificationLayout.iconSize * sizeScale * displayedScale * 0.38,
                    y: displayedIconPosition.y
                        + FavoriteMagnificationLayout.iconSize * sizeScale * displayedScale * 0.90
                )
                if animatePosition {
                    animateReorderPosition(badgePosition, on: badge)
                } else {
                    badge.position = badgePosition
                }
                let badgeScale = FavoriteShelfBadgeMetrics.scale(for: displayedScale)
                badge.transform = CATransform3DMakeScale(badgeScale, badgeScale, 1)
                badge.opacity = badgeLabels[favoriteID] == nil || isDragHidden ? 0 : 1
            }
            updateHoverLabel(at: hoveredIconTop, index: hoveredIndex)
            CATransaction.commit()
            reportMagnificationBounds(left: visibleLeft, right: visibleRight)
        }

        private func reportMagnificationBounds(left: CGFloat, right: CGFloat) {
            let contentWidth = CGFloat(favoriteIDs.count) * FavoriteMagnificationLayout.itemStep * sizeScale
                - CGFloat(favoriteIDs.filter { $0.hasPrefix("utility:separator") }.count) * 28 * sizeScale
            let leading = left.isFinite ? max(0, 2 * sizeScale - left) : 0
            let trailing = right.isFinite ? max(0, right - (contentWidth - (FavoriteMagnificationLayout.itemStep - 28) * sizeScale)) : 0
            if let previous = lastReportedBounds,
               abs(previous.0 - leading) < 0.01, abs(previous.1 - trailing) < 0.01 { return }
            lastReportedBounds = (leading, trailing)
            // These are the same interpolated icon frames rendered above. The
            // bar follows them directly, without starting a second animation.
            DispatchQueue.main.async { [weak self] in
                self?.onMagnificationBoundsChange?(leading, trailing)
            }
        }

        private func updateHoverLabel(at iconTop: CGPoint?, index: Int?) {
            hoverLabelLayer.opacity = 0
            guard !isMagnificationPaused, hiddenDraggedItemID == nil, let iconTop, let index else {
                hoverLabelLayer.opacity = 0
                hoverBubble?.isHidden = true
                return
            }
            let title = favoriteNames[index]
            let fontSize = SmallBubbleMetrics.fontSize
            let viewOriginX = convert(.zero, to: window?.contentView).x
            let contentWidth = window?.contentView?.bounds.width ?? bounds.width
            if displayedHoverLabel != title || hoverLabelTextLayer.fontSize != fontSize
                || hoverLabelSizeScale != sizeScale {
                displayedHoverLabel = title
                hoverLabelSizeScale = sizeScale
                let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
                hoverLabelWidth = SmallBubbleMetrics.width(for: title, sizeScale: sizeScale)
                hoverLabelTextLayer.font = font
                hoverLabelTextLayer.fontSize = fontSize
                hoverLabelTextLayer.string = title
                let totalHeight = FavoriteMagnificationLayout.hoverLabelHeight * sizeScale
                hoverLabelLayer.bounds = CGRect(x: 0, y: 0, width: hoverLabelWidth, height: totalHeight)
                hoverLabelLayer.path = Self.hoverLabelPath(
                    width: hoverLabelWidth, height: totalHeight, scale: sizeScale)
                hoverLabelTextLayer.frame = CGRect(
                    x: 9 * sizeScale, y: 10 * sizeScale,
                    width: hoverLabelWidth - 18 * sizeScale, height: 17 * sizeScale)
            }
            let placement = SmallBubbleMetrics.placement(width: hoverLabelWidth, iconCenter: iconTop.x,
                horizontalBounds: (8 - viewOriginX)...(max(8, contentWidth - 8) - viewOriginX))
            let left = placement.left
            let arrow = placement.arrow
            if hoverBubble == nil {
                let hint = FloatingBubbleHintView(title: title, width: hoverLabelWidth, fontSize: fontSize, arrowX: arrow)
                addSubview(hint)
                hoverBubble = hint
            }
            hoverBubble?.update(title: title, width: hoverLabelWidth, fontSize: fontSize, arrowX: arrow)
            hoverBubble?.frame = CGRect(x: left, y: iconTop.y + SmallBubbleMetrics.iconGap,
                                       width: hoverLabelWidth, height: SmallBubbleMetrics.height)
            hoverBubble?.isHidden = false
        }

        private static func hoverLabelPath(width: CGFloat, height: CGFloat, scale: CGFloat) -> CGPath {
            let tailHeight = 6 * scale
            let radius = 12 * scale
            let center = width / 2
            let path = CGMutablePath()
            path.move(to: CGPoint(x: radius, y: tailHeight))
            path.addLine(to: CGPoint(x: center - 6 * scale, y: tailHeight))
            path.addLine(to: CGPoint(x: center, y: 0))
            path.addLine(to: CGPoint(x: center + 6 * scale, y: tailHeight))
            path.addLine(to: CGPoint(x: width - radius, y: tailHeight))
            path.addQuadCurve(to: CGPoint(x: width, y: tailHeight + radius),
                              control: CGPoint(x: width, y: tailHeight))
            path.addLine(to: CGPoint(x: width, y: height - radius))
            path.addQuadCurve(to: CGPoint(x: width - radius, y: height),
                              control: CGPoint(x: width, y: height))
            path.addLine(to: CGPoint(x: radius, y: height))
            path.addQuadCurve(to: CGPoint(x: 0, y: height - radius),
                              control: CGPoint(x: 0, y: height))
            path.addLine(to: CGPoint(x: 0, y: tailHeight + radius))
            path.addQuadCurve(to: CGPoint(x: radius, y: tailHeight),
                              control: CGPoint(x: 0, y: tailHeight))
            path.closeSubpath()
            return path
        }
    }
}

private struct FavoriteShortcutBadge: View {
    let label: String
    let sizeScale: CGFloat

    var body: some View {
        Text(label)
            .font(.system(size: 10 * sizeScale, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 14 * sizeScale, height: 14 * sizeScale)
            .background(Color.accentColor, in: Circle())
            .offset(x: 3, y: -3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct FavoriteShelfButton: View {
    let item: FavoriteShelfItem
    let isRunning: Bool
    let badgeLabel: String?
    let shortcutLabel: String?
    let isMovable: Bool
    let isTransient: Bool
    let sizeScale: CGFloat
    let onOpen: () -> Void

    var body: some View {
        button
    }

    private var button: some View {
        Button(action: onOpen) {
            Color.clear
                .frame(width: 30 * sizeScale, height: 30 * sizeScale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 30 * sizeScale, height: 30 * sizeScale)
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            if let shortcutLabel {
                FavoriteShortcutBadge(label: shortcutLabel, sizeScale: sizeScale)
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(isMovable
            ? "点击打开；长按或右键显示菜单；拖动可调整收藏顺序，拖出停留 0.5 秒后松手移除收藏"
            : isTransient
                ? "点击打开；长按或右键可固定到 Dock"
                : "点击打开；长按或右键显示菜单")
    }

    private var accessibilityLabel: String {
        switch item {
        case .app(let app): return "\(isTransient ? "Dock 临时" : "收藏")：\(app.applicationName)"
        case .separator: return "分隔线"
        case .trash(let isFull): return isFull ? "打开废纸篓，非空" : "打开废纸篓，空"
        case .applications: return "应用程序；点击展开列表"
        case .folder(let folder): return "打开收藏文件夹：\(folder.name)"
        case .insertionGap: return ""
        }
    }

    private var accessibilityValue: String {
        guard item.app != nil else { return "" }
        return [isRunning ? "正在运行" : "未运行", badgeLabel.map { "\($0) 条未读" }]
            .compactMap { $0 }.joined(separator: "，")
    }
}

private enum DownloadFileIcon {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for pathOrFilename: String) -> NSImage {
        let key = pathOrFilename as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: pathOrFilename)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

private enum FavoriteFolderIcon {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for folder: FavoriteFolder) -> NSImage {
        let key = folder.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: folder.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

private struct FavoriteApplicationIcon: View {
    let favorite: FavoriteApp
    var size: CGFloat = 26
    private static let iconCache = NSCache<NSString, NSImage>()

    var body: some View {
        Image(nsImage: Self.image(for: favorite, date: Date()))
            .resizable()
            .renderingMode(.original)
            .interpolation(.high)
            .frame(width: size, height: size)
    }

    fileprivate static func image(for favorite: FavoriteApp, date: Date) -> NSImage {
        let calendarKey = CalendarLiveIcon.isCalendar(favorite)
            ? CalendarLiveIcon.dayKey(for: date) : ""
        let cacheKey = "\(favorite.id)|\(favorite.bundlePath ?? "")|\(calendarKey)" as NSString
        if let cached = Self.iconCache.object(forKey: cacheKey) { return cached }
        if CalendarLiveIcon.isCalendar(favorite) {
            let icon = CalendarLiveIcon.image(for: date)
            Self.iconCache.setObject(icon, forKey: cacheKey)
            return icon
        }
        let workspace = NSWorkspace.shared
        let icon: NSImage
        if let bundleIdentifier = favorite.bundleIdentifier,
           let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            icon = workspace.icon(forFile: url.path)
        } else if let bundlePath = favorite.bundlePath {
            icon = workspace.icon(forFile: bundlePath)
        } else {
            icon = NSImage(named: NSImage.applicationIconName)
                ?? NSImage(size: NSSize(width: 24, height: 24))
        }
        Self.iconCache.setObject(icon, forKey: cacheKey)
        return icon
    }
}
