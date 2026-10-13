import Foundation
import WorkbenchCore

func checkAppVersionCheck() {
    // Tag picking: highest semantic version wins; junk and non-semver names drop.
    // Pre-release suffixes compare as their release (the repo only tags releases).
    expectEqual(AppVersionCheck.latestTag(["v0.1.0", "v0.2.0", "nightly", "v0.10.0-beta"]), "0.10.0")
    expectEqual(AppVersionCheck.latestTag(["0.1", "0.1.5", "v0.1.9"]), "0.1.9")
    precondition(AppVersionCheck.latestTag(["nightly", "latest"]) == nil)
    // Three-component numeric compare, missing parts read as zero.
    precondition(AppVersionCheck.compare("0.1.0", "0.1.0") == .orderedSame)
    precondition(AppVersionCheck.compare("0.1.0", "v0.2") == .orderedAscending)
    precondition(AppVersionCheck.compare("1.0.0", "v0.9.9") == .orderedDescending)
    precondition(AppVersionCheck.compare("0.2", "0.2.0") == .orderedSame)
    print("PASS: app version check — tag picking, suffix stripping, numeric compare")
}
