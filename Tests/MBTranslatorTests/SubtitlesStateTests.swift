import Testing
@testable import MBTranslator

@Suite("SubtitlesState")
@MainActor
struct SubtitlesStateTests {
    @Test("sourcePartial updates the live PL line")
    func sourcePartialUpdates() {
        let state = SubtitlesState()
        state.apply(.sourcePartial("Jadę"))
        #expect(state.sourcePartial == "Jadę")
        #expect(state.sourceFinal.isEmpty)
    }

    @Test("sourceFinal replaces sourceFinal and clears the now-stale partial")
    func sourceFinalClearsPartial() {
        let state = SubtitlesState()
        state.apply(.sourcePartial("Jadę zar"))
        state.apply(.sourceFinal("Jadę zaraz do Konina."))

        #expect(state.sourceFinal == "Jadę zaraz do Konina.")
        #expect(state.sourcePartial.isEmpty)
    }

    @Test("translationPartial is ignored — only translationFinal is tracked")
    func translationPartialIgnored() {
        let state = SubtitlesState()
        state.apply(.translationPartial("I'm go"))
        #expect(state.translationFinal.isEmpty)
    }

    @Test("translationFinal updates the EN line")
    func translationFinalUpdates() {
        let state = SubtitlesState()
        state.apply(.translationFinal("I'm going to Konin right away."))
        #expect(state.translationFinal == "I'm going to Konin right away.")
    }

    @Test("reset clears all three lines")
    func resetClearsEverything() {
        let state = SubtitlesState()
        state.apply(.sourcePartial("Jadę"))
        state.apply(.sourceFinal("Jadę zaraz do Konina."))
        state.apply(.translationFinal("I'm going to Konin right away."))

        state.reset()

        #expect(state.sourcePartial.isEmpty)
        #expect(state.sourceFinal.isEmpty)
        #expect(state.translationFinal.isEmpty)
    }
}

@Suite("SubtitlesState — incoming side (M4)")
@MainActor
struct SubtitlesStateIncomingTests {
    @Test("incoming events fill the right side and leave the outgoing side untouched")
    func incomingIsIndependent() {
        let state = SubtitlesState()
        state.apply(.sourceFinal("Cześć."))
        state.applyIncoming(.sourcePartial("Hel"))
        state.applyIncoming(.sourceFinal("Hello there."))
        state.applyIncoming(.translationFinal("Witaj."))

        #expect(state.incoming.sourceFinal == "Hello there.")
        #expect(state.incoming.sourcePartial.isEmpty)
        #expect(state.incoming.translationFinal == "Witaj.")
        #expect(state.sourceFinal == "Cześć.")
        #expect(state.translationFinal.isEmpty)
    }

    @Test("resetOutgoing keeps the incoming side, resetIncoming keeps the outgoing side")
    func sidesResetIndependently() {
        let state = SubtitlesState()
        state.apply(.translationFinal("Hi."))
        state.applyIncoming(.translationFinal("Witaj."))

        state.resetOutgoing()
        #expect(state.translationFinal.isEmpty)
        #expect(state.incoming.translationFinal == "Witaj.")

        state.apply(.translationFinal("Hi."))
        state.resetIncoming()
        #expect(state.incoming.translationFinal.isEmpty)
        #expect(state.translationFinal == "Hi.")
    }
}
