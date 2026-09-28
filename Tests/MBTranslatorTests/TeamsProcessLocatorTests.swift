import Testing
@testable import MBTranslator

@Suite("TeamsProcessLocator")
struct TeamsProcessLocatorTests {
    @Test("matches new Teams, classic Teams and their helper processes")
    func matchesTeamsFamily() {
        #expect(TeamsProcessLocator.isTeamsBundleID("com.microsoft.teams2"))
        #expect(TeamsProcessLocator.isTeamsBundleID("com.microsoft.teams"))
        #expect(TeamsProcessLocator.isTeamsBundleID("com.microsoft.teams2.modulehost"))
        #expect(TeamsProcessLocator.isTeamsBundleID("COM.Microsoft.Teams2"))
    }

    @Test("does not match other apps")
    func rejectsOthers() {
        #expect(!TeamsProcessLocator.isTeamsBundleID("us.zoom.xos"))
        #expect(!TeamsProcessLocator.isTeamsBundleID("com.microsoft.Word"))
        #expect(!TeamsProcessLocator.isTeamsBundleID("pl.mbgroup.translator"))
        #expect(!TeamsProcessLocator.isTeamsBundleID(""))
    }
}
