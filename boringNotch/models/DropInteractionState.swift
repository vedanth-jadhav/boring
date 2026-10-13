//
//  DropInteractionState.swift
//  boringNotch
//

import Observation

@Observable
final class DropInteractionState {
    var dragDetectorTargeting = false
    var shelfDropTargeting = false
    var generalDropTargeting = false
    var dropZoneTargeting = false
    var dropEvent = false

    var anyDropZoneTargeting: Bool {
        dragDetectorTargeting || shelfDropTargeting || generalDropTargeting || dropZoneTargeting
    }
}
