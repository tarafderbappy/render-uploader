import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

// MARK: - Model

struct UploadRecord: Codable, Identifiable {
    var id = UUID()
    var name: String
    var date: Date
}

struct SavedState: Codable {
    var ledger: [String] = []
    var recent: [UploadRecord] = []
}

enum Status { case idle, uploading, paused, waiting }

// MARK: - Engine

final class Engine: ObservableObject {
    static let defaultSource = "/Volumes/Bappy/My Works 2025/2026/October/Rach/Exports"
    static let defaultDest = "/Users/tarafderbappy/Library/CloudStorage/GoogleDrive-bappyinwork@gmail.com/My Drive/Rach/Oct"

    @Published var status: Status = .idle
    @Published var currentName = ""
    @Published var progress: Double = 0
    @Published var recent: [UploadRecord] = []
    @Published var paused: Bool
    @Published var sourcePath: String
    @Published var destPath: String

    private var ledger = Set<String>()
    private var lastSizes: [String: Int64] = [:]
    private let queue = DispatchQueue(label: "renderuploader.engine")
    private var busy = false
    private var timer: Timer?
    private let videoExts: Set<String> = ["mp4", "mov", "mkv", "webm", "m4v"]
    private let defaults = UserDefaults.standard

    private var stateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RenderUploader", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("state.json")
    }

    init() {
        paused = defaults.bool(forKey: "paused")
        sourcePath = defaults.string(forKey: "sourcePath") ?? Engine.defaultSource
        destPath = defaults.string(forKey: "destPath") ?? Engine.defaultDest
        if let data = try? Data(contentsOf: stateURL),
           let s = try? JSONDecoder().decode(SavedState.self, from: data) {
            ledger = Set(s.ledger)
            recent = s.recent
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        if !defaults.bool(forKey: "didFirstRun") {
            defaults.set(true, forKey: "didFirstRun")
            try? SMAppService.mainApp.register()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.scan() }
        scan()
    }

    // MARK: Controls

    func togglePause() {
        paused.toggle()
        defaults.set(paused, forKey: "paused")
        if paused { status = .paused }
        scan()
    }

    func chooseFolder(source: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = source ? "Choose the folder where Faceless Motion saves finished videos"
                               : "Choose the Google Drive folder to upload into"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            if source {
                sourcePath = url.path
                defaults.set(url.path, forKey: "sourcePath")
            } else {
                destPath = url.path
                defaults.set(url.path, forKey: "destPath")
            }
            lastSizes = [:]
            scan()
        }
    }

    func open(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: Scanning

    func scan() {
        queue.async { [weak self] in self?.doScan() }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    private func isFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func doScan() {
        if busy { return }
        busy = true
        defer { busy = false }

        let src = sourcePath
        let dst = destPath
        guard isFolder(src), isFolder(dst) else {
            onMain { self.status = .waiting }
            return
        }
        if paused {
            onMain { self.status = .paused }
            return
        }
        onMain { if self.status != .uploading { self.status = .idle } }

        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: src),
                                                 includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles])) ?? []

        for file in files where videoExts.contains(file.pathExtension.lowercased()) {
            if paused { break }
            let name = file.lastPathComponent
            let size = fileSize(file)
            if size <= 0 { continue }
            let key = "\(name)|\(size)"
            if ledger.contains(key) { continue }

            // A render is finished when its size is the same on two checks in a row
            // and it hasn't been modified for a little while.
            if lastSizes[name] != size { lastSizes[name] = size; continue }
            let mod = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? Date()
            if Date().timeIntervalSince(mod) < 20 { continue }

            let target = URL(fileURLWithPath: dst).appendingPathComponent(name)
            if fileSize(target) == size {
                ledger.insert(key)
                save()
                continue
            }
            upload(file, to: target, size: size, key: key)
        }
        onMain { if self.status == .uploading { self.status = .idle } }
    }

    private func upload(_ file: URL, to target: URL, size: Int64, key: String) {
        let fm = FileManager.default
        let name = file.lastPathComponent
        let tmp = target.deletingLastPathComponent().appendingPathComponent(".\(name).part")
        try? fm.removeItem(at: tmp)

        onMain {
            self.currentName = name
            self.progress = 0
            self.status = .uploading
        }

        var copyError: Error?
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            do { try fm.copyItem(at: file, to: tmp) } catch { copyError = error }
            group.leave()
        }
        while group.wait(timeout: .now() + 0.5) == .timedOut {
            let done = max(0, self.fileSize(tmp))
            let p = Double(done) / Double(size)
            self.onMain { self.progress = min(p, 1) }
        }

        var ok = false
        if copyError == nil, fileSize(tmp) == size {
            try? fm.removeItem(at: target)
            do { try fm.moveItem(at: tmp, to: target); ok = true } catch { ok = false }
        }

        if ok {
            ledger.insert(key)
            let record = UploadRecord(name: name, date: Date())
            onMain {
                self.recent.insert(record, at: 0)
                if self.recent.count > 50 { self.recent.removeLast(self.recent.count - 50) }
                self.progress = 1
                self.save()
            }
            notify("Uploaded to Drive", name)
        } else {
            try? fm.removeItem(at: tmp)
            lastSizes[name] = nil   // try again on a later check
            notify("Upload failed, will retry", name)
        }
    }

    private func save() {
        let state = SavedState(ledger: Array(ledger), recent: recent)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL)
        }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    var iconName: String {
        switch status {
        case .idle: return "arrow.up.circle"
        case .uploading: return "arrow.up.circle.fill"
        case .paused: return "pause.circle"
        case .waiting: return "exclamationmark.circle"
        }
    }

    var uploadedToday: Int {
        recent.filter { Calendar.current.isDateInToday($0.date) }.count
    }
}

// MARK: - UI

private func shortPath(_ path: String) -> String {
    path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}

private func relative(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: Date())
}

struct FolderRow: View {
    let label: String
    let path: String
    let onOpen: () -> Void
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Open", action: onOpen).buttonStyle(.link).font(.system(size: 12))
                Button("Change…", action: onChange).buttonStyle(.link).font(.system(size: 12))
            }
            Text(shortPath(path))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct PopoverView: View {
    @ObservedObject var e: Engine
    @State private var loginOn = (SMAppService.mainApp.status == .enabled)

    private var title: String {
        switch e.status {
        case .idle: return "Watching for new videos"
        case .uploading: return "Uploading to Drive"
        case .paused: return "Paused"
        case .waiting: return "Waiting for folders"
        }
    }

    private var detail: String {
        switch e.status {
        case .idle:
            let n = e.uploadedToday
            return n == 0 ? "Nothing uploaded yet today" : "\(n) uploaded today"
        case .uploading: return e.currentName
        case .paused: return "New videos are ignored until you resume"
        case .waiting: return "Check that the Bappy drive and Google Drive are connected"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if e.status == .uploading {
                    ProgressView(value: e.progress).padding(.top, 2)
                }
            }
            .padding(14)

            Divider()

            // Recent
            VStack(alignment: .leading, spacing: 8) {
                Text("RECENT")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                if e.recent.isEmpty {
                    Text("Uploaded videos will appear here.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(e.recent.prefix(5)) { r in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.green)
                            Text(r.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(relative(r.date))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(14)

            Divider()

            // Folders
            VStack(alignment: .leading, spacing: 10) {
                FolderRow(label: "Videos come from", path: e.sourcePath,
                          onOpen: { e.open(path: e.sourcePath) },
                          onChange: { e.chooseFolder(source: true) })
                FolderRow(label: "Uploaded to", path: e.destPath,
                          onOpen: { e.open(path: e.destPath) },
                          onChange: { e.chooseFolder(source: false) })
            }
            .padding(14)

            Divider()

            // Actions
            HStack {
                Button(e.paused ? "Resume" : "Pause") { e.togglePause() }
                Button("Check now") { e.scan() }
                Spacer()
                Toggle("Open at login", isOn: Binding(
                    get: { loginOn },
                    set: { on in
                        if on { try? SMAppService.mainApp.register() }
                        else { try? SMAppService.mainApp.unregister() }
                        loginOn = (SMAppService.mainApp.status == .enabled)
                    }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
            .padding(14)

            Divider()

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) }
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

@main
struct RenderUploaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine = Engine()

    var body: some Scene {
        Window("Render Uploader", id: "main") {
            PopoverView(e: engine)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            PopoverView(e: engine)
        } label: {
            Image(systemName: engine.iconName)
        }
        .menuBarExtraStyle(.window)
    }
}
