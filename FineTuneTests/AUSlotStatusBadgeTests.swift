// FineTuneTests/AUSlotStatusBadgeTests.swift
// T1: every AppAUChain.FailureReason must map to its pinned badge text —
// `.missing` reads "Not installed", every other reason reads "Couldn't load"
// with the specific reason in a tooltip. Pure logic — no audio, no views.

import Testing
@testable import FineTune

@Suite("AUSlotStatus — failure badge mapping")
struct AUSlotStatusBadgeTests {

    @Test(
        "Every FailureReason maps to its pinned badge text",
        arguments: [
            (AppAUChain.FailureReason.missing, "Not installed"),
            (.formatRefused, "Couldn't load"),
            (.stateRestore, "Couldn't load"),
            (.allocFailed, "Couldn't load"),
            (.hung, "Couldn't load")
        ]
    )
    func failureReasonBadgeText(reason: AppAUChain.FailureReason, expectedText: String) {
        let status = AUSlotStatus.forFailure(reason)
        #expect(status.badgeCopy?.text == expectedText)
    }

    @Test("Only .missing produces the .missing status; every other reason produces .couldNotLoad")
    func failureReasonBadgeStatus() {
        #expect(AUSlotStatus.forFailure(.missing) == .missing)
        #expect(AUSlotStatus.forFailure(.formatRefused) == .couldNotLoad(.formatRefused))
        #expect(AUSlotStatus.forFailure(.stateRestore) == .couldNotLoad(.stateRestore))
        #expect(AUSlotStatus.forFailure(.allocFailed) == .couldNotLoad(.allocFailed))
        #expect(AUSlotStatus.forFailure(.hung) == .couldNotLoad(.hung))
    }

    @Test(
        "Every non-missing reason gets a distinct, non-empty tooltip",
        arguments: [
            AppAUChain.FailureReason.formatRefused,
            .stateRestore,
            .allocFailed,
            .hung
        ]
    )
    func couldNotLoadTooltipIsPresent(reason: AppAUChain.FailureReason) {
        let tooltip = AUSlotStatus.couldNotLoad(reason).badgeTooltip
        #expect(tooltip != nil)
        #expect(!(tooltip ?? "").isEmpty)
    }

    @Test("Tooltips are distinct per reason — no reason silently shares another's copy")
    func tooltipsAreDistinct() {
        let reasons: [AppAUChain.FailureReason] = [.formatRefused, .stateRestore, .allocFailed, .hung]
        let tooltips = reasons.compactMap { AUSlotStatus.couldNotLoad($0).badgeTooltip }
        #expect(Set(tooltips).count == reasons.count)
    }

    @Test("The .missing status has no tooltip — its badge text already says it all")
    func missingHasNoTooltip() {
        #expect(AUSlotStatus.missing.badgeTooltip == nil)
    }
}
