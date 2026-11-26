enum RecentAppHoverBehavior: String, CaseIterable {
    static let settingsKey = "taskdock.recentAppHoverBehaviorV1"
    case nameBubble
    case programList
}

enum RecentAppDisplayPolicy {
    static func visible<App>(
        from history: [App],
        excluding isExcluded: (App) -> Bool,
        limit: Int = 15
    ) -> [App] {
        Array(history.filter { !isExcluded($0) }.prefix(max(0, limit)))
    }
}
