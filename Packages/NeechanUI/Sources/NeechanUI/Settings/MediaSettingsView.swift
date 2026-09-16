import NeechanAPI
import NeechanCore
import NeechanMedia
import NeechanSettings
import SwiftUI

/// Thumbnails, video behaviour, downloads, and the disk they use.
struct MediaSettingsView: View {
    @Environment(AppServices.self) private var services

    @State private var cacheBytes = 0
    @State private var isPickingFolder = false
    @State private var folderMessage: AlertMessage?
    @State private var savedThreadBytes = 0

    private var cacheChoices: [Int] { AppSettings.cacheLimitChoicesMegabytes }
    private var ageChoices: [Int] { AppSettings.cacheAgeChoicesDays }

    var body: some View {
        @Bindable var settings = services.settings

        Form {
            Section {
                Picker(selection: $settings.mediaLoadPolicy) {
                    Text("Always", bundle: .module).tag(MediaLoadPolicy.always)
                    Text("Only on Wi-Fi", bundle: .module).tag(MediaLoadPolicy.wifiOnly)
                    Text("Never", bundle: .module).tag(MediaLoadPolicy.never)
                } label: {
                    Text("Load images", bundle: .module)
                }
            } header: {
                Text("Images", bundle: .module)
            } footer: {
                Text("Never still lets you open an image by tapping its placeholder.", bundle: .module)
            }

            Section {
                Toggle(isOn: $settings.videoAutoplay) {
                    Text("Play when opened", bundle: .module)
                }
                Toggle(isOn: $settings.videoLoops) {
                    Text("Repeat when finished", bundle: .module)
                }
            } header: {
                Text("Video", bundle: .module)
            }

            Section {
                Toggle(isOn: $settings.appendsUniqueHashByDefault) {
                    Text("Make files unique", bundle: .module)
                }
                Toggle(isOn: $settings.stripsMetadataByDefault) {
                    Text("Remove metadata", bundle: .module)
                }
                Toggle(isOn: $settings.removesFileNamesByDefault) {
                    Text("Random file names", bundle: .module)
                }
            } header: {
                Text("Uploads", bundle: .module)
            } footer: {
                Text(
                    "Applied to everything you attach. Photos lose their location and camera data; video keeps its own tags, which need the file to be rebuilt to remove.",
                    bundle: .module
                )
            }

            Section {
                Toggle(isOn: $settings.convertsWebMOnSave) {
                    Text("Convert WebM to MP4", bundle: .module)
                }
                .accessibilityIdentifier("convert-webm")

                Toggle(isOn: $settings.savesToPhotos) {
                    Text("Save to Photos", bundle: .module)
                }
                if !settings.savesToPhotos {
                    Button {
                        isPickingFolder = true
                    } label: {
                        Label {
                            Text(
                                services.settings.downloadFolderBookmark == nil
                                    ? "Choose a folder"
                                    : "Change folder",
                                bundle: .module
                            )
                        } icon: {
                            Image(systemName: "folder")
                        }
                    }
                }
                Picker(selection: $settings.downloadConflictAction) {
                    Text("Ask", bundle: .module).tag(DownloadConflictAction.ask)
                    Text("Keep both", bundle: .module).tag(DownloadConflictAction.keepBoth)
                    Text("Replace", bundle: .module).tag(DownloadConflictAction.replace)
                    Text("Skip", bundle: .module).tag(DownloadConflictAction.skip)
                } label: {
                    Text("If the name is taken", bundle: .module)
                }
                TextField(text: $settings.downloadSubdirectoryPattern) {
                    Text("Folders", bundle: .module)
                }
                .noAutocapitalization()
                .autocorrectionDisabled()
            } header: {
                Text("Downloads", bundle: .module)
            } footer: {
                if services.settings.savesToPhotos {
                    Text(
                        "WebM plays in this app but nowhere else on the phone: Photos will not accept one at all. Converting re-encodes the video, which takes a moment and loses a little quality.",
                        bundle: .module
                    )
                    Text("Files go to your photo library.", bundle: .module)
                } else if services.settings.downloadFolderBookmark == nil {
                    Text("Choose a folder before saving, or files go to Photos.", bundle: .module)
                } else {
                    Text("Folders can use <board>, <thread> and <title>.", bundle: .module)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent {
                        Text(byteCount(settings.mediaCacheLimitMegabytes * 1024 * 1024))
                            .monospacedDigit()
                    } label: {
                        Text("Limit", bundle: .module)
                    }

                    // Dragged rather than picked from a list: there are only
                    // four sizes and they are far apart, so the slider shows
                    // where this one sits between them at a glance.
                    Slider(
                        value: cacheLimitBinding,
                        in: 0...Double(max(1, cacheChoices.count - 1)),
                        step: 1
                    ) {
                        Text("Limit", bundle: .module)
                    } minimumValueLabel: {
                        Text(byteCount((cacheChoices.first ?? 0) * 1024 * 1024))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text(byteCount((cacheChoices.last ?? 0) * 1024 * 1024))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("cache-limit")
                    .accessibilityValue(
                        Text(byteCount(settings.mediaCacheLimitMegabytes * 1024 * 1024))
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent {
                        ageLabel(settings.mediaCacheMaxAgeDays).monospacedDigit()
                    } label: {
                        Text("Keep for", bundle: .module)
                    }

                    // Counted from when a file was last opened, not from when it
                    // arrived: a clip watched again this morning is not old
                    // because it was fetched last month.
                    Slider(
                        value: cacheAgeBinding,
                        in: 0...Double(max(1, ageChoices.count - 1)),
                        step: 1
                    ) {
                        Text("Keep for", bundle: .module)
                    } minimumValueLabel: {
                        ageLabel(ageChoices.first ?? 1)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        ageLabel(ageChoices.last ?? 0)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("cache-age")
                    .accessibilityValue(ageLabel(settings.mediaCacheMaxAgeDays))
                }

                LabeledContent {
                    Text(byteCount(cacheBytes))
                        .monospacedDigit()
                } label: {
                    Text("Images and video", bundle: .module)
                }

                LabeledContent {
                    Text(byteCount(savedThreadBytes))
                        .monospacedDigit()
                } label: {
                    Text("Saved threads", bundle: .module)
                }

                Button(role: .destructive) {
                    Task {
                        await MediaCache.shared.removeAll()
                        await refreshSizes()
                    }
                } label: {
                    Text("Clear cache", bundle: .module)
                }
                .disabled(cacheBytes == 0)
            } header: {
                Text("Storage", bundle: .module)
            } footer: {
                Text("Clearing the cache does not touch threads you saved.", bundle: .module)
            }
        }
        .navigationTitle(Text("Media", bundle: .module))
        .inlineNavigationTitle()
        .task { await refreshSizes() }
        .downloadFolderPicker(isPresented: $isPickingFolder) { url in
            do {
                services.settings.downloadFolderBookmark = try FileDownloadSaver.bookmark(for: url)
            } catch {
                folderMessage = AlertMessage(
                    text: String(localized: "That folder could not be used.", bundle: .module, locale: AppLocale.current)
                )
            }
        }
        .alert(item: $folderMessage) { message in
            Alert(title: Text(message.text))
        }
    }

    /// The slider's position, which is an index into the sizes on offer rather
    /// than a size: the four are not evenly spaced, so dragging moves between
    /// them a step at a time instead of through the gigabytes in between.
    private var cacheLimitBinding: Binding<Double> {
        Binding(
            get: {
                let current = services.settings.mediaCacheLimitMegabytes
                return Double(cacheChoices.firstIndex(of: current) ?? 0)
            },
            set: { position in
                let index = min(max(0, Int(position.rounded())), cacheChoices.count - 1)
                let megabytes = cacheChoices[index]
                guard megabytes != services.settings.mediaCacheLimitMegabytes else { return }

                services.settings.mediaCacheLimitMegabytes = megabytes
                Task {
                    await MediaCache.shared.setByteLimit(megabytes * 1024 * 1024)
                    await refreshSizes()
                }
            }
        )
    }

    /// The keep-for slider's position, an index like the size one above: a day
    /// and forever are not two points on the same scale.
    private var cacheAgeBinding: Binding<Double> {
        Binding(
            get: {
                let current = services.settings.mediaCacheMaxAgeDays
                // The stored length is always one of the stops, so the fallback
                // is only ever reached if the two lists drift apart.
                let fallback = ageChoices.firstIndex(of: AppSettings.defaultCacheAgeDays) ?? 0
                return Double(ageChoices.firstIndex(of: current) ?? fallback)
            },
            set: { position in
                let index = min(max(0, Int(position.rounded())), ageChoices.count - 1)
                let days = ageChoices[index]
                guard days != services.settings.mediaCacheMaxAgeDays else { return }
                services.settings.mediaCacheMaxAgeDays = days
                Task {
                    // Applied at once, so a reader who shortens this sees the
                    // size below drop rather than wondering whether it took.
                    await MediaCache.shared.setMaxAge(days: days)
                    await refreshSizes()
                }
            }
        )
    }

    /// What one of the lengths on offer is called.
    ///
    /// Four written-out strings rather than a number and a unit: Russian needs
    /// different forms for one day and thirty days, and forever is not a number
    /// at all.
    private func ageLabel(_ days: Int) -> Text {
        switch days {
        case 1: Text("1 day", bundle: .module)
        case 7: Text("7 days", bundle: .module)
        case 30: Text("30 days", bundle: .module)
        default: Text("Forever", bundle: .module)
        }
    }

    private func refreshSizes() async {
        cacheBytes = await MediaCache.shared.currentSize()
        savedThreadBytes = (try? await services.savedThreads.totalBytesOnDisk()) ?? 0
    }

    /// Counted in 1024s, so a limit of five gigabytes reads as "5 GB" rather
    /// than as the 5.37 that dividing by a thousand gives. Disk sizes in this
    /// app are powers of two, and the number on the slider should be the number
    /// the reader chose.
    private func byteCount(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .binary))
    }
}
