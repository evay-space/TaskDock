struct TaskbarArrivalOrder {
    struct Window: Equatable {
        let id: String
        let appKey: String
    }

    private var hasSeenSnapshot = false
    private var visibleAppKeys: Set<String> = []
    private var orderedWindowIDs: [String] = []

    mutating func reconcile(_ windows: [Window], appOrder: [String]) -> (apps: [String], windows: [String]) {
        var seenApps = Set<String>()
        let currentApps = windows.map(\.appKey).filter { seenApps.insert($0).inserted }
        let currentAppSet = Set(currentApps)
        var nextAppOrder = appOrder
        if hasSeenSnapshot {
            for appKey in currentApps where !visibleAppKeys.contains(appKey) {
                nextAppOrder.removeAll { $0 == appKey }
                nextAppOrder.append(appKey)
            }
        } else {
            var knownApps = Set(nextAppOrder)
            nextAppOrder.append(contentsOf: currentApps.filter { knownApps.insert($0).inserted })
            hasSeenSnapshot = true
        }

        let currentWindowIDs = Set(windows.map(\.id))
        orderedWindowIDs.removeAll { !currentWindowIDs.contains($0) }
        var knownWindowIDs = Set(orderedWindowIDs)
        orderedWindowIDs.append(contentsOf: windows.map(\.id).filter { knownWindowIDs.insert($0).inserted })
        visibleAppKeys = currentAppSet
        return (nextAppOrder, orderedWindowIDs)
    }
}

enum MinimalAppOrder {
    static func reconcile(saved: [String], candidates: [String]) -> [String] {
        var seen = Set<String>()
        return (saved + candidates).filter { seen.insert($0).inserted }
    }

    static func visible(saved: [String], candidates: [String]) -> [String] {
        let visible = Set(candidates)
        return reconcile(saved: saved, candidates: candidates).filter { visible.contains($0) }
    }

    static func replacingVisible(saved: [String], with keys: [String]) -> [String] {
        let ordered = reconcile(saved: [], candidates: keys)
        let visible = Set(ordered)
        var next = ordered.makeIterator()
        return reconcile(saved: saved, candidates: ordered).map { key in
            visible.contains(key) ? (next.next() ?? key) : key
        }
    }
}
