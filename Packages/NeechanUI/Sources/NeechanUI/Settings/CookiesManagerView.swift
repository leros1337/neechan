import NeechanCore
import SwiftUI

/// Lists the cookies the site has set, and lets the reader drop them.
///
/// Useful when a session goes wrong: the Cloudflare clearance and the age
/// confirmation are both cookies, and deleting one is the usual fix.
struct CookiesManagerView: View {
    @Environment(AppServices.self) private var services

    @State private var cookies: [CookieRecord] = []
    @State private var isConfirmingClear = false

    var body: some View {
        List {
            if cookies.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No cookies", bundle: .module)
                    } icon: {
                        Image(systemName: "checkmark.shield")
                    }
                } description: {
                    Text("Nothing has been stored for this mirror yet.", bundle: .module)
                }
            }

            ForEach(cookies) { cookie in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(cookie.name)
                            .font(.body.monospaced())
                        if cookie.isSignificant {
                            Spacer()
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text("Part of your session", bundle: .module))
                        }
                    }
                    Text(cookie.value)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(cookie.domain)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        Task { await remove(cookie) }
                    } label: {
                        Label {
                            Text("Delete", bundle: .module)
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
        .groupedListStyle()
        .navigationTitle(Text("Cookies", bundle: .module))
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .trailingBar) {
                Button(role: .destructive) {
                    isConfirmingClear = true
                } label: {
                    Label {
                        Text("Clear all", bundle: .module)
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
                .disabled(cookies.isEmpty)
            }
        }
        .confirmationDialog(
            Text("Delete every cookie?", bundle: .module),
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task {
                    await services.cookies.removeAll(for: nil)
                    await reload()
                }
            } label: {
                Text("Delete", bundle: .module)
            }
        } message: {
            Text("You will be signed out of your passcode and asked your age again.", bundle: .module)
        }
        .task { await reload() }
    }

    private func reload() async {
        cookies = await services.cookies.cookies()
    }

    private func remove(_ cookie: CookieRecord) async {
        await services.cookies.remove(name: cookie.name, domain: cookie.domain)
        await reload()
    }
}
