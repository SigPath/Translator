import Foundation
import Testing
@testable import MBTranslator

@Suite("CaptureSource matching")
struct CaptureSourceTests {
    @Test("Teams: matches new Teams, classic Teams and their helper processes")
    func teamsMatchesFamily() {
        #expect(CaptureSource.teams.matches(bundleID: "com.microsoft.teams2"))
        #expect(CaptureSource.teams.matches(bundleID: "com.microsoft.teams"))
        #expect(CaptureSource.teams.matches(bundleID: "com.microsoft.teams2.modulehost"))
        #expect(CaptureSource.teams.matches(bundleID: "COM.Microsoft.Teams2"))
    }

    @Test("Teams: does not match other apps, including browsers")
    func teamsRejectsOthers() {
        #expect(!CaptureSource.teams.matches(bundleID: "us.zoom.xos"))
        #expect(!CaptureSource.teams.matches(bundleID: "com.microsoft.Word"))
        #expect(!CaptureSource.teams.matches(bundleID: "com.google.Chrome"))
        #expect(!CaptureSource.teams.matches(bundleID: "pl.mbgroup.translator"))
        #expect(!CaptureSource.teams.matches(bundleID: ""))
    }

    @Test("Browser: matches common browsers and their helper processes")
    func browserMatches() {
        for id in [
            "com.google.Chrome", "com.google.Chrome.helper.Renderer", "com.apple.Safari",
            "com.apple.WebKit.GPU", "company.thebrowser.Browser", "com.microsoft.edgemac",
            "org.mozilla.firefox", "com.brave.Browser", "com.vivaldi.Vivaldi",
            "com.operasoftware.Opera",
        ] {
            #expect(CaptureSource.browser.matches(bundleID: id), "\(id) should match")
        }
    }

    @Test("Browser: does not match Teams or this app")
    func browserRejectsOthers() {
        #expect(!CaptureSource.browser.matches(bundleID: "com.microsoft.teams2"))
        #expect(!CaptureSource.browser.matches(bundleID: "pl.mbgroup.translator"))
        #expect(!CaptureSource.browser.matches(bundleID: ""))
    }
}

@Suite("AudioSettingsStore.captureSource")
struct CaptureSourceStoreTests {
    private func makeStore() -> AudioSettingsStore {
        let defaults = UserDefaults(suiteName: "pl.mbgroup.translator.tests.\(UUID().uuidString)")!
        return AudioSettingsStore(defaults: defaults)
    }

    @Test("defaults to Teams")
    func defaultsToTeams() {
        #expect(makeStore().captureSource == .teams)
    }

    @Test("persists the chosen source")
    func persists() {
        let store = makeStore()
        store.captureSource = .browser
        #expect(store.captureSource == .browser)
        store.captureSource = .teams
        #expect(store.captureSource == .teams)
    }
}
