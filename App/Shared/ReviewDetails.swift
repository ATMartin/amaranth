import SwiftUI
import Presentation

extension EnvironmentValues {
    /// Mirrors the persisted `ReviewPreferences.showDetailsKey`; MainView injects it, panes read it.
    @Entry var showDetails = ReviewPreferences.showDetailsDefault
}
