import AppKit
import KinhinKit
import SwiftUI

/// Sheet: make a video of a repository's `.kinhin/videos/`, with live build output, and find music for it.
struct VideosView: View {
    static let size = CGSize(width: 640, height: 640)

    @Bindable var model: VideosModel
    let onClose: () -> Void

    var body: some View {
        SheetScaffold(
            title: "Make a video", width: Self.size.width,
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        repositorySection
                        if model.repository != nil {
                            videosSection
                            buildSection
                            musicSection
                        }
                        HintText(
                            "Builds run in a container (Apple container or Docker); the first build downloads the video image."
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity)
            },
            footer: { SheetCloseFooter(close: onClose) }
        )
        .frame(height: Self.size.height, alignment: .topLeading)
        .alert(
            "Videos", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
        ) {
            Button("OK") { model.message = nil }
        } message: {
            Text(verbatim: model.message ?? "")
        }
    }

    // MARK: repository

    private var repositorySection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                Button(model.repository == nil ? "Choose Repository…" : "Change Repository…") {
                    Task { await model.chooseRepository() }
                }
                .accessibilityIdentifier("videos-choose-repository")
                if let repository = model.repository {
                    Text(verbatim: repository.path)
                        .typeStyle(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if model.isBuilding || model.musicSearching {
                    ProgressView().controlSize(.small).accessibilityLabel("Working")
                }
            }
            if model.repository == nil {
                HintText("Pick the repository whose .kinhin/videos/ folder holds your videos.")
            }
        }
    }

    // MARK: videos

    private var videosSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            fieldLabel("Videos")
            if model.videos.isEmpty {
                HintText("No videos here yet. Create one below.")
            } else {
                Picker("Video", selection: $model.selected) {
                    ForEach(model.videos, id: \.self) { name in Text(verbatim: name).tag(Optional(name)) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Video to build")
            }
            HStack {
                TextField("New video name (default: launch)", text: $model.newVideoName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.createVideo() }
                Button("New Video") { model.createVideo() }
                    .controlSize(.small)
                    .accessibilityIdentifier("videos-new")
            }
        }
    }

    // MARK: build

    private var buildSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            fieldLabel("Build")
            HStack(spacing: Spacing.md) {
                Toggle("Fast preview", isOn: $model.fast).toggleStyle(.checkbox)
                if model.isBuilding {
                    Button("Cancel") { model.cancelBuild() }
                } else {
                    Button("Build") { model.build() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canBuild)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("videos-build")
                }
                status
                Spacer(minLength: 0)
            }
            if !model.log.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(verbatim: model.log.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(Spacing.sm)
                            .id("end")
                    }
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: Radius.md).fill(Palette.grouped))
                    .onChange(of: model.log.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .building:
            StatusText(text: "Building…")
        case .succeeded:
            HStack(spacing: Spacing.sm) {
                StatusText(text: "Done.", style: .ok)
                if let directory = model.outputDirectory {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                        .controlSize(.small)
                }
            }
        case .failed(let why):
            StatusText(verbatim: why, style: .error).textSelection(.enabled)
        }
    }

    // MARK: music

    private var musicSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            fieldLabel("Music")
            HStack {
                TextField("Search free music (CC0 and public domain)", text: $model.musicQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.searchMusic() } }
                Button("Search") { Task { await model.searchMusic() } }
                    .controlSize(.small)
                    .disabled(model.musicSearching)
                    .accessibilityIdentifier("videos-music-search")
            }
            if let notice = model.musicNotice {
                HintText(verbatim: notice).textSelection(.enabled)
            }
            ForEach(Array(model.musicResults.enumerated()), id: \.offset) { index, track in
                InsetRow(
                    content: {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(verbatim: track.title).typeStyle(.body).fontWeight(.medium).lineLimit(1)
                            HintText(verbatim: detail(track)).lineLimit(1)
                        }
                    },
                    trailing: {
                        Button("Add to video") { Task { await model.addMusic(at: index) } }
                            .controlSize(.small)
                            .disabled(model.selected == nil || model.addingMusic)
                    })
            }
            if !model.musicResults.isEmpty {
                HintText("Licenses are as declared by the source. You are responsible for how you use a track.")
            }
        }
    }

    private func fieldLabel(_ key: LocalizedStringKey) -> some View {
        Text(key).typeStyle(.caption).fontWeight(.medium).foregroundStyle(.secondary)
    }

    private func detail(_ track: MusicTrack) -> String {
        var parts: [String] = []
        if let creator = track.creator, !creator.isEmpty { parts.append(creator) }
        if let seconds = track.seconds {
            let total = Int(seconds.rounded())
            parts.append(String(format: "%d:%02d", total / 60, total % 60))
        }
        parts.append(track.origin == .builtIn ? "built in" : track.source)
        parts.append(MusicLicense.displayName(track.license, version: nil))
        return parts.joined(separator: " · ")
    }
}
