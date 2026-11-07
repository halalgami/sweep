import Foundation
import Testing
@testable import SweepCore

@Suite struct SettingsStoreTests {
    @Test func usesStandardDefaultsInsideTheAppBundle() {
        #expect(SettingsStore.usesStandardDomain(mainBundleID: "dev.algamthe.sweep"))
        #expect(!SettingsStore.usesStandardDomain(mainBundleID: nil))          // CLI / swift run
        #expect(!SettingsStore.usesStandardDomain(mainBundleID: "com.apple.dt.xctest.tool"))
    }
}
