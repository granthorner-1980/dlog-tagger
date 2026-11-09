// D-Log Tagger: pick a folder of DJI Osmo Pocket 4P clips, find which log
// profile each was shot in, and rename them  ..._D.MP4 -> ..._D_DLOG1.MP4
//
// Detection reads two markers the camera writes into every clip:
//   * the 'dbcm' tag in the file header (moov/udta/dbcm)
//   * field 2.2.3.1 of the first frame in DJI's metadata track ('djmd')
// Values were learned from sample clips (0090 = D-Log1, 0091 = D-Log2).

import AppKit
import SwiftUI

// MARK: - What the raw values mean

enum Profile: String {
    case dlog1 = "DLOG1", dlog2 = "DLOG2"
    var label: String { self == .dlog1 ? "D-Log1" : "D-Log2" }
    var color: Color { self == .dlog1 ? .orange : .blue }
}

let dbcmMap: [UInt64: Profile] = [5: .dlog1, 2: .dlog2]
let djmdMap: [UInt64: Profile] = [22: .dlog1, 2: .dlog2]
let videoExtensions: Set<String> = ["mp4", "mov"]

// MARK: - Minimal MP4 reader

struct Box { let type: String; let pos: UInt64; let hdr: UInt64; let size: UInt64
    var bodyStart: UInt64 { pos + hdr }
    var end: UInt64 { pos + size }
}

final class MP4File {
    private let handle: FileHandle
    let length: UInt64

    init?(url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url), let len = try? h.seekToEnd() else { return nil }
        handle = h
        length = len
    }
    deinit { try? handle.close() }

    func bytes(_ offset: UInt64, _ count: Int) -> [UInt8] {
        guard (try? handle.seek(toOffset: offset)) != nil else { return [] }
        return [UInt8]((try? handle.read(upToCount: count)) ?? Data())
    }

    func boxes(_ start: UInt64, _ end: UInt64) -> [Box] {
        var out: [Box] = []
        var pos = start
        while pos + 8 <= end {
            let h = bytes(pos, 16)
            guard h.count >= 8 else { break }
            var size = UInt64(be32(h, 0))
            var hdr: UInt64 = 8
            if size == 1 {
                guard h.count >= 16 else { break }
                size = be64(h, 8); hdr = 16
            } else if size == 0 {
                size = end - pos
            }
            // A box must fit inside its container. Corrupt files can claim sizes up to 2^64,
            // which would overflow the arithmetic below and crash the app.
            guard size >= hdr, size <= end - pos else { break }
            out.append(Box(type: String(decoding: h[4..<8], as: UTF8.self), pos: pos, hdr: hdr, size: size))
            pos += size
        }
        return out
    }

    func find(_ start: UInt64, _ end: UInt64, _ path: [String]) -> Box? {
        guard let first = path.first, let box = boxes(start, end).first(where: { $0.type == first }) else { return nil }
        return path.count == 1 ? box : find(box.bodyStart, box.end, Array(path.dropFirst()))
    }
}

func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
    b[i..<i + 4].reduce(0) { $0 << 8 | UInt32($1) }
}
func be64(_ b: [UInt8], _ i: Int) -> UInt64 {
    b[i..<i + 8].reduce(0) { $0 << 8 | UInt64($1) }
}

// MARK: - Minimal protobuf reader

func readVarint(_ b: [UInt8], _ i: inout Int) -> UInt64? {
    var result: UInt64 = 0, shift: UInt64 = 0
    while i < b.count, shift < 64 {
        let c = b[i]; i += 1
        result |= UInt64(c & 0x7F) << shift
        if c < 0x80 { return result }
        shift += 7
    }
    return nil
}

/// First varint at a nested field path such as [2, 2, 3, 1].
func protobufField(_ b: [UInt8], _ path: [UInt64]) -> UInt64? {
    var i = 0
    while i < b.count {
        guard let key = readVarint(b, &i) else { return nil }
        let num = key >> 3, wire = key & 7
        switch wire {
        case 0:
            guard let v = readVarint(b, &i) else { return nil }
            if num == path[0] && path.count == 1 { return v }
        case 1: i += 8
        case 5: i += 4
        case 2:
            guard let len = readVarint(b, &i), len <= UInt64(b.count - i) else { return nil }
            let chunk = Array(b[i..<i + Int(len)]); i += Int(len)
            if num == path[0] && path.count > 1 { return protobufField(chunk, Array(path.dropFirst())) }
        default: return nil
        }
    }
    return nil
}

// MARK: - Detection

struct Detection { let profile: Profile?; let dbcm: UInt64?; let djmd: UInt64? }

func detect(_ url: URL) -> Detection {
    guard let f = MP4File(url: url), let moov = f.find(0, f.length, ["moov"]) else {
        return Detection(profile: nil, dbcm: nil, djmd: nil)
    }
    var dbcm: UInt64?
    if let box = f.find(moov.bodyStart, moov.end, ["udta", "dbcm"]) {
        let b = f.bytes(box.bodyStart, 4)
        if b.count == 4 { dbcm = UInt64(be32(b, 0)) }
    }
    let djmd = readDjmd(f, moov)
    let a = dbcm.flatMap { dbcmMap[$0] }, b = djmd.flatMap { djmdMap[$0] }
    if let a, let b, a != b { return Detection(profile: nil, dbcm: dbcm, djmd: djmd) } // disagree: don't guess
    return Detection(profile: a ?? b, dbcm: dbcm, djmd: djmd)
}

func readDjmd(_ f: MP4File, _ moov: Box) -> UInt64? {
    for trak in f.boxes(moov.bodyStart, moov.end) where trak.type == "trak" {
        guard let stbl = f.find(trak.bodyStart, trak.end, ["mdia", "minf", "stbl"]),
              let stsd = f.find(stbl.bodyStart, stbl.end, ["stsd"]),
              f.bytes(stsd.bodyStart, 64).count >= 16,
              String(decoding: f.bytes(stsd.bodyStart, 64), as: UTF8.self).contains("djmd")
        else { continue }
        guard let stsz = f.find(stbl.bodyStart, stbl.end, ["stsz"]) else { return nil }
        var chunk = f.find(stbl.bodyStart, stbl.end, ["stco"]), is64 = false
        if chunk == nil { chunk = f.find(stbl.bodyStart, stbl.end, ["co64"]); is64 = true }
        guard let chunk else { return nil }
        let sz = f.bytes(stsz.bodyStart, 16)
        guard sz.count == 16 else { return nil }
        var sampleSize = UInt64(be32(sz, 4))
        if sampleSize == 0 { sampleSize = UInt64(be32(sz, 12)) }
        let co = f.bytes(chunk.bodyStart + 8, 8)
        guard co.count == 8, sampleSize > 0, sampleSize < 10_000_000 else { return nil }
        let offset = is64 ? be64(co, 0) : UInt64(be32(co, 0))
        return protobufField(f.bytes(offset, Int(sampleSize)), [2, 2, 3, 1])
    }
    return nil
}

// MARK: - Finder tags
// Stored in the com.apple.metadata:_kMDItemUserTags extended attribute as a
// binary plist of "Name\n<colour index>" strings (4 = blue, 7 = orange).

let tagAttribute = "com.apple.metadata:_kMDItemUserTags"
let ourTagNames: Set<String> = ["D-Log1", "D-Log2"]

extension Profile {
    var finderTag: String { "\(label)\n\(self == .dlog1 ? 7 : 4)" }
}

func tagName(_ raw: String) -> String { String(raw.split(separator: "\n").first ?? "") }

func readFinderTags(_ url: URL) -> [String] {
    url.withUnsafeFileSystemRepresentation { path -> [String] in
        guard let path else { return [] }
        let size = getxattr(path, tagAttribute, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, tagAttribute, $0.baseAddress, size, 0, 0) }
        guard read == size else { return [] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] ?? []
    }
}

func hasFinderTag(_ url: URL, _ profile: Profile) -> Bool {
    readFinderTags(url).contains { tagName($0) == profile.label }
}

/// Adds our tag, replacing any other D-Log tag but keeping the user's own tags.
func applyFinderTag(_ url: URL, _ profile: Profile) throws {
    var tags = readFinderTags(url).filter { !ourTagNames.contains(tagName($0)) }
    tags.append(profile.finderTag)
    let data = try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return data.withUnsafeBytes { setxattr(path, tagAttribute, $0.baseAddress, data.count, 0, 0) }
    }
    if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

func hasAnyOurTag(_ url: URL) -> Bool {
    readFinderTags(url).contains { ourTagNames.contains(tagName($0)) }
}

/// Removes D-Log1/D-Log2 tags, keeping any other tags the user added.
func removeOurFinderTags(_ url: URL) throws {
    let all = readFinderTags(url)
    let kept = all.filter { !ourTagNames.contains(tagName($0)) }
    guard kept.count != all.count else { return }
    let result: Int32
    if kept.isEmpty {
        result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return removexattr(path, tagAttribute, 0)
        }
    } else {
        let data = try PropertyListSerialization.data(fromPropertyList: kept, format: .binary, options: 0)
        result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return data.withUnsafeBytes { setxattr(path, tagAttribute, $0.baseAddress, data.count, 0, 0) }
        }
    }
    if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

// MARK: - Clips and renaming

enum ClipStatus: Equatable {
    case pending(rename: String?, tag: Bool)   // work still to do
    case upToDate                              // already renamed and tagged
    case unknown                               // not a recognised log clip
    case done(String)                          // what we just did
    case failed(String)
}

struct Clip: Identifiable {
    let id = UUID()
    var url: URL
    let detection: Detection
    var status: ClipStatus
    var restorable = false          // has our suffix or our Finder tag
    var name: String { url.lastPathComponent }
}

/// One clip changed by Rename & Tag, so it can be undone exactly.
struct UndoStep { let original: URL; let current: URL; let removeTag: Bool }

/// "DJI_..._D_DLOG1.MP4" -> "DJI_..._D.MP4"; nil if the name has no suffix of ours.
func originalName(for filename: String) -> String? {
    guard isTagged(filename) else { return nil }
    let url = URL(fileURLWithPath: filename)
    let ext = url.pathExtension
    let base = String(url.deletingPathExtension().lastPathComponent.dropLast("_DLOG1".count))
    return ext.isEmpty ? base : "\(base).\(ext)"
}

func newName(for filename: String, _ profile: Profile) -> String {
    let url = URL(fileURLWithPath: filename)
    let ext = url.pathExtension, stem = url.deletingPathExtension().lastPathComponent
    return ext.isEmpty ? "\(stem)_\(profile.rawValue)" : "\(stem)_\(profile.rawValue).\(ext)"
}

func isTagged(_ filename: String) -> Bool {
    let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent.uppercased()
    return stem.hasSuffix("_DLOG1") || stem.hasSuffix("_DLOG2")
}

func findVideos(in folder: URL) -> [URL] {
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return [] }
    return e.compactMap { $0 as? URL }
        .filter { videoExtensions.contains($0.pathExtension.lowercased()) }
        .filter { (try? $0.resourceValues(forKeys: Set(keys)).isRegularFile) == true }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
}

func scan(_ folder: URL) -> [Clip] {
    findVideos(in: folder).map { url in
        let d = detect(url)
        let status: ClipStatus
        if let p = d.profile {
            let rename = isTagged(url.lastPathComponent) ? nil : newName(for: url.lastPathComponent, p)
            let tag = !hasFinderTag(url, p)
            status = (rename == nil && !tag) ? .upToDate : .pending(rename: rename, tag: tag)
        } else {
            status = .unknown
        }
        return Clip(url: url, detection: d, status: status,
                    restorable: isTagged(url.lastPathComponent) || hasAnyOurTag(url))
    }
}

// MARK: - App state

@MainActor
final class Model: ObservableObject {
    @Published var folder: URL?
    @Published var clips: [Clip] = []
    @Published var busy = false
    @Published var hasScanned = false
    @Published var lastBatch: [UndoStep] = []     // what the last Rename & Tag changed
    @Published var notice: String?                // shown in place of the summary after undo/restore

    var toRename: Int { clips.filter { if case .pending = $0.status { true } else { false } }.count }
    var toRestore: Int { clips.filter(\.restorable).count }
    var canUndo: Bool { !lastBatch.isEmpty && !busy }

    var summary: String {
        guard hasScanned else {
            return busy ? "Looking for clips…" : "Choose the folder you offloaded your clips into."
        }
        if clips.isEmpty { return "No .MP4 or .MOV files in this folder." }
        let d1 = clips.filter { $0.detection.profile == .dlog1 }.count
        let d2 = clips.filter { $0.detection.profile == .dlog2 }.count
        let other = clips.count - d1 - d2
        var s = "\(clips.count) clips: \(d1) D-Log1, \(d2) D-Log2"
        if other > 0 { s += ", \(other) not recognised (left as is)" }
        return s
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder where you offloaded your clips"
        if let f = folder { panel.directoryURL = f }
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            clips = []
            hasScanned = false
            lastBatch = []
            notice = nil
            find()
        }
    }

    func find() {
        guard let folder else { return }
        busy = true
        Task {
            let result = await Task.detached { scan(folder) }.value
            guard self.folder == folder else { return }   // a newer folder was chosen meanwhile
            clips = result
            hasScanned = true
            busy = false
        }
    }

    func rename() {
        let fm = FileManager.default
        var steps: [UndoStep] = []
        notice = nil
        for i in clips.indices {
            guard case .pending(let rename, let tag) = clips[i].status,
                  let profile = clips[i].detection.profile else { continue }
            var url = clips[i].url
            if let name = rename {
                let dest = url.deletingLastPathComponent().appendingPathComponent(name)
                if fm.fileExists(atPath: dest.path) {
                    clips[i].status = .failed("\(name) already exists")
                    continue
                }
                do { try fm.moveItem(at: url, to: dest); url = dest }
                catch { clips[i].status = .failed(error.localizedDescription); continue }
            }
            if tag {
                do { try applyFinderTag(url, profile) }
                catch {
                    if url != clips[i].url {
                        steps.append(UndoStep(original: clips[i].url, current: url, removeTag: false))
                        clips[i].url = url
                        clips[i].restorable = true
                    }
                    clips[i].status = .failed((rename.map { "Renamed to \($0), but " } ?? "") + "couldn't add tag")
                    continue
                }
            }
            steps.append(UndoStep(original: clips[i].url, current: url, removeTag: tag))
            clips[i].url = url              // show the new name straight away
            clips[i].restorable = true      // so Restore Originals works without a rescan
            switch (rename != nil, tag) {
            case (true, true): clips[i].status = .done("Renamed + tagged")
            case (true, false): clips[i].status = .done("Renamed")
            default: clips[i].status = .done("Tagged")
            }
        }
        lastBatch = steps
    }

    /// Reverses exactly what the last Rename & Tag did.
    func undo() {
        guard canUndo else { return }
        let fm = FileManager.default
        var problems = 0
        for step in lastBatch.reversed() {
            if step.removeTag { do { try removeOurFinderTags(step.current) } catch { problems += 1 } }
            guard step.current != step.original else { continue }
            if fm.fileExists(atPath: step.original.path) { problems += 1; continue }
            do { try fm.moveItem(at: step.current, to: step.original) } catch { problems += 1 }
        }
        let n = lastBatch.count
        lastBatch = []
        notice = problems == 0
            ? "Undone: \(n == 1 ? "1 clip is" : "\(n) clips are") back to how \(n == 1 ? "it was" : "they were")."
            : "Undone, but \(problems) change\(problems == 1 ? "" : "s") couldn't be reversed (a file with the original name already exists)."
        find()
    }

    /// Puts every clip in the folder back to its original name and removes our tags.
    func restoreOriginals() {
        let fm = FileManager.default
        var restored = 0, problems = 0
        for clip in clips where clip.restorable {
            // check for a name clash first, so a clip is never left half-restored
            let dest = originalName(for: clip.name).map { clip.url.deletingLastPathComponent().appendingPathComponent($0) }
            if let dest, fm.fileExists(atPath: dest.path) { problems += 1; continue }
            if hasAnyOurTag(clip.url) {
                do { try removeOurFinderTags(clip.url) } catch { problems += 1; continue }
            }
            if let dest {
                do { try fm.moveItem(at: clip.url, to: dest) } catch { problems += 1; continue }
            }
            restored += 1
        }
        lastBatch = []
        notice = "Restored \(restored) clip\(restored == 1 ? "" : "s") to the original name"
            + (problems > 0 ? ". \(problems) couldn't be restored (a file with the original name already exists)." : ".")
        find()
    }
}

// MARK: - UI

struct ProfileBadge: View {
    let profile: Profile?
    var body: some View {
        if let profile {
            Text(profile.label)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(profile.color.opacity(0.18), in: Capsule())
                .foregroundStyle(profile.color)
        } else {
            Text("Unknown").font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct StatusText: View {
    let clip: Clip
    var body: some View {
        switch clip.status {
        case .pending(let n?, let tag):
            Text("Add _\(clip.detection.profile?.rawValue ?? "") to name" + (tag ? " + Finder tag" : ""))
                .help("New name: \(n)")
        case .pending(nil, _): Text("Add Finder tag")
        case .upToDate: Text("Already renamed and tagged").foregroundStyle(.secondary)
        case .unknown:
            Text("Left as is (dbcm \(clip.detection.dbcm.map(String.init) ?? "–"), djmd \(clip.detection.djmd.map(String.init) ?? "–"))")
                .foregroundStyle(.secondary)
        case .done(let n): Label(n, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let why): Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: Model
    @State private var confirmRestore = false
    @State private var selection = Set<Clip.ID>()

    /// Opens Finder with these clips selected (each in its own folder).
    private func reveal(_ ids: Set<Clip.ID>) {
        let urls = model.clips.filter { ids.contains($0.id) }.map(\.url)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(model.folder?.lastPathComponent ?? "No folder chosen")
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(model.folder == nil ? .secondary : .primary)
                    .help(model.folder?.path ?? "")
                Spacer()
                Button { if let f = model.folder { NSWorkspace.shared.open(f) } } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Open this folder in Finder")
                .disabled(model.folder == nil)
                Button("Choose Folder…") { model.chooseFolder() }
            }

            HStack {
                Button { model.find() } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                    .help("Look through the folder again, e.g. after adding more clips")
                    .disabled(model.folder == nil || model.busy)
                    .controlSize(.large)
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button { confirmRestore = true } label: {
                    Label("Restore Originals…", systemImage: "arrow.uturn.backward")
                }
                .help("Put every clip in this folder back to its original name and remove the D-Log tags")
                .controlSize(.large)
                .disabled(model.toRestore == 0 || model.busy)
                if model.canUndo {
                    Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward.circle") }
                        .help("Reverse the last Rename & Tag (⌘Z)")
                        .controlSize(.large)
                }
                Button { model.rename() } label: {
                    Label(model.toRename == 0 ? "Rename & Tag"
                          : model.toRename == 1 ? "Rename & Tag 1 Clip" : "Rename & Tag \(model.toRename) Clips",
                          systemImage: "pencil")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.toRename == 0 || model.busy)
            }

            Table(model.clips, selection: $selection) {
                TableColumn("Clip") { Text($0.name).lineLimit(1).truncationMode(.middle) }
                    .width(min: 180, ideal: 260)
                TableColumn("Shot in") { ProfileBadge(profile: $0.detection.profile) }
                    .width(90)
                TableColumn("Result") { StatusText(clip: $0).lineLimit(1).truncationMode(.middle) }
            }
            .contextMenu(forSelectionType: Clip.ID.self) { ids in
                Button(ids.count > 1 ? "Show \(ids.count) Clips in Finder" : "Show in Finder") { reveal(ids) }
                    .disabled(ids.isEmpty)
            } primaryAction: { ids in
                reveal(ids)                 // double-click a clip
            }

            HStack {
                if let notice = model.notice {
                    Label(notice, systemImage: "arrow.uturn.backward.circle.fill").foregroundStyle(.secondary)
                } else {
                    Text(model.summary).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Rename before importing into DaVinci Resolve.")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 440)
        .confirmationDialog(
            "Put \(model.toRestore == 1 ? "1 clip" : "\(model.toRestore) clips") back to the original \(model.toRestore == 1 ? "name" : "names")?",
            isPresented: $confirmRestore
        ) {
            Button("Restore Originals") { model.restoreOriginals() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes _DLOG1 / _DLOG2 from the filenames in this folder and removes the D-Log Finder tags. Your own tags are kept. You can Rename & Tag again at any time.")
        }
        .task {
            // Optional: open with a folder already chosen (DLogTagger --folder <path>)
            if let i = CommandLine.arguments.firstIndex(of: "--folder"), i + 1 < CommandLine.arguments.count,
               model.folder == nil {
                model.folder = URL(fileURLWithPath: CommandLine.arguments[i + 1])
                model.find()
            }
        }
    }
}

struct DLogTaggerApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        Window("D-Log Tagger", id: "main") { ContentView(model: model) }
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .undoRedo) {
                    Button("Undo Rename & Tag") { model.undo() }
                        .keyboardShortcut("z", modifiers: .command)
                        .disabled(!model.canUndo)
                }
            }
    }
}

// MARK: - Entry point (with a hidden test mode: DLogTagger --detect file...)

let args = CommandLine.arguments
if args.count > 2 && args[1] == "--detect" {
    for path in args.dropFirst(2) {
        let d = detect(URL(fileURLWithPath: path))
        print("\(d.profile?.rawValue ?? "UNKNOWN")\tdbcm=\(d.dbcm.map(String.init) ?? "nil")\tdjmd=\(d.djmd.map(String.init) ?? "nil")\t\(path)")
    }
    exit(0)
}
DLogTaggerApp.main()
