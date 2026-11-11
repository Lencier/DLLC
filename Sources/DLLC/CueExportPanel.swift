import AppKit
import AVFoundation
import DLLCCore
import SwiftUI

/// Bottom panel: which sections, how (separate files or one joined file), the options, the file names
/// you'll get, and where they go (save to the project folder and/or AirDrop).
struct CueExportPanel: View {
    @Bindable var editor: CueEditor
    /// Width of the song pane; picks one of four layouts so nothing is cut off in a small window.
    var width: CGFloat = 1200
    @Environment(AppModel.self) private var model

    @State private var options = Self.loadOptions()
    @State private var joined = UserDefaults.standard.bool(forKey: "cueJoined")
    @State private var save = UserDefaults.standard.object(forKey: "cueSendSave") as? Bool ?? true
    @State private var airDrop = UserDefaults.standard.bool(forKey: "cueSendAirDrop")
    @State private var busy: String?
    @State private var result: ExportResult?
    /// The count-in sound, remembered even while the count-in is off.
    @State private var sound = CountInSound(rawValue: UserDefaults.standard.string(forKey: "cueCountSound") ?? "") ?? .beep
    @State private var preview: AVAudioPlayer?

    private struct ExportResult { var urls: [URL]; var savedTo: URL?; var error: String? }
    private enum AirDropState { case waiting, sent, failed(String) }
    @State private var airDropState: AirDropState?
    @State private var airDropTracker: AirDropTracker?

    /// Widths of the side columns, set by dragging the lines between the columns (double-click resets).
    @AppStorage("cueColSections") private var sectionsWidth = Self.sectionsDefault
    @AppStorage("cueColSend") private var sendWidth = Self.sendDefault
    private static let sectionsDefault = 250.0, sendDefault = 250.0
    private static let sectionsRange = 190.0...440.0, sendRange = 210.0...400.0
    /// The options column never gets narrower than this (its compact form), so nothing overlaps.
    private static let optionsMin: CGFloat = 380
    private static let filesMin: CGFloat = 200
    private static let handle: CGFloat = 9

    private enum Fit { case wide, medium, narrow, tiny }

    /// Side columns as wide as the user set them, shrunk (never below their minimum) when the window is too
    /// narrow to keep the options column readable.
    private var columns: (fit: Fit, left: CGFloat, right: CGFloat, middle: CGFloat) {
        let l = CGFloat(sectionsWidth), r = CGFloat(sendWidth)
        if width < 690 { return (.tiny, 0, r, 0) }
        let room = width - Self.handle * 2 - Self.optionsMin
        let minSides = CGFloat(Self.sectionsRange.lowerBound + Self.sendRange.lowerBound)
        guard room >= minSides else {
            let right = min(r, max(CGFloat(Self.sendRange.lowerBound), width - Self.handle - Self.optionsMin))
            return (.narrow, 0, right, width - right - Self.handle)
        }
        let f = min(1, room / (l + r))
        let left = max(CGFloat(Self.sectionsRange.lowerBound), l * f)
        let right = max(CGFloat(Self.sendRange.lowerBound), r * f)
        let middle = width - left - right - Self.handle * 2
        return (middle >= Self.optionsMin + 90 + Self.filesMin ? .wide : .medium, left, right, middle)
    }

    var body: some View {
        layout
        .disabled(busy != nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .onChange(of: options) { _, o in Self.saveOptions(o); result = nil }
        .onChange(of: joined) { _, v in UserDefaults.standard.set(v, forKey: "cueJoined"); result = nil }
        .onChange(of: sound) { _, v in UserDefaults.standard.set(v.rawValue, forKey: "cueCountSound") }
        .onChange(of: save) { _, v in UserDefaults.standard.set(v, forKey: "cueSendSave") }
        .onChange(of: airDrop) { _, v in UserDefaults.standard.set(v, forKey: "cueSendAirDrop") }
        .onChange(of: editor.selected) { _, _ in result = nil }
        // One speed for listening and exporting: what you hear in the preview is what the file will be.
        .onAppear { editor.player.speed = options.speed }
        .onChange(of: options.speed) { _, v in if editor.player.speed != v { editor.player.speed = v } }
        .onChange(of: editor.player.speed) { _, v in if options.speed != v { options.speed = v } }
    }

    /// Upper limit while dragging a side column: the options column keeps its minimum width.
    private func maxSide(_ other: CGFloat, _ range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, Double(width - other - Self.handle * 2 - Self.optionsMin)))
    }

    @ViewBuilder private var layout: some View {
        let c = columns
        switch c.fit {
        case .wide, .medium:   // sections · options (· files) · send, every column top-aligned
            HStack(alignment: .top, spacing: 0) {
                whatColumn.frame(width: c.left, alignment: .topLeading)
                ColumnHandle(value: $sectionsWidth, shown: Double(c.left),
                             range: Self.sectionsRange.lowerBound...maxSide(c.right, Self.sectionsRange),
                             direction: 1, reset: Self.sectionsDefault, name: "sections")
                if c.fit == .wide {
                    optionsColumn().fixedSize(horizontal: true, vertical: false)
                        .frame(alignment: .topLeading)
                    divider
                    filesColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    optionsColumn().frame(maxWidth: .infinity, alignment: .topLeading)
                }
                ColumnHandle(value: $sendWidth, shown: Double(c.right),
                             range: Self.sendRange.lowerBound...maxSide(c.left, Self.sendRange),
                             direction: -1, reset: Self.sendDefault, name: "send")
                sendColumn(showFiles: c.fit != .wide).frame(width: c.right, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .narrow:    // sections become one scrolling strip on top
            VStack(alignment: .leading, spacing: 12) {
                sectionStrip
                HStack(alignment: .top, spacing: 0) {
                    optionsColumn().frame(maxWidth: .infinity, alignment: .topLeading)
                    ColumnHandle(value: $sendWidth, shown: Double(c.right),
                                 range: Self.sendRange.lowerBound...max(Self.sendRange.lowerBound, Double(width - Self.handle - Self.optionsMin)),
                                 direction: -1, reset: Self.sendDefault, name: "send")
                    sendColumn(showFiles: true).frame(width: c.right, alignment: .topLeading)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        case .tiny:      // everything stacked; the editor scrolls it if the window is short
            VStack(alignment: .leading, spacing: 14) {
                sectionStrip
                optionsColumn()
                Divider().padding(.horizontal, 16)
                sendColumn(showFiles: true)
            }
        }
    }

    /// Narrow windows: the section chips in one sideways-scrolling row, with All and Separate/Joined.
    private var sectionStrip: some View {
        HStack(spacing: 10) {
            header("Export")
            if let sections = editor.song?.sections, !sections.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(sections) { s in chip(s) } }.padding(.vertical, 1)
                }
                Button(chosen.count == sections.count ? "None" : "All") {
                    if chosen.count == sections.count { editor.selected = [] } else { editor.selectAllSections() }
                }
                .buttonStyle(.borderless).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.info)
            } else {
                Text("Add sections on the timeline first (R, then drag).")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            GlassChoice(options: [false, true], selection: Binding(get: { joined && chosen.count >= 2 }, set: { v in
                                if !v || chosen.count >= 2 { joined = v } }),
                        label: { v in AnyView(Label(v ? "Joined" : "Separate",
                                                    systemImage: v ? "rectangle" : "rectangle.split.2x1")) },
                        help: { $0 ? "Join the chosen sections into one file (choose two or more)" : "One file per section" })
        }
        .padding(.horizontal, 16)
    }

    private var divider: some View {
        Rectangle().fill(.primary.opacity(0.08)).frame(width: 1).padding(.vertical, 2)
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
    }

    // MARK: Sections

    private var chosen: [SongSection] { (editor.song?.sections ?? []).filter { editor.selected.contains($0.id) } }

    private var whatColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                header("Sections to export")
                Spacer()
                if let all = editor.song?.sections, !all.isEmpty {
                    Button(chosen.count == all.count ? "None" : "All") {
                        if chosen.count == all.count { editor.selected = [] } else { editor.selectAllSections() }
                    }
                    .buttonStyle(.borderless).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.info)
                }
            }
            if let sections = editor.song?.sections, !sections.isEmpty {
                // Many sections: the chips scroll instead of pushing the timeline off the screen.
                if sections.count > 10 {
                    ScrollView { FlowLayout(spacing: 6) { ForEach(sections) { s in chip(s) } }.padding(.vertical, 1) }
                        .frame(height: 130)
                } else {
                    FlowLayout(spacing: 6) { ForEach(sections) { s in chip(s) } }
                }
            } else {
                Text("Add sections on the timeline first: press R and drag across the song.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                modeCard(false, "rectangle.split.2x1", "Separate", "file per section")
                modeCard(true, "rectangle", "Joined", "one file")
            }
        }
        .padding(.horizontal, 16)
    }

    private func chip(_ s: SongSection) -> some View {
        let on = editor.selected.contains(s.id)
        let color = SectionColor.of(s.name)
        return Button {
            if on { editor.selected.remove(s.id) } else { editor.selected.insert(s.id) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark" : "circle.fill")
                    .font(.system(size: on ? 10 : 7, weight: .bold))
                    .foregroundStyle(on ? .white : color)
                Text(s.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading).fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 11).frame(height: 28)
            .foregroundStyle(on ? .white : .primary)
            .background(Capsule().fill(on ? color : Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(on ? .clear : Color.primary.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(s.name) · \(Format.clock(s.start)) – \(Format.clock(s.end))")
    }

    private func modeCard(_ value: Bool, _ symbol: String, _ title: String, _ sub: String) -> some View {
        // What will actually happen: with fewer than two sections chosen it's always separate files.
        let on = (joined && chosen.count >= 2) == value
        let disabled = value && chosen.count < 2
        return Button { joined = value } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(sub).font(.system(size: 10)).foregroundStyle(on ? Color.primary.opacity(0.75) : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 66)
            .foregroundStyle(on ? Color.primary : .secondary)
            .glassTile(selected: on && !disabled, tint: Theme.accent)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .help(value ? "Join the chosen sections back-to-back in song order; the parts between them are left out (choose two or more)"
                    : "Export each chosen section as its own file")
    }

    // MARK: Options

    private static let countIns: [CountIn?] = [nil, CountIn(count: 3, interval: 1), CountIn(count: 4, interval: 0.5),
                                               CountIn(count: 8, interval: 0.5)]

    /// The options at full size, or with shorter count-in labels when the column is narrow (the tooltips
    /// still give the pace).
    private func optionsColumn() -> some View {
        ViewThatFits(in: .horizontal) {
            optionsGrid(short: false)
            optionsGrid(short: true)
        }
    }

    private func optionsGrid(short: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
            GridRow { header("Options").gridCellColumns(2) }
            GridRow {
                rowLabel("Lead-in")
                GlassChoice(options: [0.0, 1, 2, 3, 4, 5], selection: $options.padBefore,
                            label: { v in AnyView(Text(v == 0 ? "None" : "\(Int(v))\(v == 5 ? " s" : "")")) },
                            help: { v in v == 0 ? "Start right on the section" : "Start \(Int(v)) s before the section" })
            }
            GridRow {
                rowLabel("Count-in")
                GlassChoice(options: Array(0..<Self.countIns.count),
                            selection: Binding(get: { countInIndex }, set: { i in
                                var c = Self.countIns[i]; c?.sound = sound; options.countIn = c }),
                            label: { i in AnyView(countInLabel(i, short: short)) },
                            help: { i in ["No count-in — the file starts with the song",
                                          "3 beeps, 1 second apart (3 s), then the song",
                                          "4 beeps, half a second apart (2 s), then the song",
                                          "8 beeps, half a second apart (4 s), then the song"][i] })
            }
            GridRow {
                rowLabel("Sound")
                HStack(spacing: 8) {
                    GlassChoice(options: CountInSound.allCases, selection: Binding(get: { sound }, set: { v in
                                    sound = v; options.countIn?.sound = v }),
                                label: { snd in AnyView(Label(snd.shortLabel, systemImage: snd.symbol)) },
                                help: { $0.explanation })
                    Button { previewCountIn() } label: {
                        Image(systemName: "play.circle.fill").font(.system(size: 20))
                            .foregroundStyle(Theme.info)
                    }
                    .buttonStyle(.plain)
                    .help("Listen to the count-in")
                    .accessibilityLabel("Listen to the count-in")
                }
                .disabled(options.countIn == nil)
                .opacity(options.countIn == nil ? 0.45 : 1)
            }
            GridRow {
                rowLabel("Speed")
                HStack(spacing: 6) {
                    Image(systemName: "tortoise.fill").foregroundStyle(.secondary).help("Slower")
                    GlassChoice(options: CueSpeed.slowToFast, selection: $options.speed,
                                label: { s in AnyView(Text(s.label)) }, help: { $0.longLabel },
                                tintFor: { $0.tint })
                    Image(systemName: "hare.fill").foregroundStyle(.secondary).help("Faster")
                }
            }
            GridRow {
                rowLabel("Format")
                HStack(spacing: 14) {
                    GlassChoice(options: [CueFormat.mp3, .wav], selection: $options.format,
                                label: { f in AnyView(Text(f.label)) },
                                help: { $0 == .mp3 ? "Small, plays everywhere" : "Uncompressed, larger" })
                    Toggle("Fade out", isOn: $options.fadeOut).toggleStyle(.switch).controlSize(.mini)
                        .font(.system(size: 12))
                        .fixedSize()
                        .help("Fade the ending — up to 1.5 s, shorter on very short cues")
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// "3 beats" with its step underneath ("every 1 s" / "every 0.5 s") so the pace is clear at a glance.
    private func countInLabel(_ i: Int, short: Bool) -> some View {
        Group {
            if let c = Self.countIns[i] {
                HStack(spacing: 5) {
                    Text("\(c.count) beats")
                    if !short {
                        Text(c.interval == 1 ? "· 1 s" : "· 0.5 s")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("Off")
            }
        }
    }

    /// Plays the chosen count-in once, exactly as it will be in the file.
    private func previewCountIn() {
        let c = options.countIn ?? CountIn(count: 3, interval: 1, sound: sound)
        preview?.stop()
        preview = try? AVAudioPlayer(data: CountInSynth.wav(c))
        preview?.play()
    }

    private var countInIndex: Int {
        guard let c = options.countIn else { return 0 }
        return Self.countIns.firstIndex { $0?.count == c.count && $0?.interval == c.interval } ?? 0
    }

    private func rowLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            .gridColumnAlignment(.trailing)
    }

    // MARK: Files

    private struct Planned: Identifiable { let id: String; let name: String; let length: Double }

    private var planned: [Planned] {
        guard let song = editor.song, !chosen.isEmpty else { return [] }
        func plan(_ secs: [SongSection]) -> Planned? {
            guard let range = CueMath.range(of: secs), range.duration > 0 else { return nil }
            let name = CueNaming.baseName(sections: secs, range: range, songTitle: song.title, prefix: song.prefix,
                                          speed: options.speed) + "." + options.format.fileExtension
            let pieces = CueMath.padded(pieces: secs.map(\.range), options: options, duration: song.duration)
            return Planned(id: secs.map(\.id.uuidString).joined(), name: name,
                           length: CueMath.outputDuration(pieces: pieces, options: options))
        }
        return joined && chosen.count > 1 ? [plan(chosen)].compactMap { $0 } : chosen.compactMap { plan([$0]) }
    }

    private var filesColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(save ? "You’ll get · \(folderName)" : "You’ll get")
            if planned.isEmpty {
                Text("Choose sections on the left or click them on the timeline (⌘-click for more).")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                fileList(maxHeight: 128)
            }
        }
        .padding(.horizontal, 16)
    }

    private func fileList(maxHeight: CGFloat) -> some View {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(planned) { f in
                            HStack {
                                Image(systemName: "waveform").font(.system(size: 11)).foregroundStyle(Theme.trim)
                                Text(f.name).font(.system(size: 12)).lineLimit(2).truncationMode(.middle)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Text(Format.clock(f.length)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6).frame(minHeight: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.05)))
                        }
                    }
                }
                .frame(maxHeight: maxHeight)
    }

    private var folderName: String {
        model.project(editor.song?.projectID)?.name ?? "chosen folder"
    }

    // MARK: Send

    private func sendColumn(showFiles: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if showFiles, !planned.isEmpty {
                header("You’ll get")
                fileList(maxHeight: 66)
            }
            header("Send to")
            HStack(spacing: 8) {
                sendTile("Save", "square.and.arrow.down", on: save) { if !(save && !airDrop) { save.toggle() } }
                    .help(save ? "Saving to the project folder" : "Also save to the project folder")
                sendTile("AirDrop", "airplayaudio", on: airDrop) { if !(airDrop && !save) { airDrop.toggle() } }
                    .help("Send to an iPhone nearby with AirDrop")
            }
            Button { Task { await export() } } label: {
                VStack(spacing: 2) {
                    if let busy {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text(busy) }
                            .font(.system(size: 14, weight: .bold))
                    } else {
                        Text(planned.count > 1 ? "Export \(planned.count) Files" : "Export")
                            .font(.system(size: 15, weight: .bold))
                    }
                    Text(destinationLine).font(.system(size: 10.5)).opacity(0.85)
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(ExportButtonStyle())
            .disabled(planned.isEmpty || busy != nil || editor.fileURL == nil)
            .keyboardShortcut("e", modifiers: .command)
            .help("Export (⌘E)")
            resultLine
        }
        .padding(.horizontal, 16)
    }

    private var destinationLine: String {
        switch (save, airDrop) {
        case (true, true): "Save to \(folderName), then AirDrop"
        case (false, true): "Straight to AirDrop"
        default: "Save to \(folderName)"
        }
    }

    private func sendTile(_ title: String, _ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .overlay(alignment: .topTrailing) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(on ? Theme.accent : Color.secondary.opacity(0.5))
                    .padding(6)
            }
            .foregroundStyle(Color.primary)
            .glassTile(selected: on, tint: Theme.accent, radius: 10)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var resultLine: some View {
        if let r = result {
            if let err = r.error {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.error)
                    .lineLimit(2)
            } else if let folder = r.savedTo {
                HStack(spacing: 6) {
                    Label("Saved \(r.urls.count) file\(r.urls.count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                    Spacer()
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting(r.urls.isEmpty ? [folder] : r.urls) }
                        .buttonStyle(.borderless).foregroundStyle(Theme.info)
                }
                .font(.system(size: 11, weight: .medium))
            }
            switch airDropState {
            case .waiting?:
                Label("AirDrop open — pick your iPhone", systemImage: "airplayaudio").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.info)
            case .sent?:
                Label("Sent with AirDrop", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.success)
            case .failed(let why)?:
                Label(why, systemImage: "xmark.circle.fill").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.attention).lineLimit(2)
            case nil: EmptyView()
            }
        }
    }

    // MARK: Export

    private func export() async {
        guard let song = editor.song, let src = editor.fileURL, let ffmpeg = model.worker?.tools.ffmpeg else { return }
        // Everything is decided now; changing options while it runs can't mix settings within one export.
        let options = self.options, save = self.save, airDrop = self.airDrop
        let groups: [[SongSection]] = (joined && chosen.count > 1 ? [chosen] : chosen.map { [$0] })
            .filter { CueMath.range(of: $0).map { $0.duration > 0 } ?? false }
        let folder: URL
        if save {
            guard let f = model.saveFolder(forProject: song.projectID) else { return }
            folder = f
        } else {
            // AirDrop only: copies go to a private outbox in the app's cache (never your own folders). Each export
            // gets its own folder so a transfer still running isn't touched; folders older than a day are cleared.
            let outbox = model.paths.caches.appendingPathComponent("airdrop-outbox", isDirectory: true)
            Self.pruneOutbox(outbox)
            folder = outbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        }
        airDropState = nil
        let exporter = CueExporter(ffmpeg: ffmpeg)
        var urls: [URL] = []
        editor.player.pause()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (i, g) in groups.enumerated() {
                busy = groups.count > 1 ? "Exporting \(i + 1) of \(groups.count)…" : "Exporting…"
                urls.append(try await exporter.export(songFile: src, song: song, sections: g, pieces: g.map(\.range),
                                                      options: options, to: folder))
            }
            busy = nil
            result = ExportResult(urls: urls, savedTo: save ? folder : nil, error: nil)
            if airDrop, !urls.isEmpty { sendAirDrop(urls) }
        } catch {
            busy = nil
            result = ExportResult(urls: urls, savedTo: save ? folder : nil,
                                  error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func sendAirDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            model.show(.warning, "AirDrop isn’t available. Turn on Wi-Fi and Bluetooth, then try again.")
            return
        }
        let tracker = AirDropTracker { ok, why in
            airDropState = ok ? .sent : .failed(why ?? "AirDrop didn’t send. Try again.")
        }
        airDropTracker = tracker
        service.delegate = tracker
        airDropState = .waiting
        service.perform(withItems: urls)
    }

    /// Removes AirDrop outbox folders from earlier exports (older than a day). Only touches the app's cache.
    private static func pruneOutbox(_ outbox: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: outbox, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for item in items {
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: item) }
        }
    }

    // MARK: Remembered options

    private static func loadOptions() -> CueOptions {
        guard let data = UserDefaults.standard.data(forKey: "cueOptions"),
              var o = try? JSONDecoder().decode(CueOptions.self, from: data) else { return CueOptions() }
        if o.format == .lyricVideo { o.format = .mp3 }
        o.padBefore = min(5, max(0, o.padBefore.rounded()))
        o.padAfter = 0
        return o
    }

    private static func saveOptions(_ o: CueOptions) {
        if let data = try? JSONEncoder().encode(o) { UserDefaults.standard.set(data, forKey: "cueOptions") }
    }
}

/// The big red Export button (Liquid Glass with a red tint on macOS 26).
struct ExportButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.82)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .shadow(color: Theme.accent.opacity(isEnabled ? 0.35 : 0), radius: 8, y: 3)
            }
            .saturation(isEnabled ? 1 : 0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Lays chips out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let h = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + size.width
            r.height = max(r.height, size.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}

/// Hears back from the AirDrop window: sent, or cancelled / failed.
final class AirDropTracker: NSObject, NSSharingServiceDelegate {
    private let done: @MainActor (Bool, String?) -> Void
    init(done: @escaping @MainActor (Bool, String?) -> Void) { self.done = done }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        Task { @MainActor in done(true, nil) }
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let cancelled = (error as NSError).code == NSUserCancelledError
        let text = cancelled ? "AirDrop cancelled — files weren’t sent." : "AirDrop didn’t send: \(error.localizedDescription)"
        Task { @MainActor in done(false, text) }
    }
}

/// The line between two export columns: drag it to make the column beside it wider or narrower,
/// double-click it to go back to the standard width. The width is remembered.
private struct ColumnHandle: View {
    @Binding var value: Double
    /// The width the column has right now (it may be squeezed below `value` in a small window).
    let shown: Double
    let range: ClosedRange<Double>
    /// +1: dragging right widens the column (it's on the left); −1: dragging left widens it.
    let direction: Double
    let reset: Double
    let name: String
    @State private var start: Double?
    @State private var hover = false

    var body: some View {
        ZStack {
            Rectangle().fill(.primary.opacity(hover || start != nil ? 0.22 : 0.08)).frame(width: 1)
            Capsule().fill(.primary.opacity(hover || start != nil ? 0.4 : 0))
                .frame(width: 4, height: 30)
        }
        .frame(width: 9)
        .frame(maxHeight: .infinity)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pointerStyle(.columnResize)
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { v in
                let s = start ?? shown
                if start == nil { start = s }
                value = min(range.upperBound, max(range.lowerBound, s + direction * Double(v.translation.width)))
            }
            .onEnded { _ in start = nil })
        .onTapGesture(count: 2) { value = reset }
        .help("Drag to resize the \(name) column · double-click to reset")
        .accessibilityLabel("Resize the \(name) column")
    }
}
