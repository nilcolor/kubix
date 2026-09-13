// Bridge architecture adapted from thdxg/macterm (MIT).
// Copyright (c) 2026 Macterm. See Resources/ThirdPartyNotices.txt.

import Foundation
import KubixCore

enum GhosttyResources {
    static func configure(bundle: Bundle = .main) throws {
        guard let resources = bundle.resourceURL else { throw TerminalResourcePaths.ResourceError.missingResources }
        let paths = try TerminalResourcePaths(bundleResources: resources) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        // Ghostty itself derives TERMINFO from this directory's sibling. Do not override TERMINFO.
        guard setenv("GHOSTTY_RESOURCES_DIR", paths.ghostty.path, 1) == 0 else {
            throw TerminalResourcePaths.ResourceError.missingResources
        }
    }
}
