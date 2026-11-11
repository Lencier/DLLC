import DLLCCore
import SwiftUI

/// Compact output picker for one job: mode, quality (real combinations only), container, advanced details.
struct OutputPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let jobID: UUID
    @State private var showAdvanced = false

    enum Mode: String, CaseIterable, Identifiable {
        case video = "Video", audio = "Audio", clip = "Clip", frame = "Frame", gif = "GIF"
        var id: String { rawValue }
    }

    var body: some View {
        if let job = model.engine.job(jobID) {
            Group {
                if let items = job.info?.directItems, !items.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(PinterestPins.summary(items)).font(.headline)
                        Text("This post is saved as its own files, in their original size.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    content(job)
                }
            }
            .padding(Theme.Space.l)
            .frame(width: 360)
        }
    }

    @ViewBuilder private func content(_ job: Job) -> some View {
        let info = job.info
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Picker("Output", selection: Binding(get: { mode(job) }, set: { setMode($0, job) })) {
                ForEach(Mode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch job.options.kind {
            case .video:
                videoControls(job, info)
            case .audio:
                audioControls(job, info)
            case .clip, .gif:
                Text("Set the range in the preview workspace.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Preview") { model.openWorkspace(job.id); dismiss() }
            }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                AdvancedDetails(job: job).padding(.top, Theme.Space.s)
            }
            .font(.callout)

            HStack {
                Button("Use as Default for New Links") {
                    var o = job.options
                    o.range = nil; o.selectedEntries = nil; o.quality = .best
                    model.defaultOptions = o
                }
                .buttonStyle(.link).font(.caption)
                .disabled(job.options.kind == .clip || job.options.kind == .gif)
                Spacer()
            }
        }
    }

    private func mode(_ job: Job) -> Mode {
        switch job.options.kind {
        case .video: .video
        case .audio: .audio
        case .clip: .clip
        case .gif: .gif
        }
    }

    private func setMode(_ m: Mode, _ job: Job) {
        switch m {
        case .video: model.engine.updateOptions(job.id) { $0.kind = .video }
        case .audio:
            if job.info?.hasAudio == false {
                model.show(.info, "This video has no audio track to save.")
                return
            }
            model.engine.updateOptions(job.id) { $0.kind = .audio }
        case .clip, .gif, .frame:
            // Ranges and frames are chosen visually in the workspace; the job itself stays a full download
            // until the user exports a clip/GIF from there.
            model.openWorkspace(job.id, mode: m == .frame ? .frame : (m == .gif ? .gif : .clip))
            dismiss()
        }
    }

    @ViewBuilder private func videoControls(_ job: Job, _ info: MediaInfo?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let info, !info.qualityOptions.isEmpty {
                Picker("Quality", selection: Binding(
                    get: { qualityTag(job.options.quality) },
                    set: { tag in
                        model.engine.updateOptions(job.id) { o in
                            if tag == "best" { o.quality = .best }
                            else if let q = info.qualityOptions.first(where: { $0.id == tag }) {
                                o.quality = .option(id: q.id, height: q.height, fps: q.fps, formatIDs: q.formatIDs)
                            }
                        }
                    })) {
                    Text("Best available" + (info.bestQuality.map { " (\($0.label))" } ?? "")).tag("best")
                    Divider()
                    ForEach(info.qualityOptions) { q in
                        Text(qualityRow(q, job: job, info: info)).tag(q.id)
                    }
                }
            } else if info == nil {
                Text("Qualities appear after analysis.").font(.callout).foregroundStyle(.secondary)
            }

            Picker("File type", selection: Binding(
                get: { job.options.fileType },
                set: { t in model.engine.updateOptions(job.id) { $0.fileType = t } })) {
                ForEach(VideoFileType.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Codecs", selection: Binding(
                get: { job.options.container },
                set: { c in model.engine.updateOptions(job.id) { $0.container = c } })) {
                Text("Original (no re-encode)").tag(ContainerMode.bestQuality)
                Text("Compatible H.264 (plays everywhere)").tag(ContainerMode.compatibleMP4)
            }
            .pickerStyle(.radioGroup)
            Text(containerExplanation(job))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SizePicker(compression: Binding(
                get: { job.options.compression },
                set: { c in model.engine.updateOptions(job.id) { $0.compression = c } }),
                       estimate: { c in
                           guard let info = job.info else { return nil }
                           var o = job.options; o.kind = .video; o.compression = c
                           return SizeModel.video(info: info, options: o)
                       })
            if let info, info.hasVideo, !info.hasAudio {
                Label("This video has no audio track.", systemImage: "speaker.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func audioControls(_ job: Job, _ info: MediaInfo?) -> some View {
        if let info, !info.hasAudio {
            Label("No audio track available — this video is silent.", systemImage: "speaker.slash")
                .font(.callout).foregroundStyle(Theme.attention)
        } else {
            Picker("Audio", selection: Binding(
                get: { job.options.audioFormat },
                set: { f in model.engine.updateOptions(job.id) { $0.audioFormat = f } })) {
                Text("MP3").tag(AudioFormatChoice.mp3)
                Text("Original (no re-encode)").tag(AudioFormatChoice.original)
            }
            .pickerStyle(.radioGroup)
            if job.options.audioFormat == .original, let a = info?.bestAudio {
                Text("Keeps the source \(a.codecFamily) stream as-is.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("High-quality VBR MP3, plays everywhere.").font(.caption).foregroundStyle(.secondary)
            }
            if let info, let e = SizeModel.audio(info: info, mp3: job.options.audioFormat == .mp3) {
                Text("Estimated size: \(e.label)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func qualityTag(_ q: QualityChoice) -> String {
        if case .option(let id, _, _, _) = q { return id }
        return "best"
    }

    /// "1080p · 30 fps · ≈ 310 MB" — the size of the file you'd get with this quality and the current Size/codecs.
    private func qualityRow(_ q: QualityOption, job: Job, info: MediaInfo) -> String {
        var s = q.height.map { "\($0)p" } ?? "Unknown"
        if !q.fpsLabel.isEmpty { s += " · \(q.fpsLabel) fps" }
        if q.isHDR { s += " · HDR" }
        var o = job.options
        o.kind = .video
        o.quality = .option(id: q.id, height: q.height, fps: q.fps, formatIDs: q.formatIDs)
        if let e = SizeModel.video(info: info, options: o) { s += " · \(e.label)" }
        return s
    }

    private func containerExplanation(_ job: Job) -> String {
        let option: QualityOption? = {
            guard let info = job.info else { return nil }
            if case .option(let id, _, _, _) = job.options.quality { return info.qualityOptions.first { $0.id == id } }
            return info.bestQuality
        }()
        let codecs = option?.codecs ?? []
        switch job.options.container {
        case .bestQuality:
            let type = job.options.fileType.label
            if codecs.allSatisfy({ $0 == "H.264" || $0 == "HEVC" }) && !codecs.isEmpty {
                return "Keeps the original streams without re-encoding (\(type))."
            }
            if job.options.fileType == .mov {
                return "This quality is \(codecs.first ?? "not H.264"), which MOV can’t hold — it will be converted to H.264."
            }
            return "Keeps the original \(codecs.first ?? "") streams in \(type). QuickTime and Premiere can’t play \(codecs.first ?? "these codecs") — choose Compatible H.264 for editing apps."
        case .compatibleMP4:
            if codecs.contains("H.264") {
                let audio = job.info?.bestAudio?.codecFamily
                if audio == nil || audio == "AAC" { return "H.264 and AAC are available at this quality — no conversion needed." }
                return "H.264 is available at this quality; only the audio is converted to AAC (quick)."
            }
            var s = "This quality is \(codecs.first ?? "not H.264"); it will be converted to H.264 after downloading. Takes extra time and loses a little quality."
            if option?.isHDR == true { s += " HDR is tone-mapped to SDR." }
            return s
        }
    }
}

struct AdvancedDetails: View {
    let job: Job
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let info = job.info {
                let option: QualityOption? = {
                    if case .option(let id, _, _, _) = job.options.quality { return info.qualityOptions.first { $0.id == id } }
                    return info.bestQuality
                }()
                row("Video codec", option?.codecs.joined(separator: ", ") ?? "—")
                row("Dynamic range", option?.isHDR == true ? "HDR" : "SDR")
                row("Audio", info.bestAudio.map { "\($0.codecFamily)\($0.abr.map { " · \(Int($0)) kbps" } ?? "")" }
                    ?? (info.hasAudio ? "Included in video stream" : "None"))
                if let b = option?.estimatedBytes {
                    row("Estimated size", "\(option?.estimateIsRough == true ? "~" : "")\(ByteFormat.string(b)) (estimate)")
                }
                row("Format IDs", option?.formatIDs.prefix(4).joined(separator: ", ") ?? "—")
                row("Source", info.extractor ?? info.platform.displayName)
                Text("“Best available” is the best stream the site offers, not necessarily the uploader’s original file.")
                    .font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
            } else {
                Text("Details appear after analysis.").foregroundStyle(.secondary)
            }
            CookieRow(job: job)
        }
        .font(.caption)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(v).textSelection(.enabled)
        }
    }
}

/// Per-job opt-in browser login (never global).
struct CookieRow: View {
    @Environment(AppModel.self) private var model
    let job: Job
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Browser login").foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Picker("", selection: Binding(
                get: { if case .browser(let n, _) = job.cookies { return n } else { return "none" } },
                set: { v in model.engine.setCookies(job.id, v == "none" ? .none : .browser(name: v, profile: nil)) })) {
                Text("Off").tag("none")
                ForEach(CookieBrowsers.all, id: \.id) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(job.state.isActive)
        }
        .help("Only for content you’re allowed to view. Applies to this item only.")
    }
}

/// Multi-item post: explicit selection instead of silently downloading everything.
struct SelectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let jobID: UUID
    @State private var chosen: Set<Int> = []

    var body: some View {
        let job = model.engine.job(jobID)
        let entries = job?.info?.entries ?? []
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Choose items to download").font(.headline)
            Text(job?.info?.title ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            List(entries) { e in
                Toggle(isOn: Binding(get: { chosen.contains(e.index) },
                                     set: { if $0 { chosen.insert(e.index) } else { chosen.remove(e.index) } })) {
                    HStack(spacing: Theme.Space.s) {
                        Thumbnail(url: e.thumbnail, platform: job?.info?.platform)
                        VStack(alignment: .leading) {
                            Text(e.title ?? "Item \(e.index)").lineLimit(1)
                            Text([e.isVideo ? "Video" : "Image", Format.duration(e.duration)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!e.isVideo)
            }
            .frame(minHeight: 240)
            HStack {
                Button(chosen.count == entries.filter(\.isVideo).count ? "Select None" : "Select All Videos") {
                    if chosen.count == entries.filter(\.isVideo).count { chosen = [] }
                    else { chosen = Set(entries.filter(\.isVideo).map(\.index)) }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(chosen.count) Selected") {
                    model.engine.resolveSelection(jobID, entries: Array(chosen))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 480, height: 420)
    }
}
