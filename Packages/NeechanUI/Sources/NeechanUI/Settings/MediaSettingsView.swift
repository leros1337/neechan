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

    private let cacheChoices = [128, 256, 512, 1024, 2048]

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
                Picker(selection: cacheLimitBinding) {
                    ForEach(cacheChoices, id: \.self) { megabytes in
                        Text(byteCount(megabytes * 1024 * 1024)).tag(megabytes)
                    }
                } label: {
                    Text("Limit", bundle: .module)
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

    private var cacheLimitBinding: Binding<Int> {
        Binding(
            get: { services.settings.mediaCacheLimitMegabytes },
            set: { megabytes in
                services.settings.mediaCacheLimitMegabytes = megabytes
                Task {
                    await MediaCache.shared.setByteLimit(megabytes * 1024 * 1024)
                    await refreshSizes()
                }
            }
        )
    }

    private func refreshSizes() async {
        cacheBytes = await MediaCache.shared.currentSize()
        savedThreadBytes = (try? await services.savedThreads.totalBytesOnDisk()) ?? 0
    }

    private func byteCount(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file))
    }
}
