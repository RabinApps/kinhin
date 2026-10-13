import AppKit
import KinhinKit
import SwiftUI

/// Sheet: make a video of a repository's `.kinhin/videos/`, with live build output, and find music for it.
struct VideosView: View {
    static let size = CGSize(width: 680, height: 640)

    @Bindable var model: VideosModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    repositorySection
                    if model.repository != nil {
                        videosSection
                        buildSection
                        musicSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .alert(
            "Videos", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
        ) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    // MARK: header and footer

    private var header: some View {
        HStack(spacing: 10) {
            Text("Make a Video").font(.system(size: 16, weight: .semibold))
            Spacer()
            if model.isBuilding || model.musicSearching {
                ProgressView().controlSize(.small).accessibilityLabel("Working")
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Builds run in a container (Apple container or Docker); the first build downloads the video image.")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
        }
    }

    // MARK: repository

    private var repositorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await model.chooseRepository() }
            } label: {
                HStack {
                    Image(systemName: "folder")
                    Text(model.repository == nil ? "Choose Repository…" : "Change Repository…")
                }
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(model.repository == nil ? Color.accentColor : Color.secondary.opacity(0.15))
                .foregroundStyle(model.repository == nil ? Color.white : Color.primary)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("videos-choose-repository")
            if let repository = model.repository {
                Text(repository.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Pick the repository whose .kinhin/videos/ folder holds your videos.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: videos

    private var videosSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Videos").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            if model.videos.isEmpty {
                Text("No videos here yet. Create one below.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Picker("Video", selection: $model.selected) {
                    ForEach(model.videos, id: \.self) { name in Text(name).tag(Optional(name)) }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Video to build")
            }
            HStack {
                TextField("New video name (default: launch)", text: $model.newVideoName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.createVideo() }
                Button("New Video") { model.createVideo() }
                    .accessibilityIdentifier("videos-new")
            }
        }
    }

    // MARK: build

    private var buildSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Build").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            HStack {
                Toggle("Fast preview", isOn: $model.fast).toggleStyle(.checkbox)
                Spacer()
                if model.isBuilding {
                    Button("Cancel") { model.cancelBuild() }
                } else {
                    Button("Build") { model.build() }
                        .disabled(!model.canBuild)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("videos-build")
                }
            }
            status
            if !model.log.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.log.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(6)
                            .id("end")
                    }
                    .frame(height: 150)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
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
            Text("Building…").font(.system(size: 12)).foregroundStyle(Color.accentColor)
        case .succeeded:
            HStack {
                Text("Done.").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
                if let directory = model.outputDirectory {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                        .controlSize(.small)
                }
            }
        case .failed(let why):
            Text(why).font(.system(size: 12)).foregroundStyle(.red)
        }
    }

    // MARK: music

    private var musicSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Music").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            HStack {
                TextField("Search free music (CC0 and public domain)", text: $model.musicQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.searchMusic() } }
                Button("Search") { Task { await model.searchMusic() } }
                    .disabled(model.musicSearching)
                    .accessibilityIdentifier("videos-music-search")
            }
            if let notice = model.musicNotice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ForEach(Array(model.musicResults.enumerated()), id: \.offset) { index, track in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title).font(.system(size: 12)).lineLimit(1)
                        Text(detail(track)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Add to video") { Task { await model.addMusic(at: index) } }
                        .controlSize(.small)
                        .disabled(model.selected == nil || model.addingMusic)
                }
            }
            if !model.musicResults.isEmpty {
                Text("Licenses are as declared by the source. You are responsible for how you use a track.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
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
