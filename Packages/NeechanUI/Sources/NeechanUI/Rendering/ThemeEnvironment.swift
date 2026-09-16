import NeechanCore
import SwiftUI

extension EnvironmentValues {
    /// The colour scheme the reader picked.
    ///
    /// Put in the environment by the shell so any view can colour itself
    /// without reaching back through the services for it.
    @Entry public var neechanTheme: NeechanTheme = .builtIn
}
