import SwiftUI

// The package builds for macOS as well as iOS so that its pure logic (the post
// renderer, the link scheme) can be unit-tested with `swift test`, without
// booting a simulator. These shims keep that possible without scattering
// conditional compilation through the views. The app itself only ships on iOS.

extension View {
    /// `navigationBarTitleDisplayMode(.inline)` where that exists.
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// A search field docked under the navigation bar, where that placement
    /// exists. Keeps the field visible with the content rather than pushing a
    /// separate screen.
    @ViewBuilder
    func searchableInPlace(text: Binding<String>, prompt: Text) -> some View {
        #if os(iOS)
        searchable(
            text: text,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: prompt
        )
        #else
        searchable(text: text, prompt: prompt)
        #endif
    }

    /// Turns off automatic capitalisation where that setting exists.
    @ViewBuilder
    func noAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// Hides the tab bar where there is one.
    @ViewBuilder
    func hidesTabBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .tabBar)
        #else
        self
        #endif
    }

    /// Hides the status bar where there is one.
    @ViewBuilder
    func hidesStatusBar(_ hidden: Bool) -> some View {
        #if os(iOS)
        statusBarHidden(hidden)
        #else
        self
        #endif
    }

    /// The grouped list appearance used across the app's settings-like screens.
    @ViewBuilder
    func groupedListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.sidebar)
        #endif
    }
}

extension View {
    /// A cover that fills the screen where that exists, and a sheet elsewhere.
    @ViewBuilder
    func fullScreenCoverCompat<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item, content: content)
        #endif
    }
}

extension ToolbarItemPlacement {
    /// Trailing side of the navigation bar.
    static var trailingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .automatic
        #endif
    }

    /// The large title's own row, beside the title rather than in the bar above
    /// it.
    ///
    /// An item here rides the large title: level with it while the title is
    /// expanded, and away with it once the list is scrolled and the title
    /// collapses into the bar.
    static var largeTitleBar: ToolbarItemPlacement {
        #if os(iOS)
        .largeTitle
        #else
        .automatic
        #endif
    }
}
