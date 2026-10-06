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
    func searchableInPlace(
        text: Binding<String>,
        prompt: Text,
        isFocused: FocusState<Bool>.Binding? = nil,
        onSubmit: (() -> Void)? = nil
    ) -> some View {
        #if os(iOS)
        appSearchable(
            text: text,
            prompt: prompt,
            placement: .navigationBarDrawer(displayMode: .automatic),
            isFocused: isFocused,
            onSubmit: onSubmit
        )
        #else
        appSearchable(text: text, prompt: prompt, isFocused: isFocused, onSubmit: onSubmit)
        #endif
    }

    /// `searchable`, everywhere except an iPad app running on a Mac.
    ///
    /// There the system's search cannot be used at all. On macOS 27 opening it
    /// ends the app: laying out its presentation asks `UIScreen` for the main
    /// scene's size, and an iPad app on a Mac has none to give, so UIKit throws
    /// "Accessing the focus system through UIScreen is no longer supported."
    /// Placing it in the toolbar, or keeping the bar on screen while it is
    /// open, goes the same way. A plain field above the content does instead.
    @ViewBuilder
    func appSearchable(
        text: Binding<String>,
        prompt: Text? = nil,
        placement: SearchFieldPlacement = .automatic,
        isFocused: FocusState<Bool>.Binding? = nil,
        onSubmit: (() -> Void)? = nil
    ) -> some View {
        if InlineSearchField.isNeeded {
            safeAreaInset(edge: .top, spacing: 0) {
                InlineSearchField(text: text, prompt: prompt, isFocused: isFocused, onSubmit: onSubmit)
            }
        } else if let isFocused {
            searchable(text: text, placement: placement, prompt: prompt)
                .searchFocused(isFocused)
                .onSubmit(of: .search) { onSubmit?() }
        } else {
            searchable(text: text, placement: placement, prompt: prompt)
                .onSubmit(of: .search) { onSubmit?() }
        }
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

    /// Lets a drag near the screen's edge reach the view before the system's
    /// own edge swipes take it, where there are any.
    @ViewBuilder
    func deferringSystemGestures() -> some View {
        #if os(iOS)
        defersSystemGestures(on: .all)
        #else
        self
        #endif
    }

    /// The shape a long-press menu lifts, where the menu lifts anything.
    @ViewBuilder
    func contextMenuPreviewShape(_ shape: some Shape) -> some View {
        #if os(iOS)
        contentShape(.contextMenuPreview, shape)
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
