import CoreGraphics
import Foundation

enum FavoriteMagnificationTiming {
    static let entryDuration: TimeInterval = 0.18
    static let exitDuration: TimeInterval = 0.14

    static func progress(elapsed: TimeInterval, exiting: Bool) -> CGFloat {
        let duration = exiting ? exitDuration : entryDuration
        let linear = CGFloat(min(1, max(0, elapsed / duration)))
        return exiting ? 1 - pow(1 - linear, 3) : linear * linear * (3 - 2 * linear)
    }
}

enum FavoriteShelfInteractionMetrics {
    static let holdDuration: TimeInterval = 0.55
    static let holdMovementTolerance: CGFloat = 8
    static let dragDistance: CGFloat = 12
    static let dragSettleDuration: TimeInterval = 0.18
    static let pressedOpacity: CGFloat = 0.42
}

enum FavoriteShelfBadgeMetrics {
    static let height: CGFloat = 11.5
    static let fontSize: CGFloat = 8

    static func width(for label: String) -> CGFloat {
        label.count == 1 ? height : CGFloat(label.count) * 6 + 5
    }

    static func scale(for iconScale: CGFloat) -> CGFloat { 1 + (iconScale - 1) * 0.55 }
}

enum FavoriteShelfReorderTarget {
    static func index(source: Int, count: Int, translation: CGFloat,
                      itemStep: CGFloat, previewIndex: Int? = nil) -> Int? {
        guard count > 1, (0..<count).contains(source), itemStep > 0,
              translation.isFinite else { return nil }
        let distance = abs(translation) / itemStep
        let crossed = Int(min(CGFloat(count), floor(distance + 0.5)))
        let proposed = min(count - 1, max(0, source + (translation < 0 ? -crossed : crossed)))
        let previous = previewIndex ?? source
        if previous != source, proposed != previous {
            let priorDistance = abs(previous - source)
            if proposed == source, distance > 0.42 { return previous }
            let sameDirection = (previous - source) * (proposed - source) > 0
            if sameDirection, abs(proposed - source) > priorDistance,
               distance < CGFloat(priorDistance) + 0.58 { return previous }
            if sameDirection, abs(proposed - source) < priorDistance,
               distance > CGFloat(priorDistance) - 0.58 { return previous }
        }
        return proposed == source ? nil : proposed
    }
}

enum TaskbarFavoriteLaneLayout {
    /// Reserve one envelope for the entire hover session instead of following
    /// the wave's small, pointer-dependent changes on every frame.
    static func hoverTrailingSpace(appCount: Int, folderCount: Int, showsTrash: Bool,
                                   showsApplications: Bool = false,
                                   sizeScale: CGFloat, peakScale: CGFloat) -> CGFloat {
        guard peakScale > 1, sizeScale > 0 else { return 0 }
        let hasUtilities = showsTrash || folderCount > 0
        let hasUtilitySeparator = appCount > 0 && hasUtilities
        let hasAppsSeparator = showsApplications && (appCount > 0 || hasUtilities)
        var separators: Set<Int> = []
        if hasUtilitySeparator { separators.insert(appCount) }
        let appsSeparatorIndex = appCount + (hasUtilitySeparator ? 1 : 0) + folderCount + (showsTrash ? 1 : 0)
        if hasAppsSeparator { separators.insert(appsSeparatorIndex) }
        let count = appsSeparatorIndex + (hasAppsSeparator ? 1 : 0) + (showsApplications ? 1 : 0)
        guard count > 0 else { return 0 }
        let width = contentWidth(appCount: appCount, folderCount: folderCount,
                                 showsTrash: showsTrash, showsApplications: showsApplications) * sizeScale
        let rightLimit = width - (FavoriteMagnificationLayout.itemStep - 28) * sizeScale
        var maximum: CGFloat = 0
        for pointer in stride(from: CGFloat.zero, through: width, by: sizeScale) {
            let layout = FavoriteMagnificationLayout(count: count, pointerX: pointer,
                sizeScale: sizeScale, separatorIndices: separators, peakScale: peakScale)
            for index in 0..<count where !separators.contains(index) {
                let center = (CGFloat(index) + 0.5) * FavoriteMagnificationLayout.itemStep * sizeScale
                    + layout.offsets[index]
                let right = center + FavoriteMagnificationLayout.iconSize * sizeScale * layout.scales[index] / 2
                maximum = max(maximum, right - rightLimit)
            }
        }
        return ceil(maximum + sizeScale)
    }

    static func contentWidth(appCount: Int, folderCount: Int,
                             showsTrash: Bool = true,
                             showsApplications: Bool = false) -> CGFloat {
        let hasUtilities = showsTrash || folderCount > 0
        let separatorCount = (appCount > 0 && hasUtilities ? 1 : 0)
            + (showsApplications && (appCount > 0 || hasUtilities) ? 1 : 0)
        let itemCount = appCount + folderCount + (showsTrash ? 1 : 0)
            + (showsApplications ? 1 : 0) + separatorCount
        return CGFloat(itemCount) * FavoriteMagnificationLayout.itemStep - CGFloat(separatorCount * 28)
    }
}

struct FavoriteVisualGeometry {
    let centerX: CGFloat
    let iconBottomY: CGFloat
    let indicatorCenterY: CGFloat
    let indicatorWidth: CGFloat
    let indicatorHeight: CGFloat
}

enum FavoriteShelfSeparator {
    static let width: CGFloat = 1
    static let height: CGFloat = 16
    static let slotWidth: CGFloat = 2
    static let bottomInset: CGFloat = 10
    static let magnifiedIconGap: CGFloat = 4
}

/// Dock-style visual positions. Hit targets remain in their compact slots.
struct FavoriteMagnificationLayout {
    static let itemStep: CGFloat = 30
    static let iconSize: CGFloat = 26
    static let indicatorDiameter: CGFloat = 4
    static let iconBottomInset: CGFloat = 6
    static let runningIndicatorCenter: CGFloat = 3.5
    static let maximumScale: CGFloat = 2.0
    static let influenceRadius: CGFloat = 3.32
    static let influenceExponent: CGFloat = 1.56
    static let gapGrowthPerScale: CGFloat = 1.25
    static let hoverLabelHeight: CGFloat = 31
    // Integrate the fixed influence curve once. A discrete sum changes slightly
    // with the pointer's position between slots and makes distant icons wobble.
    private static let influenceArea: [CGFloat] = {
        let samples = 256
        let step = influenceRadius / CGFloat(samples)
        var area = [CGFloat.zero]
        func influence(_ distance: CGFloat) -> CGFloat {
            pow(max(0, 1 - pow(distance / influenceRadius, 2)), influenceExponent)
        }
        for index in 1...samples {
            let a = CGFloat(index - 1) * step
            let b = CGFloat(index) * step
            area.append(area[index - 1] + (influence(a) + influence(b)) * step / 2)
        }
        return area
    }()

    static func configuredScale(_ scale: CGFloat, enabled: Bool, reducesMotion: Bool) -> CGFloat {
        guard enabled else { return 1 }
        return reducesMotion ? min(scale, 1.35) : scale
    }

    static func scale(distanceInSlots: CGFloat, peakScale: CGFloat) -> CGFloat {
        let normalized = max(0, 1 - pow(distanceInSlots / influenceRadius, 2))
        return 1 + (peakScale - 1) * pow(normalized, influenceExponent)
    }

    static func edgeInsets(for visibleBounds: ClosedRange<CGFloat>,
                           canvasWidth: CGFloat, margin: CGFloat) -> CGSize {
        CGSize(width: max(0, visibleBounds.lowerBound - margin),
            height: max(0, canvasWidth - visibleBounds.upperBound - margin))
    }

    static func trailingReveal(center: CGFloat, iconWidth: CGFloat, scale: CGFloat,
                               offset: CGFloat, viewportEnd: CGFloat, clearance: CGFloat) -> CGFloat {
        guard center < viewportEnd, scale > 1 || offset > 0 else { return 0 }
        let rightEdge = center + offset + iconWidth * scale / 2
        return min(max(0, clearance), max(0, rightEdge - viewportEnd))
    }

    /// Each nil center is a task item separating two independently animated icon runs.
    static func linkedIconWave(centers: [CGFloat?], widths: [CGFloat], hoveredIndex: Int,
                               pointerX: CGFloat, slotWidth: CGFloat, sizeScale: CGFloat,
                               peakScale: CGFloat, leftClearance: CGFloat, rightClearance: CGFloat = 0,
                               lastSlotWidth: CGFloat? = nil,
                               itemSlotWidths: [CGFloat]? = nil,
                               separatorDistances: [Int: CGFloat] = [:],
                               fixedScaleSlot: Int? = nil,
                               trailingReservations: [Int: CGFloat] = [:],
                               yieldingTaskSlots: Set<Int> = []) -> LinkedFavoriteWave {
        var wave = LinkedFavoriteWave(count: centers.count)
        guard centers.indices.contains(hoveredIndex), centers[hoveredIndex] != nil,
              widths.count == centers.count, slotWidth > 0, pointerX.isFinite else { return wave }

        var first = hoveredIndex
        while first > 0, centers[first - 1] != nil { first -= 1 }
        var last = hoveredIndex
        while last + 1 < centers.count, centers[last + 1] != nil { last += 1 }

        let range = first...last
        let runCenters = centers[range].compactMap { $0 }
        let runWidths = Array(widths[range])
        guard let firstCenter = runCenters.first, let lastCenter = runCenters.last else { return wave }
        let pointer = min(max(pointerX, firstCenter), lastCenter)
        let pointerInSlots: CGFloat
        if itemSlotWidths != nil, let next = runCenters.firstIndex(where: { $0 > pointer }), next > 0 {
            let previous = next - 1
            pointerInSlots = CGFloat(previous)
                + (pointer - runCenters[previous]) / (runCenters[next] - runCenters[previous])
        } else {
            pointerInSlots = itemSlotWidths == nil ? (pointer - firstCenter) / slotWidth : CGFloat(runCenters.count - 1)
        }
        let influences = runCenters.enumerated().map { index, center -> CGFloat in
            if first + index == fixedScaleSlot { return 0 }
            let distance = itemSlotWidths == nil ? abs(pointer - center) / slotWidth : abs(pointerInSlots - CGFloat(index))
            return scale(distanceInSlots: distance, peakScale: 2) - 1
        }
        wave.influences.replaceSubrange(range, with: influences)
        guard peakScale > 1 else { return wave }

        let firstWidth = itemSlotWidths?[first] ?? slotWidth
        let lastWidth = itemSlotWidths?[last] ?? (last == centers.count - 1 ? lastSlotWidth ?? slotWidth : slotWidth)
        let leftInset = (firstWidth - runWidths[0]) / 2
        let rightInset = (lastWidth - runWidths[runWidths.count - 1]) / 2
        let yieldsOnLeft = yieldingTaskSlots.contains(first - 1)
        let yieldsOnRight = yieldingTaskSlots.contains(last + 1)
        let leftSpace = leftInset + (first == 0 || yieldsOnLeft ? leftClearance : 0)
        let rightSpace = rightInset + (last == centers.count - 1 || yieldsOnRight ? rightClearance : 0)

        // Use the shelf's spacing and pointer displacement, then fit the run
        // between the fixed task items or the available canvas edges.
        let scales = influences.map { 1 + (peakScale - 1) * $0 }
        var centersWithSeparators: [CGFloat] = []
        var widthsWithSeparators: [CGFloat] = []
        var scalesWithSeparators: [CGFloat] = []
        var separatorIndices = Set<Int>()
        var separatorIndicesBySlot: [Int: Int] = [:]
        var iconIndices: [Int] = []
        for (local, slot) in range.enumerated() {
            let center = runCenters[local]
            if local > 0, let distance = separatorDistances[slot] {
                let separatorIndex = centersWithSeparators.count
                separatorIndices.insert(separatorIndex)
                separatorIndicesBySlot[slot] = separatorIndex
                centersWithSeparators.append(center - distance)
                widthsWithSeparators.append(FavoriteShelfSeparator.width * sizeScale)
                scalesWithSeparators.append(1)
            }
            iconIndices.append(centersWithSeparators.count)
            centersWithSeparators.append(center)
            widthsWithSeparators.append(runWidths[local])
            scalesWithSeparators.append(scales[local])
        }
        let allShifts = horizontalShifts(centers: centersWithSeparators, widths: widthsWithSeparators,
            scales: scalesWithSeparators, pointerX: firstCenter + pointerInSlots * slotWidth,
            slotWidth: slotWidth, iconWidth: iconSize * sizeScale, sizeScale: sizeScale,
            peakScale: peakScale, separatorIndices: separatorIndices)
        let shifts = iconIndices.map { allShifts[$0] }
        let leftGrowth = runWidths[0] * (scales[0] - 1) / 2 - shifts[0]
        let lastIndex = scales.count - 1
        let rightGrowth = runWidths[lastIndex] * (scales[lastIndex] - 1) / 2 + shifts[lastIndex]
        let total = leftGrowth + rightGrowth
        guard total > 0 else { return wave }
        let fit = min(1, max(0, leftSpace + rightSpace) / total)
        let correction = max(0, leftGrowth * fit - leftSpace)
            - max(0, rightGrowth * fit - rightSpace)
        for (local, index) in range.enumerated() {
            wave.scales[index] = 1 + (scales[local] - 1) * fit
            wave.offsets[index] = shifts[local] * fit + correction
        }
        wave.separatorOffsets = separatorIndicesBySlot.mapValues { allShifts[$0] * fit + correction }
        wave.leadingOverflow = max(0, leftGrowth * fit - correction - leftInset)
        wave.trailingOverflow = max(0, rightGrowth * fit + correction - rightInset)
        // Shift the neighboring blocks as units so a yielding task cannot
        // collide with the next item. Their scales remain at rest.
        if yieldsOnLeft {
            for index in 0..<first { wave.offsets[index] = -wave.leadingOverflow }
        }
        if yieldsOnRight {
            let reservedSpace = min(rightClearance, trailingReservations[runCenters.count] ?? 0)
            wave.trailingTaskShift = max(wave.trailingOverflow, reservedSpace)
            for index in (last + 1)..<centers.count { wave.offsets[index] = wave.trailingTaskShift }
        }
        wave.edgeExtension = total * fit / 2
        return wave
    }

    private static func integratedInfluence(to distance: CGFloat) -> CGFloat {
        let position = min(1, max(0, distance / influenceRadius)) * CGFloat(influenceArea.count - 1)
        let lower = Int(position)
        let upper = min(lower + 1, influenceArea.count - 1)
        return influenceArea[lower] + (influenceArea[upper] - influenceArea[lower]) * (position - CGFloat(lower))
    }
    let scales: [CGFloat]
    let offsets: [CGFloat]

    init(count: Int, pointerX: CGFloat?, sizeScale: CGFloat = 1,
         separatorIndices: Set<Int> = [], peakScale: CGFloat = Self.maximumScale) {
        guard count > 0 else {
            scales = []
            offsets = []
            return
        }
        let itemStep = Self.itemStep * sizeScale
        let iconSize = Self.iconSize * sizeScale
        let compactOffsets: [CGFloat] = (0..<count).map { index in
            separatorIndices.reduce(CGFloat.zero) { result, separator in
                result - (index > separator ? 28 : index == separator ? 14 : 0) * sizeScale
            }
        }
        let centers = (0..<count).map {
            (CGFloat($0) + 0.5) * itemStep + compactOffsets[$0]
        }
        scales = (0..<count).map { index in
            guard let pointerX else { return 1 }
            if separatorIndices.contains(index) { return 1 }
            return Self.scale(distanceInSlots: abs(pointerX - centers[index]) / itemStep, peakScale: peakScale)
        }

        guard let pointerX, peakScale > 1 else {
            offsets = compactOffsets
            return
        }
        let widths = centers.indices.map { separatorIndices.contains($0) ? FavoriteShelfSeparator.width * sizeScale : iconSize }
        let shifts = Self.horizontalShifts(centers: centers, widths: widths, scales: scales,
            pointerX: pointerX, slotWidth: itemStep, iconWidth: iconSize,
            sizeScale: sizeScale, peakScale: peakScale, separatorIndices: separatorIndices)
        offsets = compactOffsets.indices.map { compactOffsets[$0] + shifts[$0] }
    }

    /// Preserve the idle gaps while making room for the visible growth of each icon.
    static func horizontalShifts(centers: [CGFloat], widths: [CGFloat], scales: [CGFloat],
                                 pointerX: CGFloat, slotWidth: CGFloat, iconWidth: CGFloat,
                                 sizeScale: CGFloat, peakScale: CGFloat,
                                 separatorIndices: Set<Int> = []) -> [CGFloat] {
        guard let firstCenter = centers.first, slotWidth > 0 else { return [] }
        let anchor = (iconWidth + gapGrowthPerScale * sizeScale) * (peakScale - 1)
            * integratedInfluence(to: (pointerX - firstCenter) / slotWidth)
        var shifts = Array(repeating: -anchor, count: centers.count)
        for index in centers.indices.dropFirst() {
            let previous = index - 1
            let grows = (widths[previous] * (scales[previous] - 1) + widths[index] * (scales[index] - 1)) / 2
            if separatorIndices.contains(previous) || separatorIndices.contains(index) {
                let desiredDistance = FavoriteShelfSeparator.magnifiedIconGap * sizeScale
                    + (widths[previous] + widths[index]) / 2
                let restingDistance = centers[index] - centers[previous]
                shifts[index] = shifts[previous] + grows + desiredDistance - restingDistance
            } else {
                let gapGrowth = (scales[previous] + scales[index] - 2) / 2 * gapGrowthPerScale * sizeScale
                shifts[index] = shifts[previous] + grows + gapGrowth
            }
        }
        return shifts
    }

    func horizontalOverflow(sizeScale: CGFloat, contentWidth: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        guard !scales.isEmpty else { return (0, 0) }
        var left: CGFloat = 0
        var right = contentWidth
        for index in scales.indices {
            let geometry = visualGeometry(at: index, sizeScale: sizeScale, dragOffset: 0, isNoWindow: true)
            let halfWidth = Self.iconSize * scales[index] * sizeScale / 2
            left = min(left, geometry.centerX - halfWidth - 6 * sizeScale)
            right = max(right, geometry.centerX + halfWidth + 6 * sizeScale)
        }
        return (-left, right - contentWidth)
    }

    static func interpolate(_ start: CGFloat, _ target: CGFloat, progress: CGFloat) -> CGFloat {
        start + (target - start) * progress
    }

    static func centerLift(for scale: CGFloat, iconHeight: CGFloat, sizeScale: CGFloat) -> CGFloat {
        iconHeight * (scale - 1) / 2 - lift(for: scale) * sizeScale
    }

    static func indicatorScale(for scale: CGFloat) -> CGFloat { 1 + (scale - 1) * 0.5 }

    static func lift(for scale: CGFloat) -> CGFloat {
        -4.5 * (scale - 1) / (maximumScale - 1)
    }

    static func headroom(for sizeScale: CGFloat, peakScale: CGFloat = maximumScale) -> CGFloat {
        ceil((30 * (peakScale - 1) + 8 + hoverLabelHeight) * sizeScale)
    }

    static func sideClearance(for sizeScale: CGFloat) -> CGFloat {
        ceil(108 * sizeScale)
    }

    static func idleSideClearance(for sizeScale: CGFloat) -> CGFloat {
        ceil(31 * sizeScale)
    }

    static func clampedPointerX(trackingX: CGFloat, count: Int, sizeScale: CGFloat,
                                separatorCount: Int = 0) -> CGFloat {
        guard count > 0 else { return 0 }
        let step = itemStep * sizeScale
        let rowWidth = CGFloat(count) * step - CGFloat(separatorCount) * 28 * sizeScale
        let pointerX = trackingX - sideClearance(for: sizeScale)
        return min(max(pointerX, step / 2), rowWidth - step / 2)
    }

    static func hoveredItemIndex(pointerX: CGFloat, count: Int, sizeScale: CGFloat,
                                 separatorIndices: Set<Int>, excludedIndices: Set<Int> = []) -> Int? {
        (0..<max(0, count)).filter {
            !separatorIndices.contains($0) && !excludedIndices.contains($0)
        }.min { left, right in
            func center(_ index: Int) -> CGFloat {
                let compression = separatorIndices.reduce(CGFloat.zero) { result, separator in
                    result + (index > separator ? 28 : index == separator ? 14 : 0) * sizeScale
                }
                return (CGFloat(index) + 0.5) * itemStep * sizeScale - compression
            }
            return abs(pointerX - center(left)) < abs(pointerX - center(right))
        }
    }

    func reorderPreviewOffset(from sourceIndex: Int, to destinationIndex: Int,
                              sizeScale: CGFloat) -> CGFloat {
        guard scales.indices.contains(sourceIndex), scales.indices.contains(destinationIndex) else { return 0 }
        return CGFloat(destinationIndex - sourceIndex) * Self.itemStep * sizeScale
            + offsets[destinationIndex] - offsets[sourceIndex]
    }

    func visualGeometry(
        at index: Int,
        sizeScale: CGFloat,
        dragOffset: CGFloat,
        isNoWindow: Bool
    ) -> FavoriteVisualGeometry {
        let scale = scales[index]
        let liftY = -Self.lift(for: scale) * sizeScale
        let indicatorScale = Self.indicatorScale(for: scale)
        return FavoriteVisualGeometry(
            centerX: (CGFloat(index) * Self.itemStep + 15) * sizeScale
                + offsets[index] + dragOffset,
            iconBottomY: Self.iconBottomInset * sizeScale + liftY,
            indicatorCenterY: (isNoWindow ? Self.runningIndicatorCenter : 3) * sizeScale + liftY,
            indicatorWidth: (isNoWindow ? Self.indicatorDiameter : 15) * sizeScale * indicatorScale,
            indicatorHeight: (isNoWindow ? Self.indicatorDiameter : 2) * sizeScale * indicatorScale
        )
    }
}

struct LinkedFavoriteWave {
    var influences: [CGFloat]
    var scales: [CGFloat]
    var offsets: [CGFloat]
    var leadingOverflow: CGFloat = 0
    var trailingOverflow: CGFloat = 0
    var separatorOffsets: [Int: CGFloat] = [:]
    var trailingTaskShift: CGFloat = 0
    var edgeExtension: CGFloat = 0

    init(count: Int) {
        influences = Array(repeating: 0, count: count)
        scales = Array(repeating: 1, count: count)
        offsets = Array(repeating: 0, count: count)
    }
}
