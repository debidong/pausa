import XCTest
@testable import Pausa
@testable import PausaCore

final class SettingsAndDefaultsTests: XCTestCase {
    override func tearDown() {
        Settings.dryRun = false
        PausaDefaults.resetDryRunStore()
        super.tearDown()
    }

    func testIsolatedDefaultsRoundTripAndClamping() {
        let (ud, suite) = PausaDefaults.makeIsolated()
        defer { ud.removePersistentDomain(forName: suite) }

        let s = Settings(defaults: ud)
        XCTAssertEqual(s.shortEveryMin, 20)
        XCTAssertEqual(s.shortsBeforeLong, Settings.recommendedCount)
        XCTAssertTrue(s.pauseForMeetings)

        s.shortEveryMin = 30
        s.shortsBeforeLong = 5   // exceeds 90-minute hard line for 30 min -> clamped to 2 (30 * 3 = 90)
        s.pauseForMeetings = false
        s.language = .en
        s.customPauseApps = [CustomPauseApp(bundleID: "com.apple.dt.Xcode", mode: .foreground)]

        let reloaded = Settings(defaults: ud)
        XCTAssertEqual(reloaded.shortEveryMin, 30)
        XCTAssertEqual(reloaded.shortsBeforeLong, 2)
        XCTAssertFalse(reloaded.pauseForMeetings)
        XCTAssertEqual(reloaded.language, .en)
        XCTAssertEqual(reloaded.customPauseApps, [CustomPauseApp(bundleID: "com.apple.dt.Xcode", mode: .foreground)])
    }

    func testLegacyLongEveryMigration() {
        let (ud, suite) = PausaDefaults.makeIsolated()
        defer { ud.removePersistentDomain(forName: suite) }

        ud.set(20.0, forKey: DefaultsKey.shortEveryMin)
        ud.set(50.0, forKey: DefaultsKey.legacyLongEveryMin)
        let migrated = Settings(defaults: ud)
        XCTAssertEqual(migrated.shortsBeforeLong, 2)   // nth = 3 -> 2 shorts before long
        XCTAssertNil(ud.object(forKey: DefaultsKey.legacyLongEveryMin))
        XCTAssertEqual(ud.integer(forKey: DefaultsKey.shortsBeforeLong), 2)

        // Second launch after legacy key removal must still retain the migrated rhythm.
        let secondLaunch = Settings(defaults: ud)
        XCTAssertEqual(secondLaunch.shortsBeforeLong, 2)
    }

    func testDryRunNeverWritesToStandardUserDefaults() {
        let probeKey = DefaultsKey.pauseForMeetings
        let sentinelApp = CustomPauseApp(bundleID: "com.example.dryrun.probe", mode: .running)
        let standardBeforeMeetings = UserDefaults.standard.object(forKey: probeKey) as? Bool
        let standardBeforeApps = UserDefaults.standard.data(forKey: DefaultsKey.customPauseApps)
        let standardBeforeLang = UserDefaults.standard.string(forKey: DefaultsKey.language)

        Settings.dryRun = true
        PausaDefaults.resetDryRunStore()

        let s = Settings()
        s.shortEveryMin = 45
        s.pauseForMeetings = !(standardBeforeMeetings ?? true)
        s.language = .th
        s.customPauseApps = [sentinelApp]

        // Mutated values live inside the ephemeral dry-run domain...
        XCTAssertEqual(PausaDefaults.store.double(forKey: DefaultsKey.shortEveryMin), 45)
        XCTAssertEqual(PausaDefaults.store.string(forKey: DefaultsKey.language), AppLanguage.th.rawValue)

        // ...while UserDefaults.standard is completely untouched.
        XCTAssertEqual(UserDefaults.standard.object(forKey: probeKey) as? Bool, standardBeforeMeetings)
        XCTAssertEqual(UserDefaults.standard.data(forKey: DefaultsKey.customPauseApps), standardBeforeApps)
        XCTAssertEqual(UserDefaults.standard.string(forKey: DefaultsKey.language), standardBeforeLang)
    }

    func testSystemClockSeparatesMonotonicAndUptime() {
        let clock = PausaClock.system
        let c1 = clock.continuousNow()
        let u1 = clock.uptimeNow()
        let w1 = clock.wallNow()
        XCTAssertGreaterThan(c1, 0)
        XCTAssertGreaterThan(u1, 0)
        XCTAssertGreaterThanOrEqual(clock.continuousNow(), c1)
        XCTAssertGreaterThanOrEqual(clock.uptimeNow(), u1)
        XCTAssertGreaterThanOrEqual(clock.wallNow().timeIntervalSince(w1), -0.01)
    }
}
