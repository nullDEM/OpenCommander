import Foundation
import Testing
@testable import OpenCommanderCore

struct PanelVisibilityTests {
    @Test func bothPanelsAreVisibleByDefault() {
        let v = PanelVisibility()
        #expect(v.isVisible(.left))
        #expect(v.isVisible(.right))
        #expect(v.isSinglePanel == false)
        #expect(v.canToggle(.left))
        #expect(v.canToggle(.right))
    }

    @Test(arguments: PanelSide.allCases)
    func hidingOnePanelKeepsTheOtherVisible(side: PanelSide) {
        var v = PanelVisibility()
        let result = v.setVisible(false, side: side)
        #expect(result)
        #expect(v.isVisible(side) == false)
        #expect(v.isVisible(side.other))
        #expect(v.isSinglePanel)
        #expect(v.hidden == side)
    }

    @Test(arguments: PanelSide.allCases)
    func theSecondPanelCannotBeHiddenWhenOneIsAlreadyHidden(side: PanelSide) {
        var v = PanelVisibility(hidden: side)
        #expect(v.canToggle(side), "ukryty panel można pokazać")
        #expect(v.canToggle(side.other) == false, "drugiego nie wolno ukryć — któryś panel musi zostać")
        let result = v.setVisible(false, side: side.other)
        #expect(result == false)
        #expect(v.hidden == side, "odrzucona zmiana nie zmienia stanu")
    }

    @Test(arguments: PanelSide.allCases)
    func showingTheHiddenPanelRestoresBoth(side: PanelSide) {
        var v = PanelVisibility(hidden: side)
        let result = v.setVisible(true, side: side)
        #expect(result)
        #expect(v.hidden == nil)
        #expect(v == PanelVisibility())
    }

    @Test func repeatedRequestsAreHarmless() {
        var v = PanelVisibility()
        var result = v.setVisible(true, side: .left)
        #expect(result)
        #expect(v.hidden == nil)
        v.setVisible(false, side: .left)
        result = v.setVisible(false, side: .left)
        #expect(result)
        #expect(v.hidden == .left)
        result = v.setVisible(true, side: .right)
        #expect(result, "pokazanie widocznego panelu nic nie zmienia")
        #expect(v.hidden == .left)
    }

    @Test func activePanelMovesAwayFromAHiddenOne() {
        let hiddenLeft = PanelVisibility(hidden: .left)
        #expect(hiddenLeft.resolvedActive(.left) == .right)
        #expect(hiddenLeft.resolvedActive(.right) == .right)
        let hiddenRight = PanelVisibility(hidden: .right)
        #expect(hiddenRight.resolvedActive(.right) == .left)
        #expect(hiddenRight.resolvedActive(.left) == .left)
        #expect(PanelVisibility().resolvedActive(.right) == .right)
    }

    @Test func externalTargetsFallBackToTheVisiblePanel() {
        #expect(PanelVisibility().visibleSide(preferring: .right) == .right)
        #expect(PanelVisibility(hidden: .right).visibleSide(preferring: .right) == .left)
        #expect(PanelVisibility(hidden: .left).visibleSide(preferring: .right) == .right)
    }
}

struct HiddenPanelSettingsTests {
    @Test(arguments: [PanelSide?.none, .left, .right])
    func hiddenPanelSurvivesEncodingRoundTrip(hidden: PanelSide?) throws {
        var settings = AppSettings.defaults
        settings.hiddenPanel = hidden
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.hiddenPanel == hidden)
    }

    @Test func settingsWithoutTheFieldMeanBothPanelsVisible() throws {
        // Ustawienia sprzed tej funkcji: kodujemy bieżące, usuwamy pole i wczytujemy jak stary zapis.
        let data = try JSONEncoder().encode(AppSettings.defaults)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "hiddenPanel")
        let old = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(decoded.hiddenPanel == nil)
    }
}
