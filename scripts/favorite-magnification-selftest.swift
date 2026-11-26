import Foundation

@main
struct FavoriteMagnificationSelfTest {
    static func main() {
        let disabledIdle = FavoriteMagnificationLayout(count: 12, pointerX: nil,
            separatorIndices: [8], peakScale: 1)
        for x in stride(from: CGFloat(-100), through: 800, by: 2) {
            let hovering = FavoriteMagnificationLayout(count: 12, pointerX: x,
                separatorIndices: [8], peakScale: 1)
            precondition(hovering.scales == disabledIdle.scales)
            precondition(hovering.offsets == disabledIdle.offsets,
                "Disabled magnification must keep folders and separators fixed")
        }
        let step = FavoriteMagnificationLayout.itemStep
        let gap = step - FavoriteMagnificationLayout.iconSize

        let regularCenters = (0..<8).map { (CGFloat($0) + 0.5) * step }
        for pointer in stride(from: regularCenters[0], through: regularCenters[7], by: 2) {
            let shelf = FavoriteMagnificationLayout(count: 8, pointerX: pointer)
            let minimal = FavoriteMagnificationLayout.linkedIconWave(
                centers: regularCenters.map(Optional.some), widths: Array(repeating: FavoriteMagnificationLayout.iconSize, count: 8),
                hoveredIndex: 3, pointerX: pointer, slotWidth: step, sizeScale: 1,
                peakScale: FavoriteMagnificationLayout.maximumScale, leftClearance: 150, rightClearance: 150,
                itemSlotWidths: Array(repeating: step, count: 8))
            precondition(zip(shelf.scales, minimal.scales).allSatisfy { abs($0 - $1) < 0.0001 })
            precondition(zip(shelf.offsets, minimal.offsets).allSatisfy { abs($0 - $1) < 0.0001 })
        }
        precondition(FavoriteMagnificationLayout.configuredScale(2, enabled: false, reducesMotion: false) == 1)
        precondition(FavoriteMagnificationLayout.configuredScale(2, enabled: true, reducesMotion: true) == 1.35)

        let separatorCenters: [CGFloat?] = [15, 49, 83]
        let separatorWave = FavoriteMagnificationLayout.linkedIconWave(
            centers: separatorCenters, widths: [26, 26, 26], hoveredIndex: 1, pointerX: 49,
            slotWidth: step, sizeScale: 1, peakScale: 1.5, leftClearance: 100, rightClearance: 100,
            itemSlotWidths: [step, step, step], separatorDistances: [1: 17, 2: 17])
        let separatorCenter = 32 + separatorWave.separatorOffsets[1]!
        let leftEdge = 15 + separatorWave.offsets[0] + 13 * separatorWave.scales[0]
        let rightEdge = 49 + separatorWave.offsets[1] - 13 * separatorWave.scales[1]
        let expectedClearance = FavoriteShelfSeparator.magnifiedIconGap + FavoriteShelfSeparator.width / 2
        precondition(abs(separatorCenter - leftEdge - expectedClearance) < 0.0001)
        precondition(abs(rightEdge - separatorCenter - expectedClearance) < 0.0001)

        // Task items cut the wave even when the next icon is inside its nominal radius.
        let segmentedCenters: [CGFloat?] = [18.5, 55.5, nil, 129.5, 166.5, 203.5, 240.5, 277.5, nil, 351.5]
        func linkedWave(_ index: Int, pointer: CGFloat, peak: CGFloat = 1.4) -> LinkedFavoriteWave {
            FavoriteMagnificationLayout.linkedIconWave(centers: segmentedCenters,
                widths: Array(repeating: 28, count: segmentedCenters.count),
                hoveredIndex: index, pointerX: pointer, slotWidth: 37,
                sizeScale: 1, peakScale: peak, leftClearance: 42)
        }
        let leftWave = linkedWave(1, pointer: 55.5)
        let left = leftWave.influences
        precondition(left[1] == 1 && left[0] > 0 && left[0] < 1)
        precondition(left.dropFirst(2).allSatisfy { $0 == 0 })
        precondition(leftWave.offsets.dropFirst(2).allSatisfy { $0 == 0 })
        precondition(leftWave.offsets[0] < 0 && leftWave.leadingOverflow > 0 && leftWave.edgeExtension > 0)
        let rightWave = linkedWave(3, pointer: 129.5)
        let right = rightWave.influences
        precondition(right[3] == 1 && right[4] > right[5] && right[5] > right[6])
        precondition(right[6] > 0 && right[7] == 0)
        precondition(right.prefix(3).allSatisfy { $0 == 0 } && right[9] == 0)
        precondition(rightWave.offsets.prefix(3).allSatisfy { $0 == 0 } && rightWave.offsets[9] == 0)
        precondition(rightWave.scales[7] == 1)
        let barrier = linkedWave(2, pointer: 92.5)
        precondition(barrier.influences.allSatisfy { $0 == 0 } && barrier.edgeExtension == 0)
        let between = linkedWave(4, pointer: 148).influences
        precondition(between[3] == between[4] && between[3] > between[5])
        let linkedCentered = linkedWave(5, pointer: 203.5)
        let movedRight = linkedWave(5, pointer: 209.5)
        precondition(movedRight.offsets[5] < linkedCentered.offsets[5], "The icon moves opposite the pointer")
        precondition(linkedWave(5, pointer: 203.5, peak: 1).edgeExtension == 0)

        let yieldingCenters: [CGFloat?] = [15, nil, 151, 181, nil, 317]
        func yieldingWave(pointer: CGFloat) -> LinkedFavoriteWave {
            FavoriteMagnificationLayout.linkedIconWave(centers: yieldingCenters,
                widths: [28, 0, 28, 28, 0, 28], hoveredIndex: 2, pointerX: pointer,
                slotWidth: 30, sizeScale: 1, peakScale: 1.4, leftClearance: 42,
                rightClearance: 42, yieldingTaskSlots: [1, 4])
        }
        let yieldingRight = yieldingWave(pointer: 151)
        precondition(yieldingRight.scales[2] > 1.3 && yieldingRight.offsets[4] > 0)
        precondition(yieldingRight.offsets[4] == yieldingRight.offsets[5])
        precondition(yieldingRight.scales[4] == 1 && yieldingRight.scales[5] == 1)
        let yieldingLeft = yieldingWave(pointer: 181)
        precondition(yieldingLeft.offsets[1] < 0 && yieldingLeft.offsets[1] == yieldingLeft.offsets[0])
        precondition(yieldingLeft.scales[0] == 1 && yieldingLeft.scales[1] == 1)

        for bounds: ClosedRange<CGFloat> in [40...200, 32...216, 48...192] {
            let insets = FavoriteMagnificationLayout.edgeInsets(for: bounds, canvasWidth: 240, margin: 6)
            precondition(bounds.lowerBound - insets.width == 6)
            precondition(240 - insets.height - bounds.upperBound == 6)
        }
        let folderReveal = FavoriteMagnificationLayout.trailingReveal(center: 480, iconWidth: 26,
            scale: 1.4, offset: 26, viewportEnd: 512, clearance: 42)
        precondition(abs(folderReveal - 12.2) < 0.0001)
        precondition(FavoriteMagnificationLayout.trailingReveal(center: 530, iconWidth: 26,
            scale: 1.4, offset: 26, viewportEnd: 512, clearance: 42) == 0)
        let utilityWave = FavoriteMagnificationLayout.linkedIconWave(
            centers: [15, 45, 81, 119], widths: [28, 28, 27, 30],
            hoveredIndex: 3, pointerX: 119, slotWidth: 30,
            sizeScale: 1, peakScale: 1.4, leftClearance: 42,
            rightClearance: 42, lastSlotWidth: 40)
        precondition(utilityWave.scales[3] > utilityWave.scales[2] && utilityWave.scales[2] > 1)
        precondition(utilityWave.scales[1] > 1 && utilityWave.edgeExtension > 0)
        let inlineCenters: [CGFloat?] = [15, 45, 77, 115]
        var previousInlineOffsets: [CGFloat]?
        for pointer in stride(from: CGFloat(45), through: 115, by: 0.5) {
            let hoveredIndex = pointer < 60 ? 1 : pointer < 94 ? 2 : 3
            let wave = FavoriteMagnificationLayout.linkedIconWave(centers: inlineCenters,
                widths: [28, 26, 27, 30], hoveredIndex: hoveredIndex, pointerX: pointer,
                slotWidth: 30, sizeScale: 1, peakScale: 1.4, leftClearance: 42,
                rightClearance: 42, lastSlotWidth: 40, itemSlotWidths: [30, 30, 32, 40])
            precondition(wave.scales[1] > 1 && wave.scales[2] > 1 && wave.scales[3] > 1)
            if let previousInlineOffsets {
                precondition(zip(previousInlineOffsets, wave.offsets).allSatisfy { abs($0 - $1) < 1 })
            }
            previousInlineOffsets = wave.offsets
        }
        let separatedUtilities = FavoriteMagnificationLayout.linkedIconWave(
            centers: [15, 45, nil, 81, 119], widths: [28, 28, 0, 27, 30],
            hoveredIndex: 4, pointerX: 119, slotWidth: 30,
            sizeScale: 1, peakScale: 1.4, leftClearance: 42,
            rightClearance: 42, lastSlotWidth: 40)
        precondition(separatedUtilities.scales.prefix(3).allSatisfy { $0 == 1 })
        precondition(separatedUtilities.scales[3] > 1 && separatedUtilities.scales[4] > 1)

        let mixedWave = FavoriteMagnificationLayout.linkedIconWave(
            centers: [15, 91, 167, 243, nil, 355], widths: [28, 120, 28, 120, 0, 28],
            hoveredIndex: 1, pointerX: 91, slotWidth: 30,
            sizeScale: 1, peakScale: 1.4, leftClearance: 42,
            itemSlotWidths: [30, 122, 30, 122, 0, 30])
        precondition(mixedWave.scales[1] > mixedWave.scales[0] && mixedWave.scales[0] > 1)
        precondition(mixedWave.scales[2] > 1 && mixedWave.scales[5] == 1)
        let grownGap = 76 + mixedWave.offsets[2] - mixedWave.offsets[1]
            - (120 * mixedWave.scales[1] + 28 * mixedWave.scales[2]) / 2
        let mixedGapGrowth = (mixedWave.scales[1] + mixedWave.scales[2] - 2) / 2
            * FavoriteMagnificationLayout.gapGrowthPerScale
        precondition(abs(grownGap - 2 - mixedGapGrowth) < 0.0001)

        for count in 1...12 {
            for leftBarrier in [false, true] {
                let slotWidth: CGFloat = 30
                let iconCenters = (0..<count).map { (CGFloat($0) + 0.5) * slotWidth }
                let centers: [CGFloat?] = (leftBarrier ? [nil] : []) + iconCenters.map(Optional.some) + [nil]
                let icons = centers.indices.filter { centers[$0] != nil }
                let widths = centers.indices.map { $0.isMultiple(of: 2) ? CGFloat(28) : 26 }
                var previousOffsets: [CGFloat]?
                for x in stride(from: CGFloat(0), to: CGFloat(count) * slotWidth, by: 0.5) {
                    let index = icons[Int(x / slotWidth)]
                    let wave = FavoriteMagnificationLayout.linkedIconWave(centers: centers, widths: widths,
                        hoveredIndex: index, pointerX: x, slotWidth: slotWidth,
                        sizeScale: 1, peakScale: 1.4, leftClearance: 42)
                    if let previousOffsets {
                        precondition(zip(previousOffsets, wave.offsets).allSatisfy { abs($0 - $1) < 2 },
                            "An icon entering or leaving the wave must not jump")
                    }
                    previousOffsets = wave.offsets
                    for (left, right) in zip(icons, icons.dropFirst()) {
                        let gap = slotWidth + wave.offsets[right] - wave.offsets[left]
                            - (widths[left] * wave.scales[left] + widths[right] * wave.scales[right]) / 2
                        let idleGap = slotWidth - (widths[left] + widths[right]) / 2
                        let gapGrowth = (wave.scales[left] + wave.scales[right] - 2) / 2
                            * FavoriteMagnificationLayout.gapGrowthPerScale
                        precondition(abs(gap - idleGap - gapGrowth) < 0.0001,
                            "Spacing must grow by the same amount as on the shelf")
                    }
                    let last = icons[icons.count - 1]
                    let rightEdge = iconCenters[count - 1] + wave.offsets[last] + widths[last] * wave.scales[last] / 2
                    precondition(rightEdge <= CGFloat(count) * slotWidth + 0.001)
                }
            }
        }


        for exiting in [false, true] {
            let duration = exiting ? FavoriteMagnificationTiming.exitDuration : FavoriteMagnificationTiming.entryDuration
            precondition(FavoriteMagnificationTiming.progress(elapsed: 0, exiting: exiting) == 0)
            precondition(FavoriteMagnificationTiming.progress(elapsed: duration, exiting: exiting) == 1)
            var previous: CGFloat = 0
            for frame in 0...120 {
                let progress = FavoriteMagnificationTiming.progress(
                    elapsed: duration * Double(frame) / 120, exiting: exiting)
                precondition(progress >= previous && progress <= 1)
                previous = progress
            }
        }
        let idle = FavoriteMagnificationLayout(count: 9, pointerX: nil)
        for appCount in [0, 1, 6, 13] {
            for peak: CGFloat in [1.5, 2.4] {
                let folderCount = 2
                let separators: Set<Int> = appCount > 0 ? [appCount] : []
                let count = appCount + folderCount + 1 + separators.count
                let width = TaskbarFavoriteLaneLayout.contentWidth(appCount: appCount,
                    folderCount: folderCount, showsTrash: true)
                let reserved = TaskbarFavoriteLaneLayout.hoverTrailingSpace(appCount: appCount,
                    folderCount: folderCount, showsTrash: true, sizeScale: 1, peakScale: peak)
                for pointer in stride(from: CGFloat.zero, through: width, by: 0.5) {
                    let wave = FavoriteMagnificationLayout(count: count, pointerX: pointer,
                        separatorIndices: separators, peakScale: peak)
                    for index in 0..<count where !separators.contains(index) {
                        let right = (CGFloat(index) + 0.5) * step + wave.offsets[index]
                            + FavoriteMagnificationLayout.iconSize * wave.scales[index] / 2
                        precondition(right <= width - (step - 28) + reserved,
                            "One fixed reservation must cover every pointer position")
                    }
                }
            }
        }
        // Tracking the pointer for names must not move or enlarge disabled icons.
        for index in 0..<9 {
            let pointer = (CGFloat(index) + 0.5) * step
            let namesOnly = FavoriteMagnificationLayout(count: 9, pointerX: pointer, peakScale: 1)
            precondition(namesOnly.scales.allSatisfy { $0 == 1 })
            precondition(namesOnly.offsets == idle.offsets)
            precondition(FavoriteMagnificationLayout.hoveredItemIndex(
                pointerX: pointer, count: 9, sizeScale: 1,
                separatorIndices: [], excludedIndices: []) == index)
        }
        let reduced = FavoriteMagnificationLayout(count: 9, pointerX: step / 2, peakScale: 1.2)
        let enlarged = FavoriteMagnificationLayout(count: 9, pointerX: step / 2, peakScale: 2.4)
        precondition(abs(reduced.scales[0] - 1.2) < 0.001)
        precondition(abs(enlarged.scales[0] - 2.4) < 0.001)
        precondition(FavoriteMagnificationLayout.headroom(for: 1, peakScale: 2.4)
            > FavoriteMagnificationLayout.headroom(for: 1, peakScale: 1.2))
        for pointer in stride(from: CGFloat.zero, through: 9 * step, by: 4) {
            let layout = FavoriteMagnificationLayout(count: 9, pointerX: pointer, peakScale: 2.4)
            let clearance = FavoriteMagnificationLayout.sideClearance(for: 1)
            for index in 0..<9 {
                let center = (CGFloat(index) + 0.5) * step + layout.offsets[index]
                let radius = FavoriteMagnificationLayout.iconSize * layout.scales[index] / 2
                precondition(center + radius <= 9 * step + clearance)
                precondition(center - radius >= -clearance)
            }
        }
        precondition(FavoriteMagnificationLayout.sideClearance(for: 1) == 108)
        precondition(FavoriteMagnificationLayout.idleSideClearance(for: 1) == 31)
        // Reproduce the installed layout: 13 apps, three folders and Trash
        // exceed the former saved 516-point lane. Following lanes must move.
        let laneBefore = TaskbarFavoriteLaneLayout.contentWidth(appCount: 13, folderCount: 3)
        let laneAfter = TaskbarFavoriteLaneLayout.contentWidth(appCount: 14, folderCount: 3)
        precondition(laneBefore == 18 * step - 28 && laneAfter == 19 * step - 28)
        precondition(laneAfter - laneBefore == FavoriteMagnificationLayout.itemStep,
            "A new favorite must move recent apps and tasks by one complete slot")
        precondition(TaskbarFavoriteLaneLayout.contentWidth(appCount: 12, folderCount: 3)
            == laneBefore - FavoriteMagnificationLayout.itemStep)
        precondition(TaskbarFavoriteLaneLayout.contentWidth(appCount: 0, folderCount: 0,
            showsTrash: false) == 0)
        precondition(TaskbarFavoriteLaneLayout.contentWidth(appCount: 0, folderCount: 1) == 2 * step)
        precondition(TaskbarFavoriteLaneLayout.contentWidth(appCount: 1, folderCount: 0,
            showsTrash: false) == step)
        let safety = FavoriteMagnificationLayout.sideClearance(for: 1)
        let rightEdgePointer = FavoriteMagnificationLayout.clampedPointerX(
            trackingX: 9 * step + 2 * safety,
            count: 9,
            sizeScale: 1
        )
        precondition(rightEdgePointer == 8.5 * step)
        precondition(FavoriteMagnificationLayout(count: 9, pointerX: rightEdgePointer).scales[8]
            == FavoriteMagnificationLayout.maximumScale)
        precondition(idle.scales.allSatisfy { $0 == 1 })
        precondition(idle.offsets.allSatisfy { $0 == 0 })
        precondition(FavoriteShelfReorderTarget.index(source: 2, count: 8,
            translation: step / 2 - 0.1, itemStep: step) == nil)
        precondition(FavoriteShelfReorderTarget.index(source: 2, count: 8,
            translation: step / 2, itemStep: step) == 3)
        precondition(FavoriteShelfReorderTarget.index(source: 2, count: 8,
            translation: 14, itemStep: step, previewIndex: 3) == 3,
            "A small pointer wobble must not retract the preview")
        precondition(FavoriteShelfReorderTarget.index(source: 2, count: 8,
            translation: 12, itemStep: step, previewIndex: 3) == nil)
        precondition(FavoriteShelfReorderTarget.index(source: 2, count: 8,
            translation: 4 * step, itemStep: step) == 6)
        precondition(FavoriteShelfReorderTarget.index(source: 6, count: 8,
            translation: -5 * step, itemStep: step) == 1)
        precondition(FavoriteShelfReorderTarget.index(source: 2, count: 8,
            translation: 1000, itemStep: step) == 7)
        precondition(FavoriteShelfReorderTarget.index(source: 2, count: 8,
            translation: -1000, itemStep: step) == 0)
        precondition(FavoriteShelfReorderTarget.index(source: 2, count: 8,
            translation: 0, itemStep: step) == nil)
        for source in 0..<8 {
            for target in 0..<8 where source != target {
                let translation = CGFloat(target - source) * step
                precondition(FavoriteShelfReorderTarget.index(source: source, count: 8,
                    translation: translation, itemStep: step) == target,
                    "A direct multi-slot move must land in the previewed slot")
                let reversedTarget = min(7, max(0, source - (target - source)))
                precondition(FavoriteShelfReorderTarget.index(source: source, count: 8,
                    translation: -translation, itemStep: step)
                    == (reversedTarget == source ? nil : reversedTarget),
                    "Reversing a move must immediately follow the new pointer")
            }
        }
        let quieter = FavoriteMagnificationLayout(count: 9, pointerX: 4.5 * step,
            peakScale: 1.35)
        precondition(quieter.scales.max()! <= 1.35 && quieter.scales.max()! > 1,
            "Reduced motion keeps hover feedback with a smaller peak")
        precondition(abs(FavoriteMagnificationLayout.maximumScale - 2.0) < 0.001)
        precondition(abs(FavoriteMagnificationLayout.gapGrowthPerScale - 1.25) < 0.001)
        for sizeScale: CGFloat in [0.8, 1, 1.4, 2] {
            for index in 0..<11 where index != 8 {
                let center = ((CGFloat(index) + 0.5) * step - (index > 8 ? 28 : 0)) * sizeScale
                precondition(FavoriteMagnificationLayout.hoveredItemIndex(pointerX: center,
                    count: 11, sizeScale: sizeScale, separatorIndices: [8]) == index,
                    "Name must match compacted App, folder and trash slots")
            }
        }

        let separated = FavoriteMagnificationLayout(
            count: 9, pointerX: 4.5 * step, separatorIndices: [4]
        )
        let separatedIdle = FavoriteMagnificationLayout(
            count: 9, pointerX: nil, separatorIndices: [4]
        )
        for scale: CGFloat in [0.8, 1, 1.4, 2] {
            for pointer: CGFloat? in [nil, 2.5 * step * scale, 6.5 * step * scale] {
                let layout = FavoriteMagnificationLayout(
                    count: 9, pointerX: pointer, sizeScale: scale, separatorIndices: [4])
                for (source, destination) in [(2, 1), (2, 3), (6, 5), (5, 6)] {
                    let previewOffset = layout.reorderPreviewOffset(
                        from: source, to: destination, sizeScale: scale)
                    let previewCenter = layout.visualGeometry(at: source, sizeScale: scale,
                        dragOffset: previewOffset, isNoWindow: true).centerX
                    let committedCenter = layout.visualGeometry(at: destination, sizeScale: scale,
                        dragOffset: 0, isNoWindow: true).centerX
                    precondition(abs(previewCenter - committedCenter) < 0.001,
                        "Neighbor must already occupy its final slot before release")
                }
            }
        }
        precondition(separatedIdle.offsets[3] == 0)
        precondition(separatedIdle.offsets[4] == -14)
        precondition(separatedIdle.offsets[5] == -28)
        let folderCenter = 5.5 * step - 28
        let trackedFolder = FavoriteMagnificationLayout.clampedPointerX(
            trackingX: folderCenter + FavoriteMagnificationLayout.sideClearance(for: 1),
            count: 9, sizeScale: 1, separatorCount: 1
        )
        precondition(trackedFolder == folderCenter)
        precondition(abs(FavoriteMagnificationLayout(
            count: 9, pointerX: trackedFolder, separatorIndices: [4]
        ).scales[5] - FavoriteMagnificationLayout.maximumScale) < 0.001)
        precondition(separated.scales[4] == 1)
        precondition(separated.scales[3] > 1)
        precondition(separated.scales[5] > 1)
        for index in 1..<9 {
            let centerSpacing = step + separated.offsets[index] - separated.offsets[index - 1]
            let previousWidth = index - 1 == 4 ? 1 : 26 * separated.scales[index - 1]
            let currentWidth = index == 4 ? 1 : 26 * separated.scales[index]
            precondition(centerSpacing + 0.001 >= (previousWidth + currentWidth) / 2 + FavoriteShelfSeparator.magnifiedIconGap)
        }
        for pointer in stride(from: CGFloat(2 * step), through: 8 * step, by: 0.25) {
            let left = FavoriteMagnificationLayout(
                count: 9, pointerX: pointer, separatorIndices: [4]
            )
            let right = FavoriteMagnificationLayout(
                count: 9, pointerX: pointer + 0.25, separatorIndices: [4]
            )
            for index in 0..<9 where index != 4 {
                precondition(abs(left.scales[index] - right.scales[index]) < 0.015)
                precondition(abs(left.offsets[index] - right.offsets[index]) < 0.8,
                             "separator transition jumped at \(pointer), item \(index)")
            }
        }

        let centered = FavoriteMagnificationLayout(count: 9, pointerX: 2.5 * step)
        let idleIndicator = idle.visualGeometry(at: 2, sizeScale: 1, dragOffset: 0, isNoWindow: true)
        precondition(idleIndicator.indicatorWidth == FavoriteMagnificationLayout.indicatorDiameter)
        let raisedIndicator = centered.visualGeometry(at: 2, sizeScale: 1, dragOffset: 0, isNoWindow: true)
        let draggedIndicator = centered.visualGeometry(at: 2, sizeScale: 1, dragOffset: 17, isNoWindow: true)
        for translation in stride(from: CGFloat(-48), through: 80, by: 4) {
            let pointer = 2.5 * step + translation
            let moving = FavoriteMagnificationLayout(count: 9, pointerX: pointer)
            let compensatedOffset = translation + centered.offsets[2] - moving.offsets[2]
            let movingCenter = moving.visualGeometry(at: 2, sizeScale: 1,
                dragOffset: compensatedOffset, isNoWindow: true).centerX
            precondition(abs(movingCenter - raisedIndicator.centerX - translation) < 0.001,
                "Dragged icon must track pointer despite changing magnification")
        }
        precondition(raisedIndicator.iconBottomY > idleIndicator.iconBottomY)
        precondition(raisedIndicator.indicatorCenterY > idleIndicator.indicatorCenterY)
        precondition(raisedIndicator.indicatorWidth > idleIndicator.indicatorWidth)
        precondition(abs(raisedIndicator.centerX - draggedIndicator.centerX + 17) < 0.001)
        precondition(abs(raisedIndicator.iconBottomY - raisedIndicator.indicatorCenterY - 2.5) < 0.001)
        precondition(abs(centered.scales[2] - FavoriteMagnificationLayout.maximumScale) < 0.001)
        precondition(centered.scales[1] > centered.scales[0])
        precondition(centered.scales[3] > centered.scales[4])
        precondition(abs(centered.scales[1] - (1 + (0.923 * 2.25 - 1) * 0.8)) < 0.03)
        precondition(abs(centered.scales[0] - (1 + (0.719 * 2.25 - 1) * 0.8)) < 0.05)
        precondition(FavoriteMagnificationLayout(
            count: 9, pointerX: 2.5 * step
        ).scales[7] == 1)
        precondition(abs(centered.scales[1] - centered.scales[3]) < 0.001)
        let magnifiedEdgeGap = step + centered.offsets[3] - centered.offsets[2]
            - 26 * (centered.scales[2] + centered.scales[3]) / 2
        let expectedEdgeGap = gap + FavoriteMagnificationLayout.gapGrowthPerScale
            * (centered.scales[2] + centered.scales[3] - 2) / 2
        precondition(abs(magnifiedEdgeGap - expectedEdgeGap) < 0.001)
        let recording = FavoriteMagnificationLayout(
            count: 8, pointerX: (3.14 + 0.5) * step
        )
        let recordedIconWidths: [CGFloat] = [50, 74, 98, 108, 102, 82, 55, 48]
        for index in recordedIconWidths.indices {
            let reducedScale = 1 + (recordedIconWidths[index] / 48 - 1) * 0.8
            precondition(abs(recording.scales[index] - reducedScale) < 0.035)
        }
        precondition(abs(centered.offsets[2]) < 2,
                     "The smooth anchor must keep the hovered icon within two points: \(centered.offsets[2])")
        for index in 1..<9 {
            let centerSpacing = step + centered.offsets[index] - centered.offsets[index - 1]
            let meanExcess = (centered.scales[index - 1] + centered.scales[index] - 2) / 2
            let minimumSpacing = 26 * (centered.scales[index - 1] + centered.scales[index]) / 2
                + gap + FavoriteMagnificationLayout.gapGrowthPerScale * meanExcess
            precondition(centerSpacing + 0.001 >= minimumSpacing)
        }
        for pointer in stride(from: CGFloat.zero, through: 9 * step, by: 4) {
            let layout = FavoriteMagnificationLayout(count: 9, pointerX: pointer)
            for index in 1..<9 {
                let centerSpacing = step + layout.offsets[index] - layout.offsets[index - 1]
                let meanExcess = (layout.scales[index - 1] + layout.scales[index] - 2) / 2
                let minimumSpacing = 26 * (layout.scales[index - 1] + layout.scales[index]) / 2
                    + gap + FavoriteMagnificationLayout.gapGrowthPerScale * meanExcess
                precondition(centerSpacing + 0.001 >= minimumSpacing)
            }
        }

        let before = FavoriteMagnificationLayout(count: 9, pointerX: 3 * step - 0.1)
        let after = FavoriteMagnificationLayout(count: 9, pointerX: 3 * step + 0.1)
        let maximumBoundaryMovement = zip(before.offsets, after.offsets)
            .map { abs($0 - $1) }.max() ?? 0
        precondition(maximumBoundaryMovement < 0.5,
                     "boundary movement \(maximumBoundaryMovement)")
        let finderAtLeft = FavoriteMagnificationLayout(count: 9, pointerX: 0.5 * step)
        let finderAtMiddle = FavoriteMagnificationLayout(count: 9, pointerX: 3.5 * step)
        let finderAtRight = FavoriteMagnificationLayout(count: 9, pointerX: 8.5 * step)
        precondition(finderAtLeft.offsets[0] > finderAtMiddle.offsets[0])
        precondition(finderAtMiddle.offsets[0] > finderAtRight.offsets[0],
                     "The leading icon can move only while the influence reaches the leading edge")
        for count in [6, 11] {
            for scale: CGFloat in [0.9, 1, 54.0 / 38, 64.0 / 38] {
                for peak: CGFloat in [1.2, 1.5, 2, 2.4] {
                    let reference = FavoriteMagnificationLayout(count: count, pointerX: 4.5 * step * scale,
                        sizeScale: scale, separatorIndices: count == 11 ? [8] : [], peakScale: peak)
                    for pointer in stride(from: 4 * step * scale, through: 6 * step * scale, by: 0.1 * scale) {
                        let current = FavoriteMagnificationLayout(count: count, pointerX: pointer,
                            sizeScale: scale, separatorIndices: count == 11 ? [8] : [], peakScale: peak)
                        precondition(current.scales[0] == 1)
                        precondition(current.offsets[0] == reference.offsets[0],
                            "Icon 1 must remain stationary while crossing slots 5 and 6")
                    }
                }
            }
        }

        for sizeScale in [CGFloat(34.0 / 38), CGFloat(54.0 / 38), CGFloat(64.0 / 38)] {
            let step = FavoriteMagnificationLayout.itemStep * sizeScale
            let icon = 26 * sizeScale
            let rightmostPointer = FavoriteMagnificationLayout.clampedPointerX(
                trackingX: 9 * step + 2 * FavoriteMagnificationLayout.sideClearance(for: sizeScale),
                count: 9,
                sizeScale: sizeScale
            )
            precondition(abs(rightmostPointer - 8.5 * step) < 0.001)
            precondition(abs(FavoriteMagnificationLayout(
                count: 9, pointerX: rightmostPointer, sizeScale: sizeScale
            ).scales[8] - FavoriteMagnificationLayout.maximumScale) < 0.001)
            precondition(FavoriteMagnificationLayout.headroom(for: sizeScale)
                > (30 * (FavoriteMagnificationLayout.maximumScale - 1) + 4.5) * sizeScale)
            let maximumLabelTop = (6 + 4.5 + FavoriteMagnificationLayout.iconSize
                * FavoriteMagnificationLayout.maximumScale + 5
                + FavoriteMagnificationLayout.hoverLabelHeight) * sizeScale
            precondition(38 * sizeScale
                + FavoriteMagnificationLayout.headroom(for: sizeScale) > maximumLabelTop)
            for pointer in stride(from: CGFloat.zero, through: 9 * step, by: step / 8) {
                let layout = FavoriteMagnificationLayout(count: 9, pointerX: pointer, sizeScale: sizeScale)
                let clearance = FavoriteMagnificationLayout.sideClearance(for: sizeScale)
                for index in 0..<9 {
                    let center = (CGFloat(index) + 0.5) * step + layout.offsets[index]
                    let radius = icon * layout.scales[index] / 2
                    precondition(center + radius <= 9 * step + clearance,
                                 "right-edge overflow \(center + radius - 9 * step - clearance) at pointer \(pointer), index \(index)")
                }
                for index in 1..<9 {
                    let centerSpacing = step + layout.offsets[index] - layout.offsets[index - 1]
                    let meanExcess = (layout.scales[index - 1] + layout.scales[index] - 2) / 2
                    let minimumSpacing = icon * (layout.scales[index - 1] + layout.scales[index]) / 2
                        + (gap + FavoriteMagnificationLayout.gapGrowthPerScale * meanExcess) * sizeScale
                    precondition(centerSpacing + 0.001 >= minimumSpacing)
                }
            }
            for count in 1...15 {
                for pointer in stride(from: CGFloat.zero,
                                      through: CGFloat(count) * step,
                                      by: step / 32) {
                    let layout = FavoriteMagnificationLayout(
                        count: count, pointerX: pointer, sizeScale: sizeScale
                    )
                    for index in 0..<count {
                        let geometry = layout.visualGeometry(
                            at: index, sizeScale: sizeScale,
                            dragOffset: 0, isNoWindow: true
                        )
                        let radius = icon * layout.scales[index] / 2
                        let clearance = FavoriteMagnificationLayout.sideClearance(for: sizeScale)
                        precondition(geometry.centerX + radius
                            <= CGFloat(count) * step + clearance,
                                     "right overflow \(geometry.centerX + radius - CGFloat(count) * step - clearance), count \(count), pointer \(pointer), index \(index)")
                    }
                }
            }
        }
        let width: CGFloat = 324
        for pointer in stride(from: CGFloat.zero, through: width * 1.4, by: 7) {
            let layout = FavoriteMagnificationLayout(count: 11, pointerX: pointer,
                sizeScale: 1.4, separatorIndices: [8], peakScale: 2.4)
            let overflow = layout.horizontalOverflow(sizeScale: 1.4, contentWidth: width * 1.4)
            for index in layout.scales.indices {
                let item = layout.visualGeometry(at: index, sizeScale: 1.4, dragOffset: 0, isNoWindow: true)
                let radius = 13 * 1.4 * layout.scales[index]
                precondition(item.centerX - radius >= -overflow.leading)
                precondition(item.centerX + radius <= width * 1.4 + overflow.trailing)
            }
        }
        print("FAVORITE_MAGNIFICATION_OK background-covers-all-icons right-lane-clearance")
    }
}
