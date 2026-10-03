//
//  ApplicationRelauncher.swift
//  boringNotch
//
//  Created by Corentin132 on 03/10/2025.
//

import AppKit

@MainActor
enum ApplicationRelauncher {
    static func restart(at appURL: URL? = nil) {
        let workspace = NSWorkspace.shared
        // Launch Services can resolve the same identifier to a stale copy in
        // ~/Applications or a build directory. Restart the actual running app.
        let applicationURL = appURL ?? Bundle.main.bundleURL

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        workspace.openApplication(at: applicationURL, configuration: configuration, completionHandler: nil)

        NSApplication.shared.terminate(nil)
    }
}
