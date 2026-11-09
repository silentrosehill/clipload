// Views.swift — the main window (download list) and settings sheet.

import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Main window

struct MainView: View {
    @ObservedObject private var manager = Manager.shared
    @ObservedObject private var settings = Settings.shared
    @State private var link = ""
    @State private var quality = Settings.shared.quality
    @State private var audioOnly = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Paste a video page or stream link…", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(download)
                Picker("Quality", selection: $quality) {
                    ForEach(Quality.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 190)
                .disabled(audioOnly)
                Toggle("Audio only", isOn: $audioOnly)
                    .toggleStyle(.checkbox)
                Button("Download", action: download)
                    .keyboardShortcut(.defaultAction)
                    .fixedSize()
                    .disabled(linkFrom(link) == nil)
            }
            .padding(12)

            Divider()

            if manager.jobs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No downloads yet").font(.title3.weight(.semibold))
                    Text("Paste a link above, copy a video link anywhere,\nor click ⬇ Stream on a video in Safari.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(manager.jobs) { job in
                        JobRow(job: job)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack(spacing: 12) {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear finished") { manager.clearFinished() }
                    .disabled(!manager.jobs.contains { $0.state.isFinished })
                Button {
                    let url = URL(fileURLWithPath: settings.folder)
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Open download folder")
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                .keyboardShortcut(",", modifiers: .command)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 680, minHeight: 420)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in showSettings = true }
    }

    private var summary: String {
        let running = manager.running.count
        let queued = manager.queuedCount
        let choosing = manager.jobs.filter { $0.state == .choosing }.count
        var parts: [String] = []
        if running > 0 { parts.append("\(running) downloading") }
        if queued > 0 { parts.append("\(queued) queued") }
        if choosing > 0 { parts.append("\(choosing) waiting for a quality") }
        if parts.isEmpty { return "Idle · up to \(settings.maxConcurrent) at a time" }
        return parts.joined(separator: " · ") + " · up to \(settings.maxConcurrent) at a time"
    }

    private func download() {
        guard let url = linkFrom(link) else { return }
        manager.add(Request(url: url), audio: audioOnly, quality: quality)
        link = ""
    }
}

extension Notification.Name {
    static let showSettings = Notification.Name("ClipLoadShowSettings")
}

// MARK: - One download

struct JobRow: View {
    @ObservedObject var job: Job
    private let manager = Manager.shared

    var body: some View {
        HStack(spacing: 12) {
            icon
                .font(.title2)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if job.state == .running {
                    ProgressView(value: min(max(job.percent, 0), 100), total: 100)
                        .progressViewStyle(.linear)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(job.state == .failed ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)
            controls
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(job.req.url.absoluteString, forType: .string)
            }
            if let file = job.file, job.state == .done {
                Button("Show in Finder") { reveal(file) }
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: file)) }
            }
            Divider()
            Button("Remove from List") { manager.remove(job) }
        }
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .probing:
            ProgressView().controlSize(.small)
        case .choosing:
            Image(systemName: "slider.horizontal.3").foregroundStyle(Color.accentColor)
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
        case .done:
            Image(systemName: job.audio ? "music.note" : "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    private var status: String {
        switch job.state {
        case .probing:
            return "Checking available qualities… · \(job.host)"
        case .choosing:
            return "Choose a quality · \(job.formats.count) available · \(job.host)"
        case .queued:
            return "Queued · \(job.qualityLabel) · \(job.host)"
        case .running:
            let pct = "\(Int(job.percent))%"
            return [pct, job.qualityLabel, job.detail].filter { !$0.isEmpty }.joined(separator: " · ")
        case .done:
            var parts = ["Done"]
            if let file = job.file,
               let size = (try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? NSNumber {
                parts.append(formatBytes(size.int64Value))
            } else if job.file != nil {
                parts.append("file moved or deleted")
            }
            parts.append(job.date.formatted(date: .abbreviated, time: .shortened))
            return parts.joined(separator: " · ")
        case .failed:
            return job.error
        case .cancelled:
            return "Cancelled"
        }
    }

    @ViewBuilder private var controls: some View {
        switch job.state {
        case .choosing:
            HStack(spacing: 6) {
                Picker("Quality", selection: $job.chosen) {
                    ForEach(job.formats) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 230)
                Button("Download") { manager.confirm(job) }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                iconButton("xmark.circle.fill", help: "Cancel") { manager.cancel(job) }
            }
        case .probing, .queued, .running:
            iconButton("xmark.circle.fill", help: "Cancel") { manager.cancel(job) }
        case .done:
            HStack(spacing: 4) {
                if let file = job.file {
                    iconButton("play.circle", help: "Open") { NSWorkspace.shared.open(URL(fileURLWithPath: file)) }
                    iconButton("magnifyingglass.circle", help: "Show in Finder") { reveal(file) }
                }
            }
        case .failed, .cancelled:
            HStack(spacing: 4) {
                iconButton("arrow.clockwise.circle", help: "Retry") { manager.retry(job) }
                iconButton("trash.circle", help: "Remove from list") { manager.remove(job) }
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title2)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func reveal(_ file: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject private var s = Settings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var loginError = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Downloads") {
                    Picker("Default quality", selection: $s.quality) {
                        ForEach(Quality.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Let me pick the quality", selection: $s.askQuality) {
                        ForEach(AskQuality.allCases) { Text($0.label).tag($0) }
                    }
                    Stepper(value: $s.maxConcurrent, in: 1...6) {
                        Text("Download \(s.maxConcurrent) at a time")
                    }
                    LabeledContent("Save to") {
                        HStack {
                            Text((s.folder as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Change…", action: chooseFolder)
                        }
                    }
                }
                Section("Clipboard") {
                    Picker("When I copy a video link", selection: $s.clipMode) {
                        ForEach(ClipMode.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Offer for any link, not just video sites", isOn: $s.anyLink)
                }
                Section("General") {
                    Toggle("Open at login", isOn: $loginItem)
                        .onChange(of: loginItem) { _, on in setLoginItem(on) }
                    if !loginError.isEmpty {
                        Text(loginError).font(.caption).foregroundStyle(.red)
                    }
                    LabeledContent("yt-dlp") {
                        Button("Update") { Manager.shared.updateYtdlp() }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 500, height: 540)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: s.folder)
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url { s.folder = url.path }
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = ""
        } catch {
            loginError = error.localizedDescription
            loginItem = SMAppService.mainApp.status == .enabled
        }
    }
}
