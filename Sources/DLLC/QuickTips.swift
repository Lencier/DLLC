import SwiftUI

/// Short how-to cards for both modes, in a side panel you can open and close at any time (the ? beside the logo, ⌘?).
/// The topic chips at the top jump straight to the card you need, so you can check one thing and get back to work.
struct QuickTipsView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: AppMode = .download
    @State private var flash: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Picker("Mode", selection: $mode) {
                Label("Download", systemImage: "arrow.down.circle").tag(AppMode.download)
                Label("Song Cues", systemImage: "waveform").tag(AppMode.songs)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 16).padding(.bottom, 10)
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    jumpBar(proxy)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(QuickTip.all(for: mode)) { tip in
                                TipCard(tip: tip, highlighted: flash == tip.id).id(tip.id)
                            }
                            Text("Hover any button in the app to see its name and shortcut.")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .padding(16)
                    }
                }
                .onChange(of: mode) { _, m in
                    if let first = QuickTip.all(for: m).first { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { mode = model.mode }
        .onChange(of: model.mode) { _, m in mode = m }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 22)).foregroundStyle(Theme.info)
            VStack(alignment: .leading, spacing: 0) {
                Text("Quick Tips").font(.system(size: 16, weight: .bold))
                Text("Pick a topic, check it, get back to work").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.showTips = false } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 28, height: 28)
            }
            .buttonStyle(GlassTileButtonStyle(tint: .primary, radius: 14, padding: 0))
            .help("Close Quick Tips (⌘?)")
            .accessibilityLabel("Close Quick Tips")
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
    }

    /// Topic chips: click one to jump to its card.
    private func jumpBar(_ proxy: ScrollViewProxy) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(QuickTip.all(for: mode)) { tip in
                Button {
                    withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(tip.id, anchor: .top) }
                    flash = tip.id
                    Task { try? await Task.sleep(for: .seconds(1.2)); if flash == tip.id { flash = nil } }
                } label: {
                    Label(tip.title, systemImage: tip.symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(Capsule().fill(tip.color.opacity(0.14)))
                        .foregroundStyle(tip.color)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Jump to \(tip.title)")
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }
}

private struct TipCard: View {
    let tip: QuickTip
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: tip.symbol)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(tip.color))
                VStack(alignment: .leading, spacing: 1) {
                    Text(tip.title).font(.system(size: 14, weight: .bold))
                    Text(tip.summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(tip.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(tip.color)
                            .frame(width: 17, height: 17)
                            .background(Circle().fill(tip.color.opacity(0.15)))
                        Text(.init(step)).font(.system(size: 12.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !tip.terms.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tip.terms, id: \.0) { term, meaning in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(term).font(.system(size: 11.5, weight: .bold)).foregroundStyle(tip.color)
                                .frame(width: 92, alignment: .leading)
                            Text(.init(meaning)).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(tip.color.opacity(0.07)))
            }
            if !tip.keys.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tip.keys, id: \.0) { key, what in
                        HStack(spacing: 5) {
                            KeyCap(key)
                            Text(what).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(.trailing, 4)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(highlighted ? 0.09 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(highlighted ? tip.color : Color.primary.opacity(0.08), lineWidth: highlighted ? 2 : 1))
        .animation(.easeOut(duration: 0.25), value: highlighted)
    }
}

/// A keyboard key drawn like a key.
struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.25)))
            .shadow(color: .black.opacity(0.15), radius: 0, y: 1)
    }
}

/// One topic card. Steps accept **bold** Markdown.
struct QuickTip: Identifiable {
    let id: String
    let symbol: String
    let color: Color
    let title: String
    let summary: String
    let steps: [String]
    var keys: [(String, String)] = []
    /// Word → meaning, for explaining options (Lead-in, Count-in…).
    var terms: [(String, String)] = []

    static func all(for mode: AppMode) -> [QuickTip] { mode == .songs ? songs : download }

    static let download: [QuickTip] = [
        QuickTip(id: "d-start", symbol: "star.fill", color: Theme.accent, title: "Quick Start",
                 summary: "From a link to a file in four steps.",
                 steps: ["(Optional) Make or pick a **project** in the sidebar.",
                         "**Paste a link** into the bar at the top.",
                         "Click the row's **chip** to choose Video, Audio, Clip, Frame or GIF.",
                         "Press **Download**. The file lands in the project's folder."]),
        QuickTip(id: "d-add", symbol: "link.badge.plus", color: Theme.info, title: "Add Links",
                 summary: "Put video links in the queue.",
                 steps: ["Paste one or more links into the **bar at the top**.",
                         "Or press **⇧⌘V** to paste every link on the clipboard at once.",
                         "Each link is checked first; a duplicate shows a warning but is still added."],
                 keys: [("⇧⌘V", "Paste links")]),
        QuickTip(id: "d-projects", symbol: "folder.badge.plus", color: Theme.processing, title: "Projects",
                 summary: "Group links (and songs) per job; each project saves into its own folder.",
                 steps: ["Click **New Project** at the bottom of the sidebar.",
                         "Select the project, then paste links: they join it and save into its folder.",
                         "Drag rows onto a project to move them.",
                         "Deleting a project never deletes your downloaded files."],
                 keys: [("⇧⌘N", "New project")]),
        QuickTip(id: "d-output", symbol: "slider.horizontal.3", color: Theme.attention, title: "Choose Output",
                 summary: "Video, audio, a clip, a still frame or a GIF.",
                 steps: ["Click the **chip on a row** to open Output.",
                         "Pick **Video** (quality + size), **Audio**, **Clip**, **Frame** or **GIF**.",
                         "**Use as Default for New Links** keeps that choice for the next links."]),
        QuickTip(id: "d-preview", symbol: "scissors", color: Theme.trim, title: "Preview & Cut",
                 summary: "Watch and pick a range before anything downloads.",
                 steps: ["Click a row: the preview opens beside the list.",
                         "Drag the **orange handles** to choose the part you want, or press I and O.",
                         "Pinch or ⌘-scroll to zoom the timeline; **Fit** shows it all.",
                         "**Whole Video** resets the range."],
                 keys: [("Space", "Play"), ("← →", "One frame"), ("I", "In"), ("O", "Out")]),
        QuickTip(id: "d-download", symbol: "arrow.down.circle.fill", color: Theme.success, title: "Download",
                 summary: "Start one item or the whole list.",
                 steps: ["Press the **Download** button on a row.",
                         "Or **Download All** (⌘↩) — inside a project, only that project's items.",
                         "The red trash button removes a row; the file on disk stays."],
                 keys: [("⌘↩", "Download all"), ("⇧⌘K", "Clear completed")]),
        QuickTip(id: "d-frame", symbol: "camera.fill", color: Theme.accent, title: "Snap a Frame",
                 summary: "Save the exact frame you're looking at.",
                 steps: ["Open a preview and stop on the frame you want.",
                         "Press **Snap Frame** (⇧⌘S) to save it (PNG or JPEG), or **Copy** (⇧⌘C) to put it on the clipboard without saving — quick to paste into a chat.",
                         "**Save Cover** / **Copy Cover** take the clip's cover picture from the site (if it has one)."],
                 keys: [("⇧⌘S", "Snap frame"), ("⇧⌘C", "Copy frame")]),
        QuickTip(id: "d-login", symbol: "lock.fill", color: .gray, title: "Private Posts",
                 summary: "Some Instagram/X posts need you to be logged in.",
                 steps: ["Open the row's Output › **Advanced** › **Browser login** (off by default).",
                         "DLLC reads that browser's cookies only while downloading; it never asks for passwords.",
                         "Settings › Privacy can forget all logins."]),
        QuickTip(id: "d-songs", symbol: "waveform", color: Theme.trim, title: "To Song Cues",
                 summary: "Turn a downloaded song into cues.",
                 steps: ["Right-click a finished row › **Open in Song Cues**.",
                         "Or switch modes at the top of the window (⌘2)."],
                 keys: [("⌘1", "Download"), ("⌘2", "Song Cues")]),
    ]

    static let songs: [QuickTip] = [
        QuickTip(id: "s-start", symbol: "star.fill", color: Theme.accent, title: "Quick Start",
                 summary: "From a song to audio cues on your phone in five steps.",
                 steps: ["**Add a song** (⌘O) or drop it on a project.",
                         "Press **R** and drag over the song to make each section (Verse, Hook…). Or paste lyrics with times and press **Sections from Times**.",
                         "Press **V** to go back to moving and resizing blocks.",
                         "Below, pick the **sections**, then Lead-in, Count-in and Speed.",
                         "Choose **Save** and/or **AirDrop**, then **Export** (⌘E).",
                         "Your work saves itself — **Saved** beside the title shows it. Quit and reopen any time; nothing is lost."]),
        QuickTip(id: "s-add", symbol: "waveform.badge.plus", color: Theme.trim, title: "Add a Song",
                 summary: "Songs live in projects, next to your reference clips.",
                 steps: ["Press **⌘O**, or drop an audio/video file on a project in the sidebar.",
                         "A finished download: right-click › **Open in Song Cues**.",
                         "Click the title at the top to rename it — every file name starts with it.",
                         "Deleting a project removes its songs from the list; the audio files are never deleted."],
                 keys: [("⌘O", "Add song"), ("⌘1 / ⌘2", "Switch mode")]),
        QuickTip(id: "s-sections", symbol: "rectangle.split.3x1.fill", color: Theme.info, title: "Make Sections",
                 summary: "Cut the song into Verse, Hook, Dance Break…",
                 steps: ["Press **R** (Range) and **drag across the song** to make a section, then pick its name.",
                         "Press **V** (Select): drag a block to **move** it, drag its **edges** to make it shorter or longer.",
                         "Double-click a block to rename it; right-click for Play, Copy Times, Set Start/End to Playhead, Delete.",
                         "Blocks never overlap. With **Snap** on, edges stick to other blocks, markers and the playhead."]),
        QuickTip(id: "s-select", symbol: "rectangle.dashed", color: Theme.processing, title: "Select Many",
                 summary: "Pick several blocks at once — to delete or export them together.",
                 steps: ["With **V**, drag a box over empty space in the Sections lane: every block it touches is selected. Dragging on the song moves the playhead.",
                         "Hold **⇧** or **⌘** while dragging (or ⌘-click blocks) to add to the selection.",
                         "**⌫** deletes all selected blocks; **⌘Z** brings them back.",
                         "**⌘A** selects every section. The selected blocks are also the ones that get exported."],
                 keys: [("⌘A", "Select all"), ("⌫", "Delete"), ("esc", "Deselect"), ("⌘Z", "Undo")]),
        QuickTip(id: "s-tools", symbol: "cursorarrow", color: Theme.accent, title: "Tools",
                 summary: "The buttons above the timeline (hover any of them for its name).",
                 steps: ["**Select (V)** moves, resizes and box-selects blocks. **Range (R)** draws new sections.",
                         "**Split (C)** cuts the block under the playhead in two.",
                         "**Marker (M)** drops an orange diamond — handy for a beat or a move. Drag it to adjust; double-click the Markers row to add one there.",
                         "**Snap (S)** turns sticky edges on or off. The **lyrics** button (right end) hides or shows the lyrics."],
                 keys: [("V", "Select"), ("R", "Range"), ("C", "Split"), ("M", "Marker"), ("S", "Snap")]),
        QuickTip(id: "s-move", symbol: "arrow.left.and.right", color: Theme.processing, title: "Play & Move",
                 summary: "Get around the song like in Premiere, down to 1/100 of a second.",
                 steps: ["Click the ruler or the song to move the playhead; drag the ruler or the song to scrub.",
                         "Arrow keys step the playhead: **← →** 0.1 s, **⇧← →** 1 s, **⌥← →** 0.01 s. J / L jump 5 s.",
                         "Pinch or ⌥-scroll to zoom, scroll to move sideways, **Fit** (⇧Z) shows the whole song.",
                         "The **NM** menu sets the speed (pitch stays the same). It's the same setting as **Speed** in the export panel, so you hear exactly what you'll export."],
                 keys: [("Space", "Play"), ("K", "Pause"), ("← →", "0.1 s"), ("⇧← →", "1 s"), ("⌥← →", "0.01 s"),
                        ("J / L", "5 s"), ("⇧Z", "Fit"), ("+ / −", "Zoom")]),
        QuickTip(id: "s-lyrics", symbol: "text.quote", color: Theme.success, title: "Lyrics & Times",
                 summary: "One sheet with the lyrics and each section's times.",
                 steps: ["Paste the lyrics. A heading line like **[Verse 1] 01:31 - 01:40** marks a section.",
                         "**Sections from Times** makes (or moves) the blocks from those headings.",
                         "Move or resize a block and its heading's times update by themselves.",
                         "**Copy Lyrics & Times** copies the whole sheet, ready to send to the team.",
                         "Done typing? Click the timeline or press **esc** — the shortcut keys work again."],
                 keys: [("esc", "Leave the lyrics")]),
        QuickTip(id: "s-options", symbol: "slider.horizontal.3", color: Theme.attention, title: "Export Options",
                 summary: "What each option below the timeline does to the file.",
                 steps: [],
                 terms: [
                    ("Lead-in", "Starts the file **1–5 seconds before** the section, using the song itself — so dancers hear the run-up. None = starts right on the section."),
                    ("Count-in", "Beeps added **in front of** the file, before the song starts. The **first one is accented** (stronger) so you can hear where the count starts."),
                    ("3 beats · 1 s", "3 beeps, one per second (3 s). Calm, easy to follow."),
                    ("4 beats · 0.5 s", "4 beeps, half a second apart (2 s). Like a drummer's \"1-2-3-4\"."),
                    ("8 beats · 0.5 s", "8 beeps, half a second apart (4 s). Two bars — more time to get ready."),
                    ("Sound", "**Beep** = clear electronic tone (best on set). **Click** = short metronome tick. **Wood** = soft woodblock knock. Press ▶ to listen."),
                    ("Order", "Count-in beeps → lead-in → the section."),
                    ("Speed", "**NM** = normal (green). **÷2 ÷3 ÷4** = slower (blue, for learning moves); **×2 ×3 ×4** = faster (red). Pitch stays the same; the beeps keep their pace."),
                    ("Fade out", "Fades the ending (up to 1.5 seconds; very short cues get a shorter fade) instead of stopping abruptly."),
                    ("MP3 / WAV", "MP3 is small and plays everywhere. WAV is uncompressed and larger."),
                 ]),
        QuickTip(id: "s-export", symbol: "square.and.arrow.up.fill", color: Theme.trim, title: "Export & Send",
                 summary: "Each section as its own audio file — or several joined.",
                 steps: ["Pick sections with the chips (or select blocks on the timeline).",
                         "**Separate** = one file per section. **Joined** = the chosen sections back-to-back in song order, in one file; the parts between them are left out (choose two or more).",
                         "**You'll get** lists every file name and length before you export.",
                         "**Save** puts files in the project's folder; **AirDrop** sends them to a phone nearby. Turn on one or both, then **Export** (⌘E).",
                         "Names look like **TOP 5 - Hook 1 (slow 2x).mp3**. An existing file is never replaced — a new name is used.",
                         "Need more room for the timeline? Drag the grip above this panel; double-click it to fit again. Drag the lines between its columns to widen Sections or Send To."],
                 keys: [("⌘E", "Export"), ("⌘A", "All sections")]),
    ]
}
