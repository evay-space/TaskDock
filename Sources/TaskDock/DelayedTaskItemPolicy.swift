import Foundation

enum DelayedTaskItemPolicy {
    static let duration: TimeInterval = 10

    private static let viewerTitles: Set<String> = [
        "图片", "视频", "图片和视频", "图片预览", "视频播放", "图片查看器", "视频播放器", "聊天记录",
        "相片和影片", "圖片和影片", "圖片預覽", "聊天記錄",
        "image preview", "video player", "images and videos", "chat history"
    ]

    static func pendingWindows(_ qualifyingIDs: Set<String>, previouslySeen: Set<String>,
                               pending: [String: Date], now: Date) -> [String: Date] {
        var next = pending.filter { id, firstSeen in
            qualifyingIDs.contains(id) && now.timeIntervalSince(firstSeen) < duration
        }
        for id in qualifyingIDs.subtracting(previouslySeen) {
            next[id] = now
        }
        return next
    }

    static func matchesWeChatViewer(title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return viewerTitles.contains(title)
            || ["聊天记录 - ", "聊天記錄 - ", "chat history - "].contains(where: title.hasPrefix)
            || ["的聊天记录", "的聊天記錄", " - chat history"].contains(where: title.hasSuffix)
    }
}
