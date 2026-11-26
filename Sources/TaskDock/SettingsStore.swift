import AppKit
import SwiftUI
import TaskDockPreferences

enum TaskItemHighlightStyle: String, CaseIterable, Identifiable {
    case systemAccent
    case white

    var id: String { rawValue }
    var label: String { self == .systemAccent ? "系统强调色" : "白色" }
}

enum TaskDockLayoutMode: String, CaseIterable, Identifiable {
    case taskbar
    case minimal
    case dockCompanion

    var isTaskbar: Bool { self != .dockCompanion }
    var id: String { rawValue }
    var label: String {
        switch self {
        case .minimal: return "极简模式"
        case .taskbar: return "任务栏"
        case .dockCompanion: return "Dock 融合"
        }
    }
    var systemImage: String {
        switch self {
        case .minimal: return "rectangle.compress.vertical"
        case .taskbar: return "rectangle.bottomthird.inset.filled"
        case .dockCompanion: return "dock.rectangle"
        }
    }
}

enum DockCompanionAppSide: Equatable {
    case left
    case right
    case hidden
}

enum TaskbarToggleModifier: String, CaseIterable, Identifiable {
    case option
    case command
    case control

    var id: String { rawValue }
    var label: String {
        switch self {
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let defaultTaskbarHeight: CGFloat = 50
    // Geometry was designed around 38 pt; changing the user's default must not resize icons.
    static let layoutReferenceTaskbarHeight: CGFloat = 38
    static let defaultTaskbarSideInset: CGFloat = 88
    static let taskbarSideInsetRange: ClosedRange<CGFloat> = 35...500
    static let taskbarHeightRange: ClosedRange<CGFloat> = 34...64
    static let defaultTaskbarItemFontSize: CGFloat = 8
    static let taskbarItemFontSizes: [CGFloat] = [8, 9, 10, 11, 12]
    static let recentAppHistoryLimit = 50
    @Published var blacklistedAppKeys: Set<String> { didSet { save() } }
    @Published private(set) var blockedWindowRules: [BlockedWindowRule] { didSet { save() } }
    @Published private(set) var transparencyByMode: [TaskDockLayoutMode: Double] { didSet { save() } }
    @Published private(set) var hiddenAppsByMode: [TaskDockLayoutMode: Bool] { didSet { save() } }
    @Published private(set) var finderTabsByMode: [TaskDockLayoutMode: Bool] { didSet { save() } }
    @Published var taskItemHighlightStyle: TaskItemHighlightStyle { didSet { save() } }
    @Published var layoutMode: TaskDockLayoutMode { didSet { save() } }
    var showHiddenApps: Bool { showsHiddenApps(in: layoutMode) }
    var finderTabsAsWindows: Bool { showsFinderTabsAsWindows(in: layoutMode) }
    var nonSelectedItemTransparency: Double { transparency(in: layoutMode) }
    @Published var activeTaskbarShortcutIndices: Set<Int> = []
    @Published var activeFavoriteShortcutIndices: Set<Int> = []
    @Published var dockCompanionHeight: CGFloat = 39
    @Published var taskbarHeight: CGFloat {
        didSet { defaults.set(Double(taskbarHeight), forKey: taskbarHeightKey) }
    }
    @Published var taskbarSideInset: CGFloat {
        didSet { defaults.set(Double(taskbarSideInset), forKey: taskbarSideInsetKey) }
    }
    @Published var taskbarBackgroundTransparency: Double {
        didSet { defaults.set(taskbarBackgroundTransparency, forKey: taskbarBackgroundTransparencyKey) }
    }
    @Published var taskbarItemWidthMode: TaskbarItemWidthMode { didSet { save() } }
    @Published var taskbarItemMaximumWidth: CGFloat { didSet { save() } }
    @Published var taskbarItemFontSize: CGFloat { didSet { save() } }
    @Published var favoriteMagnificationEnabled: Bool { didSet { save() } }
    @Published var favoriteMagnificationScale: CGFloat {
        didSet { favoriteMagnificationEnabled = favoriteMagnificationScale > 1.001; save() }
    }
    @Published var taskbarCollapseSameAppWindows: Bool { didSet { save() } }
    @Published private(set) var dockCompanionLeftAppKeys: Set<String> { didSet { save() } }
    @Published private(set) var dockCompanionRightAppKeys: Set<String> { didSet { save() } }
    @Published private(set) var dockCompanionRightAppsCustomized: Bool { didSet { save() } }
    @Published private(set) var dockCompanionAddedApps: [FavoriteApp] { didSet { save() } }
    @Published var dockCompanionMinimumWindowCount: Int { didSet { save() } }
    @Published var dockCompanionCollapseThreshold: Int { didSet { save() } }
    @Published var dockCompanionShowsRecentWindows: Bool { didSet { save() } }
    @Published var dockCompanionShowsBottomBar: Bool { didSet { save() } }
    @Published var dockCompanionOverlayEnabled: Bool { didSet { save() } }
    @Published var toggleModifier: TaskbarToggleModifier { didSet { save() } }
    @Published private(set) var appOrder: [String] { didSet { save() } }
    @Published private(set) var minimalAppOrder: [String] {
        didSet { defaults.set(minimalAppOrder, forKey: minimalAppOrderKey) }
    }
    @Published private(set) var favoriteApps: [FavoriteApp] { didSet { save(); favoritesDidChange() } }
    @Published private(set) var recentApps: [FavoriteApp] { didSet { save() } }
    @Published private(set) var singleIconAppIDs: Set<String> {
        didSet { defaults.set(singleIconAppIDs.sorted(), forKey: singleIconAppIDsKey) }
    }
    @Published private(set) var appGroupPins: [FavoriteApp] {
        didSet { defaults.set(try? JSONEncoder().encode(appGroupPins), forKey: appGroupPinsKey) }
    }
    @Published private(set) var favoriteFolders: [FavoriteFolder] { didSet { save(); favoritesDidChange() } }
    @Published private(set) var dockFavoritesSyncEnabled: Bool
    @Published private(set) var dockTransientApps: [FavoriteApp] = []
    @Published var dockFavoritesSyncError: String?
    var onFavoritesChanged: (() -> Void)?
    private var importingDockFavorites = false
    private var recentAppOpenTimes: [String: Double] = [:]
    @Published private var recentAppCloseTimes: [String: Double] = [:]
    private let recentAppCloseTimesKey = "taskdock.recentAppCloseTimes"
    var recentAppsByClosingTime: [FavoriteApp] {
        recentApps.enumerated().sorted { left, right in
            let leftTime = recentAppCloseTimes[left.element.id] ?? 0
            let rightTime = recentAppCloseTimes[right.element.id] ?? 0
            return leftTime == rightTime ? left.offset < right.offset : leftTime > rightTime
        }.map(\.element)
    }
    private var taskbarArrivalOrder = TaskbarArrivalOrder()
    private var taskbarWindowOrderIDs: [String] = []

    private let defaults = UserDefaults.standard
    private let blacklistKey = "taskdock.blacklistedAppKeys"
    private let blockedWindowRulesKey = "taskdock.blockedWindowRules"
    private let blacklistResetKey = "taskdock.blacklistResetForTopSettingsV1"
    private let taskItemHighlightStyleKey = "taskdock.taskItemHighlightStyle"
    private let layoutModeKey = "taskdock.layoutMode"
    // Keep the existing preference key so prior slider adjustments are preserved.
    private let taskbarSideInsetKey = "taskdock.taskbarLeadingInset"
    private let taskbarHeightKey = "taskdock.taskbarHeight"
    private let taskbarBackgroundTransparencyKey = "taskdock.taskbarBackgroundTransparency"
    private let taskbarItemWidthModeKey = "taskdock.taskbarItemWidthMode"
    private let taskbarItemMaximumWidthKey = "taskdock.taskbarItemMaximumWidth"
    private let taskbarItemFontSizeKey = "taskdock.taskbarItemFontSize"
    private let favoriteMagnificationEnabledKey = "taskdock.favoriteMagnificationEnabled"
    private let favoriteMagnificationScaleKey = "taskdock.favoriteMagnificationScale"
    private let taskbarCollapseSameAppWindowsKey = "taskdock.taskbarCollapseSameAppWindows"
    private let dockCompanionLeftAppKeysKey = "taskdock.dockCompanionLeftAppKeys"
    private let dockCompanionRightAppKeysKey = "taskdock.dockCompanionRightAppKeys"
    private let dockCompanionRightAppsCustomizedKey = "taskdock.dockCompanionRightAppsCustomized"
    private let dockCompanionAddedAppsKey = "taskdock.dockCompanionAddedApps"
    private let dockCompanionMinimumWindowCountKey = "taskdock.dockCompanionMinimumWindowCount"
    private let dockCompanionCollapseThresholdKey = "taskdock.dockCompanionCollapseThreshold"
    private let dockCompanionShowsRecentWindowsKey = "taskdock.dockCompanionShowsRecentWindows"
    private let dockCompanionShowsBottomBarKey = "taskdock.dockCompanionShowsBottomBar"
    private let dockCompanionOverlayEnabledKey = "taskdock.dockCompanionOverlayEnabled"
    private let toggleModifierKey = "taskdock.toggleModifier"
    private let appOrderKey = "taskdock.appOrder"
    private let minimalAppOrderKey = "taskdock.minimalAppOrder"
    private let favoriteAppsKey = "taskdock.favoriteApps"
    private let recentAppsKey = "taskdock.recentApps"
    private let recentAppOpenTimesKey = "taskdock.recentAppOpenTimes"
    private let appGroupPinsKey = "taskdock.appGroupPins"
    private let singleIconAppIDsKey = "taskdock.singleIconAppIDs"
    private let favoriteFoldersKey = "taskdock.favoriteFolders"
    private let dockFavoritesSyncKey = "taskdock.dockFavoritesSyncEnabled"
    private let independentFavoriteAppsKey = "taskdock.independentFavoriteApps"
    private let independentFavoriteFoldersKey = "taskdock.independentFavoriteFolders"

    init() {
        if !defaults.bool(forKey: blacklistResetKey) {
            defaults.removeObject(forKey: blacklistKey)
            defaults.removeObject(forKey: blockedWindowRulesKey)
            defaults.set(true, forKey: blacklistResetKey)
        }
        blacklistedAppKeys = Set(defaults.stringArray(forKey: blacklistKey) ?? [])
        if let data = defaults.data(forKey: blockedWindowRulesKey),
           let decoded = try? JSONDecoder().decode([BlockedWindowRule].self, from: data) {
            var seenRuleIDs = Set<String>()
            blockedWindowRules = decoded.filter { seenRuleIDs.insert($0.id).inserted }
        } else {
            blockedWindowRules = []
        }
        let storedDefaults = UserDefaults.standard
        let loadedPreferences = Dictionary(uniqueKeysWithValues: TaskDockLayoutMode.allCases.map { mode in
            (mode, ModePreferenceStorage.load(mode: mode.rawValue, defaults: storedDefaults))
        })
        transparencyByMode = Dictionary(uniqueKeysWithValues: TaskDockLayoutMode.allCases.map { mode in
            (mode, mode == .taskbar ? 0 : loadedPreferences[mode]!.transparency)
        })
        hiddenAppsByMode = Dictionary(uniqueKeysWithValues: TaskDockLayoutMode.allCases.map { mode in
            (mode, loadedPreferences[mode]!.showHiddenApps)
        })
        finderTabsByMode = Dictionary(uniqueKeysWithValues: TaskDockLayoutMode.allCases.map { mode in
            (mode, loadedPreferences[mode]!.finderTabsAsWindows)
        })
        taskItemHighlightStyle = TaskItemHighlightStyle(
            rawValue: defaults.string(forKey: taskItemHighlightStyleKey) ?? "white"
        ) ?? .white
        let storedLayoutMode = defaults.string(forKey: layoutModeKey)
        let resolvedLayoutMode = TaskDockLayoutMode(rawValue: storedLayoutMode ?? "taskbar") ?? .taskbar
        layoutMode = resolvedLayoutMode
        if storedLayoutMode != resolvedLayoutMode.rawValue {
            defaults.set(resolvedLayoutMode.rawValue, forKey: layoutModeKey)
        }
        let savedTaskbarHeight = defaults.object(forKey: taskbarHeightKey) as? Double ?? Double(Self.defaultTaskbarHeight)
        taskbarHeight = min(max(CGFloat(savedTaskbarHeight), Self.taskbarHeightRange.lowerBound), Self.taskbarHeightRange.upperBound)
        let savedLeadingInset = defaults.object(forKey: taskbarSideInsetKey) as? Double ?? Double(Self.defaultTaskbarSideInset)
        taskbarSideInset = savedLeadingInset.isFinite
            ? min(max(CGFloat(savedLeadingInset), Self.taskbarSideInsetRange.lowerBound), Self.taskbarSideInsetRange.upperBound)
            : Self.defaultTaskbarSideInset
        let savedBackgroundTransparency = defaults.object(forKey: taskbarBackgroundTransparencyKey) as? Double ?? 0
        taskbarBackgroundTransparency = savedBackgroundTransparency.isFinite
            ? min(max(savedBackgroundTransparency, 0), 1) : 0
        taskbarItemWidthMode = TaskbarItemWidthMode(rawValue: defaults.string(forKey: taskbarItemWidthModeKey) ?? "adaptive") ?? .adaptive
        let widthRange = TaskbarItemSizing.maximumWidthRange
        let storedWidth = defaults.object(forKey: taskbarItemMaximumWidthKey) as? Double
        let maximumWidth = storedWidth.flatMap { $0.isFinite ? CGFloat($0) : nil } ?? TaskbarItemSizing.defaultFixedWidth
        taskbarItemMaximumWidth = min(widthRange.upperBound, max(widthRange.lowerBound, maximumWidth))
        let savedFontSize = defaults.object(forKey: taskbarItemFontSizeKey) as? Double ?? Double(Self.defaultTaskbarItemFontSize)
        taskbarItemFontSize = Self.taskbarItemFontSizes.min {
            abs($0 - CGFloat(savedFontSize)) < abs($1 - CGFloat(savedFontSize))
        } ?? Self.defaultTaskbarItemFontSize
        favoriteMagnificationEnabled = defaults.object(forKey: favoriteMagnificationEnabledKey) as? Bool ?? true
        let savedMagnificationScale = defaults.object(forKey: favoriteMagnificationScaleKey) as? Double ?? 2.0
        favoriteMagnificationScale = savedMagnificationScale.isFinite
            ? min(max(CGFloat(savedMagnificationScale), 1.0), 2.4) : 2.0
        taskbarCollapseSameAppWindows = defaults.bool(forKey: taskbarCollapseSameAppWindowsKey)
        dockCompanionLeftAppKeys = Set(defaults.stringArray(forKey: dockCompanionLeftAppKeysKey) ?? ["com.apple.finder"])
        dockCompanionRightAppKeys = Set(defaults.stringArray(forKey: dockCompanionRightAppKeysKey) ?? [])
        dockCompanionRightAppsCustomized = defaults.bool(forKey: dockCompanionRightAppsCustomizedKey)
        if let data = defaults.data(forKey: dockCompanionAddedAppsKey),
           let decoded = try? JSONDecoder().decode([FavoriteApp].self, from: data) {
            var seenIDs = Set<String>()
            dockCompanionAddedApps = decoded.filter { seenIDs.insert($0.id).inserted }
        } else {
            dockCompanionAddedApps = []
        }
        let savedMinimumWindowCount = defaults.object(forKey: dockCompanionMinimumWindowCountKey) as? Int ?? 2
        dockCompanionMinimumWindowCount = min(max(savedMinimumWindowCount, 1), 20)
        let savedCollapseThreshold = defaults.object(forKey: dockCompanionCollapseThresholdKey) as? Int ?? 3
        dockCompanionCollapseThreshold = min(max(savedCollapseThreshold, 2), 20)
        dockCompanionShowsRecentWindows = defaults.object(forKey: dockCompanionShowsRecentWindowsKey) as? Bool ?? true
        dockCompanionShowsBottomBar = defaults.object(forKey: dockCompanionShowsBottomBarKey) as? Bool ?? true
        dockCompanionOverlayEnabled = defaults.object(forKey: dockCompanionOverlayEnabledKey) as? Bool ?? false
        toggleModifier = TaskbarToggleModifier(rawValue: defaults.string(forKey: toggleModifierKey) ?? "option") ?? .option
        var seenAppKeys = Set<String>()
        appOrder = (defaults.stringArray(forKey: appOrderKey) ?? []).filter {
            seenAppKeys.insert($0).inserted
        }
        minimalAppOrder = MinimalAppOrder.reconcile(saved: defaults.stringArray(forKey: minimalAppOrderKey) ?? [],
            candidates: [])
        if let data = defaults.data(forKey: favoriteAppsKey),
           let decoded = try? JSONDecoder().decode([FavoriteApp].self, from: data) {
            var seenFavoriteIDs = Set<String>()
            favoriteApps = decoded.filter { seenFavoriteIDs.insert($0.id).inserted }
        } else {
            favoriteApps = []
        }
        if let data = defaults.data(forKey: recentAppsKey),
           let decoded = try? JSONDecoder().decode([FavoriteApp].self, from: data) {
            var seenIDs = Set<String>()
            recentApps = Array(decoded.filter { seenIDs.insert($0.id).inserted }.prefix(Self.recentAppHistoryLimit))
        } else {
            recentApps = []
        }
        singleIconAppIDs = Set(defaults.stringArray(forKey: singleIconAppIDsKey) ?? [])
        recentAppOpenTimes = defaults.dictionary(forKey: recentAppOpenTimesKey) as? [String: Double] ?? [:]
        recentAppCloseTimes = defaults.dictionary(forKey: recentAppCloseTimesKey) as? [String: Double] ?? [:]
        let savedPins = defaults.data(forKey: appGroupPinsKey)
            .flatMap { try? JSONDecoder().decode([FavoriteApp].self, from: $0) } ?? []
        var seenPinIDs = Set<String>()
        appGroupPins = savedPins.filter { seenPinIDs.insert($0.id).inserted }
        if let data = defaults.data(forKey: favoriteFoldersKey),
           let decoded = try? JSONDecoder().decode([FavoriteFolder].self, from: data) {
            var seenPaths = Set<String>()
            favoriteFolders = decoded.filter { seenPaths.insert($0.path).inserted }
        } else {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Downloads", isDirectory: true)
            favoriteFolders = [FavoriteFolder(path: downloads.standardizedFileURL.path)]
        }
        dockFavoritesSyncEnabled = defaults.bool(forKey: dockFavoritesSyncKey)
        dockFavoritesSyncError = nil
        defaults.set(appOrder, forKey: appOrderKey)
    }

    func toggleBlacklist(for appKey: String) {
        if blacklistedAppKeys.contains(appKey) {
            blacklistedAppKeys.remove(appKey)
        } else {
            blacklistedAppKeys.insert(appKey)
        }
    }

    func blockWindowType(for window: WindowModel) {
        let rule = BlockedWindowRule(window: window)
        guard !blockedWindowRules.contains(where: { $0.id == rule.id }) else { return }
        blockedWindowRules.append(rule)
    }

    func removeBlockedWindowRule(_ rule: BlockedWindowRule) {
        blockedWindowRules.removeAll { $0.id == rule.id }
    }

    func reconcileAppOrder(with appKeys: [String]) {
        var knownKeys = Set(appOrder)
        let newKeys = appKeys.filter { knownKeys.insert($0).inserted }
        guard !newKeys.isEmpty else { return }
        appOrder.append(contentsOf: newKeys)
    }

    func reconcileTaskbarOrder(with windows: [WindowModel]) {
        let order = taskbarArrivalOrder.reconcile(
            windows.map { .init(id: $0.id, appKey: $0.appKey) },
            appOrder: appOrder
        )
        if order.apps != appOrder { appOrder = order.apps }
        taskbarWindowOrderIDs = order.windows
    }

    func applyVisibleAppOrder(_ visibleKeys: [String]) {
        let visibleSet = Set(visibleKeys)
        var reordered = visibleKeys.makeIterator()
        let nextOrder = appOrder.map { key in
            visibleSet.contains(key) ? (reordered.next() ?? key) : key
        }
        guard nextOrder != appOrder else { return }
        appOrder = nextOrder
    }

    func taskbarWindowWidth(title: String, scale: CGFloat) -> CGFloat {
        if taskbarItemWidthMode == .fixed { return taskbarItemMaximumWidth * scale }
        return TaskbarItemSizing.adaptiveWidth(title: title, fontSize: taskbarItemFontSize, scale: scale,
            maximumWidth: taskbarItemMaximumWidth)
    }

    func orderedMinimalAppKeys(with runningKeys: [String]) -> [String] {
        MinimalAppOrder.visible(saved: minimalAppOrder,
            candidates: displayedFavoriteApps.map(\.id) + runningKeys)
    }

    func reconcileMinimalAppOrder(with runningKeys: [String]) {
        let next = MinimalAppOrder.reconcile(saved: minimalAppOrder,
            candidates: displayedFavoriteApps.map(\.id) + runningKeys)
        if next != minimalAppOrder { minimalAppOrder = next }
    }

    func applyMinimalVisibleAppOrder(_ keys: [String]) {
        let next = MinimalAppOrder.replacingVisible(saved: minimalAppOrder, with: keys)
        if next != minimalAppOrder { minimalAppOrder = next }
    }

    func isFavorite(_ appKey: String) -> Bool {
        favoriteApps.contains { $0.id == appKey }
    }

    func setDockFavoritesSyncEnabled(_ enabled: Bool) {
        guard enabled != dockFavoritesSyncEnabled else { return }
        dockFavoritesSyncError = nil
        if enabled {
            defaults.set(try? JSONEncoder().encode(favoriteApps), forKey: independentFavoriteAppsKey)
            defaults.set(try? JSONEncoder().encode(favoriteFolders), forKey: independentFavoriteFoldersKey)
        }
        dockFavoritesSyncEnabled = enabled
        if !enabled { dockTransientApps = [] }
        defaults.set(enabled, forKey: dockFavoritesSyncKey)
        if !enabled {
            importingDockFavorites = true
            if let data = defaults.data(forKey: independentFavoriteAppsKey),
               let apps = try? JSONDecoder().decode([FavoriteApp].self, from: data) { favoriteApps = apps }
            if let data = defaults.data(forKey: independentFavoriteFoldersKey),
               let folders = try? JSONDecoder().decode([FavoriteFolder].self, from: data) { favoriteFolders = folders }
            importingDockFavorites = false
        }
    }

    func replaceFavoritesFromDock(apps: [FavoriteApp], folders: [FavoriteFolder]) {
        importingDockFavorites = true
        if favoriteApps != apps { favoriteApps = apps }
        if favoriteFolders != folders { favoriteFolders = folders }
        importingDockFavorites = false
    }

    func replaceDockTransientApps(_ apps: [FavoriteApp]) {
        if dockTransientApps != apps { dockTransientApps = apps }
    }

    var displayedFavoriteApps: [FavoriteApp] {
        guard dockFavoritesSyncEnabled else { return favoriteApps }
        let pinned = Set(favoriteApps.map(\.id))
        return favoriteApps + dockTransientApps.filter { !pinned.contains($0.id) }
    }

    private func favoritesDidChange() {
        if !importingDockFavorites && dockFavoritesSyncEnabled { onFavoritesChanged?() }
    }

    func toggleFavorite(for window: WindowModel) {
        guard !window.isTrashWindow else { return }
        if let index = favoriteApps.firstIndex(where: { $0.id == window.appKey }) {
            favoriteApps.remove(at: index)
            return
        }

        let runningApp = NSRunningApplication(processIdentifier: window.pid)
        favoriteApps.append(FavoriteApp(
            id: window.appKey,
            bundleIdentifier: window.bundleIdentifier,
            applicationName: window.applicationName,
            bundlePath: runningApp?.bundleURL?.path
        ))
    }

    @discardableResult
    func addFavorite(applicationURL: URL, at insertionIndex: Int? = nil) -> Bool {
        let url = applicationURL.standardizedFileURL
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url),
              let info = bundle.infoDictionary, !info.isEmpty else { return false }

        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let bundleIdentifier = bundle.bundleIdentifier
        let appKey = bundleIdentifier ?? "name:\(name)"
        guard !favoriteApps.contains(where: { $0.id == appKey }) else { return false }

        let favorite = FavoriteApp(
            id: appKey,
            bundleIdentifier: bundleIdentifier,
            applicationName: name,
            bundlePath: url.path
        )
        favoriteApps.insert(favorite, at: min(favoriteApps.count, max(0, insertionIndex ?? favoriteApps.count)))
        return true
    }

    @discardableResult
    func addFavorite(_ app: FavoriteApp) -> Bool {
        guard !isFavorite(app.id) else { return false }
        favoriteApps.append(app)
        return true
    }

    func removeFavorite(_ favorite: FavoriteApp) {
        favoriteApps.removeAll { $0.id == favorite.id }
    }

    func recordRecentApp(_ app: FavoriteApp, openedAt: Date = Date()) {
        let timestamp = openedAt.timeIntervalSince1970
        if let prior = recentAppOpenTimes[app.id], prior > timestamp { return }
        recentAppOpenTimes[app.id] = timestamp
        var updated = recentApps.filter { $0.id != app.id }
        let insertion = updated.firstIndex { entry in
            (recentAppOpenTimes[entry.id] ?? 0) <= timestamp
        } ?? updated.endIndex
        updated.insert(app, at: insertion)
        let limited = Array(updated.prefix(Self.recentAppHistoryLimit))
        let history = Set(limited.map(\.id))
        recentAppOpenTimes = recentAppOpenTimes.filter { history.contains($0.key) }
        defaults.set(recentAppOpenTimes, forKey: recentAppOpenTimesKey)
        let closeTimes = recentAppCloseTimes.filter { history.contains($0.key) }
        if closeTimes != recentAppCloseTimes {
            recentAppCloseTimes = closeTimes
            defaults.set(closeTimes, forKey: recentAppCloseTimesKey)
        }
        if limited != recentApps { recentApps = limited }
    }

    func recordRecentAppClosure(_ app: FavoriteApp, at date: Date = Date()) {
        if !recentApps.contains(where: { $0.id == app.id }) { recordRecentApp(app, openedAt: date) }
        recentAppCloseTimes[app.id] = date.timeIntervalSince1970
        defaults.set(recentAppCloseTimes, forKey: recentAppCloseTimesKey)
    }

    func moveAppGroupPin(_ id: String, to targetID: String) {
        guard id != targetID,
              let source = appGroupPins.firstIndex(where: { $0.id == id }),
              let destination = appGroupPins.firstIndex(where: { $0.id == targetID }) else { return }
        var pins = appGroupPins
        let app = pins.remove(at: source)
        pins.insert(app, at: destination)
        appGroupPins = pins
    }

    func removesOverlapOnOptionHold(in mode: TaskDockLayoutMode) -> Bool {
        guard mode.isTaskbar else { return false }
        let key = mode == .minimal ? Self.minimalOptionAvoidanceKey : Self.taskbarOptionAvoidanceKey
        return defaults.object(forKey: key) as? Bool ?? true
    }

    static let minimalOptionAvoidanceKey = "taskdock.minimalOptionAvoidanceEnabled"
    static let taskbarOptionAvoidanceKey = "taskdock.taskbarOptionAvoidanceEnabled"
    static let layoutSwitchShortcutEnabledKey = "taskdock.layoutSwitchShortcutEnabled"

    func removeRecentApp(id: String) {
        guard recentApps.contains(where: { $0.id == id }) else { return }
        recentAppCloseTimes.removeValue(forKey: id)
        defaults.set(recentAppCloseTimes, forKey: recentAppCloseTimesKey)
        recentAppOpenTimes.removeValue(forKey: id)
        defaults.set(recentAppOpenTimes, forKey: recentAppOpenTimesKey)
        recentApps.removeAll { $0.id == id }
    }

    func toggleSingleIcon(for appID: String) {
        if !singleIconAppIDs.insert(appID).inserted { singleIconAppIDs.remove(appID) }
    }

    func toggleAppGroupPin(_ app: FavoriteApp) {
        if let index = appGroupPins.firstIndex(where: { $0.id == app.id }) {
            appGroupPins.remove(at: index)
        } else {
            appGroupPins.insert(app, at: 0)
        }
    }

    @discardableResult
    func addFavoriteFolder(_ url: URL, at insertionIndex: Int? = nil) -> Bool {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard standardized.isFileURL,
              FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !favoriteFolders.contains(where: { $0.path == standardized.path }) else { return false }
        favoriteFolders.insert(FavoriteFolder(path: standardized.path),
            at: min(favoriteFolders.count, max(0, insertionIndex ?? favoriteFolders.count)))
        return true
    }

    func removeFavoriteFolder(_ folder: FavoriteFolder) {
        favoriteFolders.removeAll { $0.id == folder.id }
    }

    func reorderFavoriteFolders(_ orderedIDs: [String]) {
        guard orderedIDs.count == favoriteFolders.count,
              Set(orderedIDs) == Set(favoriteFolders.map(\.id)) else { return }
        let foldersByID = Dictionary(uniqueKeysWithValues: favoriteFolders.map { ($0.id, $0) })
        let reordered = orderedIDs.compactMap { foldersByID[$0] }
        guard reordered != favoriteFolders else { return }
        favoriteFolders = reordered
    }

    func reorderFavorites(_ orderedIDs: [String]) {
        guard orderedIDs.count == favoriteApps.count,
              Set(orderedIDs) == Set(favoriteApps.map(\.id)) else { return }
        let favoritesByID = Dictionary(uniqueKeysWithValues: favoriteApps.map { ($0.id, $0) })
        let reordered = orderedIDs.compactMap { favoritesByID[$0] }
        guard reordered != favoriteApps else { return }
        favoriteApps = reordered
    }

    func orderedWindows(_ windows: [WindowModel]) -> [WindowModel] {
        let order = Dictionary(
            appOrder.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let windowOrder = Dictionary(
            taskbarWindowOrderIDs.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return windows.enumerated().sorted { lhs, rhs in
            let lhsOrder = order[lhs.element.appKey] ?? Int.max
            let rhsOrder = order[rhs.element.appKey] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            if layoutMode == .taskbar {
                let lhsWindowOrder = windowOrder[lhs.element.id] ?? Int.max
                let rhsWindowOrder = windowOrder[rhs.element.id] ?? Int.max
                if lhsWindowOrder != rhsWindowOrder { return lhsWindowOrder < rhsWindowOrder }
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    func dockCompanionSide(for appKey: String, availableAppKeys: Set<String>) -> DockCompanionAppSide {
        if dockCompanionLeftAppKeys.contains(appKey) { return .left }
        if dockCompanionRightAppsCustomized {
            return dockCompanionRightAppKeys.contains(appKey) ? .right : .hidden
        }
        return availableAppKeys.contains(appKey) ? .right : .hidden
    }

    func setDockCompanionLeft(_ isSelected: Bool, appKey: String) {
        if isSelected {
            dockCompanionLeftAppKeys.insert(appKey)
            dockCompanionRightAppKeys.remove(appKey)
        } else {
            dockCompanionLeftAppKeys.remove(appKey)
        }
    }

    func setDockCompanionRight(_ isSelected: Bool, appKey: String, availableAppKeys: Set<String>) {
        if !dockCompanionRightAppsCustomized {
            dockCompanionRightAppKeys = Set(availableAppKeys.filter { !dockCompanionLeftAppKeys.contains($0) })
            dockCompanionRightAppsCustomized = true
        }
        if isSelected {
            dockCompanionLeftAppKeys.remove(appKey)
            dockCompanionRightAppKeys.insert(appKey)
        } else {
            dockCompanionRightAppKeys.remove(appKey)
        }
    }

    @discardableResult
    func addDockCompanionApp(applicationURL: URL, side: DockCompanionAppSide, availableAppKeys: Set<String>) -> Bool {
        let url = applicationURL.standardizedFileURL
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url),
              bundle.infoDictionary != nil else { return false }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let bundleIdentifier = bundle.bundleIdentifier
        let appKey = bundleIdentifier ?? "name:\(name)"
        let wasAdded = dockCompanionAddedApps.contains { $0.id == appKey }
        let previousSide = dockCompanionSide(for: appKey, availableAppKeys: availableAppKeys)
        if !wasAdded {
            dockCompanionAddedApps.append(FavoriteApp(
                id: appKey,
                bundleIdentifier: bundleIdentifier,
                applicationName: name,
                bundlePath: url.path
            ))
        }
        switch side {
        case .left:
            setDockCompanionLeft(true, appKey: appKey)
        case .right:
            setDockCompanionRight(true, appKey: appKey, availableAppKeys: availableAppKeys.union([appKey]))
        case .hidden:
            break
        }
        return !wasAdded || previousSide != side
    }

    func transparency(in mode: TaskDockLayoutMode) -> Double {
        transparencyByMode[mode] ?? 0
    }

    func setTransparency(_ value: Double, in mode: TaskDockLayoutMode) {
        guard mode == .dockCompanion else { return }
        let clamped = min(max(value, 0), 0.7)
        guard transparencyByMode[mode] != clamped else { return }
        transparencyByMode[mode] = clamped
    }

    func showsHiddenApps(in mode: TaskDockLayoutMode) -> Bool {
        hiddenAppsByMode[mode] ?? false
    }

    func setShowsHiddenApps(_ value: Bool, in mode: TaskDockLayoutMode) {
        guard hiddenAppsByMode[mode] != value else { return }
        hiddenAppsByMode[mode] = value
    }

    func showsFinderTabsAsWindows(in mode: TaskDockLayoutMode) -> Bool {
        finderTabsByMode[mode] ?? false
    }

    func setShowsFinderTabsAsWindows(_ value: Bool, in mode: TaskDockLayoutMode) {
        guard finderTabsByMode[mode] != value else { return }
        finderTabsByMode[mode] = value
    }

    private func save() {
        defaults.set(Array(blacklistedAppKeys), forKey: blacklistKey)
        if let data = try? JSONEncoder().encode(blockedWindowRules) {
            defaults.set(data, forKey: blockedWindowRulesKey)
        }
        defaults.set(taskItemHighlightStyle.rawValue, forKey: taskItemHighlightStyleKey)
        for mode in TaskDockLayoutMode.allCases {
            ModePreferenceStorage.save(ModePreferenceSnapshot(
                transparency: transparency(in: mode),
                showHiddenApps: showsHiddenApps(in: mode),
                finderTabsAsWindows: showsFinderTabsAsWindows(in: mode)
            ), mode: mode.rawValue, defaults: defaults)
        }
        defaults.set(layoutMode.rawValue, forKey: layoutModeKey)
        defaults.set(Double(taskbarHeight), forKey: taskbarHeightKey)
        defaults.set(taskbarItemWidthMode.rawValue, forKey: taskbarItemWidthModeKey)
        defaults.set(Double(taskbarItemMaximumWidth), forKey: taskbarItemMaximumWidthKey)
        defaults.set(Double(taskbarItemFontSize), forKey: taskbarItemFontSizeKey)
        defaults.set(favoriteMagnificationEnabled, forKey: favoriteMagnificationEnabledKey)
        defaults.set(Double(favoriteMagnificationScale), forKey: favoriteMagnificationScaleKey)
        defaults.set(taskbarCollapseSameAppWindows, forKey: taskbarCollapseSameAppWindowsKey)
        defaults.set(Array(dockCompanionLeftAppKeys), forKey: dockCompanionLeftAppKeysKey)
        defaults.set(Array(dockCompanionRightAppKeys), forKey: dockCompanionRightAppKeysKey)
        defaults.set(dockCompanionRightAppsCustomized, forKey: dockCompanionRightAppsCustomizedKey)
        if let data = try? JSONEncoder().encode(dockCompanionAddedApps) {
            defaults.set(data, forKey: dockCompanionAddedAppsKey)
        }
        defaults.set(dockCompanionMinimumWindowCount, forKey: dockCompanionMinimumWindowCountKey)
        defaults.set(dockCompanionCollapseThreshold, forKey: dockCompanionCollapseThresholdKey)
        defaults.set(dockCompanionShowsRecentWindows, forKey: dockCompanionShowsRecentWindowsKey)
        defaults.set(dockCompanionShowsBottomBar, forKey: dockCompanionShowsBottomBarKey)
        defaults.set(dockCompanionOverlayEnabled, forKey: dockCompanionOverlayEnabledKey)
        defaults.set(toggleModifier.rawValue, forKey: toggleModifierKey)
        defaults.set(appOrder, forKey: appOrderKey)
        if let data = try? JSONEncoder().encode(favoriteApps) {
            defaults.set(data, forKey: favoriteAppsKey)
        }
        if let data = try? JSONEncoder().encode(recentApps) {
            defaults.set(data, forKey: recentAppsKey)
        }
        if let data = try? JSONEncoder().encode(favoriteFolders) {
            defaults.set(data, forKey: favoriteFoldersKey)
        }
    }
}
