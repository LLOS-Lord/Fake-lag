import SwiftUI
import UIKit

// FIXED: log viewer with real copy support + detail controls.
//  * Selectable UITextView (long-press → select/copy, Select All) instead of a
//    non-interactive SwiftUI Text.
//  * "Copy All" button → UIPasteboard in one tap.
//  * "Share…" button → UIActivityViewController (AirDrop / Files / Notes...).
//  * Keyword filter, auto-scroll-to-bottom toggle, live refresh every 1s.
struct LogsView: View {
    @State private var logs: String = ""
    @State private var filter: String = ""
    @State private var autoScroll = true
    @State private var showShare = false
    @State private var shareText: String = ""
    @State private var timer: Timer?
    @State private var copiedToast = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("All Actions Log").font(.headline)
                Spacer()
                Text("\(displayedLines) lines").font(.caption2).foregroundColor(.secondary)
            }
            .padding(.horizontal)

            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Filter (từ khoá)", text: $filter)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    if !filter.isEmpty {
                        Button(action: { filter = "" }) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    }
                }
                .padding(6)
                .background(Color(.systemGray6))
                .cornerRadius(8)

                Button(action: { load() }) {
                    Image(systemName: "arrow.clockwise")
                }.padding(6).background(Color(.systemGray6)).cornerRadius(8)

                Button(action: clearLogs) {
                    Image(systemName: "trash")
                }.padding(6).background(Color(.systemGray6)).cornerRadius(8)
            }
            .padding(.horizontal)

            SelectableLogTextView(text: logs, autoScroll: autoScroll)
                .background(Color(.systemGray6))
                .cornerRadius(8)
                .padding(.horizontal)

            HStack(spacing: 12) {
                Button(action: copyAll) {
                    HStack {
                        Image(systemName: copiedToast ? "checkmark" : "doc.on.doc")
                        Text(copiedToast ? "Copied!" : "Copy All")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }

                Button(action: { shareText = logs; showShare = true }) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share…")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary)
                    .cornerRadius(8)
                }

                Toggle("Auto", isOn: $autoScroll)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .navigationTitle("Logs")
        .onAppear {
            load()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in load() }
        }
        .onDisappear { timer?.invalidate() }
        .sheet(isPresented: $showShare) {
            if let url = exportToTemporaryFile(shareText) {
                ActivityShareSheet(items: [url])
            } else if !shareText.isEmpty {
                ActivityShareSheet(items: [shareText])
            }
        }
    }

    private var displayedLines: Int {
        logs.components(separatedBy: "\n").filter { !$0.isEmpty }.count
    }

    private func load() {
        logs = AppGroupStore.readLogs(filter: filter.isEmpty ? nil : filter)
    }

    private func copyAll() {
        UIPasteboard.general.string = logs
        copiedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedToast = false }
        AppGroupStore.logAction("LOGS_COPIED", details: "\(displayedLines) lines → clipboard")
    }

    private func clearLogs() {
        AppGroupStore.clearLogs()
        load()
    }

    private func exportToTemporaryFile(_ text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PacketBlocker-log-\(Int(Date().timeIntervalSince1970)).log")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

// UIKit bridge: selectable, scrollable, monospaced log text.
struct SelectableLogTextView: UIViewRepresentable {
    let text: String
    let autoScroll: Bool

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true                       // ← copy/select works now
        tv.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.backgroundColor = .clear
        tv.showsVerticalScrollIndicator = true
        tv.layer.cornerRadius = 8
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let wasAtBottom = uiView.contentSize.height - uiView.contentOffset.y - uiView.bounds.height < 60
        if uiView.text != text {
            uiView.text = text
        }
        if autoScroll && wasAtBottom {
            let bottom = NSRange(location: (text as NSString).length, length: 0)
            uiView.scrollRangeToVisible(bottom)
        }
    }
}

// UIKit share sheet bridge.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiView: UIActivityViewController, context: Context) {}
}
