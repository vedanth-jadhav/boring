import Foundation

@main struct NotchTabChecks {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() {
        var checks = 0
        for tab in NotchViews.allCases {
            for shelfEnabled in [false, true] {
                for shelfHasItems in [false, true] {
                    for openShelfByDefault in [false, true] {
                        let remembered = tab.nextOpenTab(
                            rememberLastTab: true, shelfEnabled: shelfEnabled,
                            shelfHasItems: shelfHasItems, openShelfByDefault: openShelfByDefault
                        )
                        expect(remembered == (tab == .shelf && !shelfEnabled ? .home : tab),
                               "Remember last tab must win over the Shelf default")
                        let defaultTab = tab.nextOpenTab(
                            rememberLastTab: false, shelfEnabled: shelfEnabled,
                            shelfHasItems: shelfHasItems, openShelfByDefault: openShelfByDefault
                        )
                        expect(defaultTab == (shelfEnabled && shelfHasItems && openShelfByDefault ? .shelf : .home),
                               "With remembering off, only an enabled, populated Shelf can be the default")
                        checks += 2
                    }
                }
                expect(NotchViews.restored(savedTab: tab.rawValue, rememberLastTab: true, shelfEnabled: shelfEnabled)
                       == (tab == .shelf && !shelfEnabled ? .home : tab), "Restore the saved tab after relaunch")
                expect(NotchViews.restored(savedTab: tab.rawValue, rememberLastTab: false, shelfEnabled: shelfEnabled)
                       == .home, "Ignore the saved tab when remembering is off")
                checks += 2
            }
        }
        for savedTab in ["", "unknown", "Home"] {
            expect(NotchViews.restored(savedTab: savedTab, rememberLastTab: true, shelfEnabled: true)
                   == .home, "Invalid saved tabs must safely fall back to Home")
            checks += 1
        }
        print("\(checks) notch tab regression checks passed")
    }
}
