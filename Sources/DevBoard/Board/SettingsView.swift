import AppKit
import ScreenCaptureKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var displays: [(UInt32, String)] = []

    var body: some View {
        @Bindable var s = model.settings
        ScrollView {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    group("Instant replay & recording", "memories") {
                        Toggle("Keep an instant replay buffer", isOn: Binding(get: { s.replayEnabled }, set: { _ in model.perform(.toggleReplay) }))
                        Picker("Replay length", selection: $s.replaySeconds) {
                            ForEach([15, 30, 60, 120], id: \.self) { Text("\($0) seconds").tag($0) }
                        }
                        Picker("Quality", selection: $s.quality) {
                            ForEach(ReplayQuality.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Frame rate", selection: $s.fps) {
                            Text("30 fps").tag(30)
                            Text("60 fps").tag(60)
                        }
                        Picker("Display", selection: $s.displayID) {
                            Text("Main display").tag(UInt32(0))
                            ForEach(displays, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        Toggle("Record system audio", isOn: $s.systemAudio)
                        Toggle("Record microphone", isOn: $s.microphone)
                        Toggle("Show cursor", isOn: $s.showCursor)
                        Toggle("Hide DevBoard from captures", isOn: $s.hideSelfInCaptures)
                        note("The replay buffer is hardware-encoded straight to short files on disk, so it uses very little memory. Older footage is deleted as it ages out.")
                    }
                    group("Screenshots", "camera.viewfinder") {
                        Toggle("Copy screenshots to the clipboard", isOn: $s.copyScreenshots)
                        HStack {
                            Text("Saved to")
                            Spacer()
                            Button("~/Movies/DevBoard") { NSWorkspace.shared.open(model.library.root) }
                                .buttonStyle(.link)
                        }
                    }
                }
                VStack(spacing: 14) {
                    group("School (DayMap)", "graduationcap") {
                        HStack {
                            Text("DayMap address")
                            Spacer()
                            TextField("https://yourschool.eq.daymap.net", text: $s.daymapURL)
                                .textFieldStyle(.roundedBorder).frame(width: 250)
                                .onSubmit { model.daymap.syncNow() }
                        }
                        Toggle("Remind me before tasks are due", isOn: $s.schoolReminders)
                        Toggle("Remind me 5 min before each class", isOn: $s.lessonReminders)
                            .disabled(!s.schoolReminders)
                        HStack {
                            if model.daymap.status == .signedOut {
                                Button("Sign in to DayMap") { model.daymap.signIn() }
                            } else {
                                Button("Sync now") { model.daymap.syncNow() }
                                Button("Sign out") { Task { await model.daymap.signOut() } }
                            }
                            Spacer()
                        }
                        note("Syncs every 20 minutes through your own DayMap sign-in, inside DevBoard. Your password is never stored; only the DayMap session, in ~/Library/Application Support/DevBoard.")
                    }
                    group("Agents", "sparkles.rectangle.stack") {
                        Toggle("Notify when an agent finishes", isOn: $s.agentNotifications)
                        Picker("Show agents active in the last", selection: $s.agentWindowMinutes) {
                            ForEach([10, 30, 60, 180], id: \.self) { Text($0 < 60 ? "\($0) min" : "\($0 / 60) h").tag($0) }
                        }
                        note("Reads omp transcripts in ~/.omp/agent/sessions. Nothing leaves your Mac.")
                    }
                    group("General", "gearshape") {
                        Toggle("Open at login", isOn: $s.launchAtLogin)
                        HStack {
                            Text("Memory used by DevBoard")
                            Spacer()
                            Text(Fmt.bytes(selfFootprint())).monospacedDigit().foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Quit DevBoard", role: .destructive) { model.perform(.quit) }
                            Spacer()
                            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    group("Shortcuts", "command") {
                        shortcut("⌥⇧D", "Open / close DevBoard")
                        shortcut("⌥⇧A", "Agents")
                        shortcut("⌥⇧L", "School")
                        shortcut("⌥⇧F", "Files: shelf & search")
                        shortcut("⌥⇧M", "Monitor")
                        shortcut("⌥⇧C", "Clips")
                        shortcut("⌥⇧S", "Screenshot (region)")
                        shortcut("⌥⇧R", "Start / stop recording")
                        shortcut("⌥⇧X", "Save instant replay")
                        shortcut("⌥⇧H", "Hide / show the island")
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.never)
        .onChange(of: s.replaySeconds) { _, _ in Task { await model.capture.syncStream() } }
        .onChange(of: s.quality) { _, _ in Task { await model.capture.syncStream() } }
        .onChange(of: s.fps) { _, _ in Task { await model.capture.syncStream() } }
        .onChange(of: s.displayID) { _, _ in Task { await model.capture.syncStream() } }
        .onChange(of: s.systemAudio) { _, _ in Task { await model.capture.syncStream() } }
        .onChange(of: s.microphone) { _, _ in Task { await model.capture.syncStream() } }
        .onChange(of: s.showCursor) { _, _ in Task { await model.capture.syncStream() } }
        .onChange(of: s.hideSelfInCaptures) { _, _ in Task { await model.capture.syncStream() } }
        .onChange(of: s.agentWindowMinutes) { _, v in model.agents.windowMinutes = v }
        .task { await loadDisplays() }
    }

    private func group<C: View>(_ title: String, _ symbol: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, symbol: symbol)
            VStack(alignment: .leading, spacing: 9) { content() }
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 22)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func shortcut(_ keys: String, _ label: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(keys)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.1)))
        }
    }

    private func loadDisplays() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        displays = content.displays.map { d in
            let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID }?
                .localizedName ?? "Display \(d.displayID)"
            return (d.displayID, "\(name) (\(d.width)×\(d.height))")
        }
    }

    private func selfFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
