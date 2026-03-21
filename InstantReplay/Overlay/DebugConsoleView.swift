import SwiftUI
import UIKit

struct DebugConsoleView: View {
    @Binding var isVisible: Bool
    @State private var logText: String = ""
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text("Debug Console")
                    .font(.system(.headline, design: .monospaced))
                    .foregroundColor(.green)

                Spacer()

                Button {
                    shareLog()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 8)

                Button {
                    copyLog()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 8)

                Button {
                    DebugLog.shared.clear()
                    refreshLog()
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 8)

                Button {
                    isVisible = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.9))

            // Log content
            ScrollViewReader { proxy in
                ScrollView {
                    Text(logText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("logContent")
                }
                .onChange(of: logText) { _, _ in
                    withAnimation {
                        proxy.scrollTo("logContent", anchor: .bottom)
                    }
                }
            }
            .background(Color.black.opacity(0.85))
        }
        .onAppear {
            refreshLog()
            startRefreshTimer()
        }
        .onDisappear {
            stopRefreshTimer()
        }
    }

    private func refreshLog() {
        logText = DebugLog.shared.formattedLog()
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            refreshLog()
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func copyLog() {
        UIPasteboard.general.string = DebugLog.shared.formattedLog()
    }

    private func shareLog() {
        let log = DebugLog.shared.formattedLog()
        let activityVC = UIActivityViewController(activityItems: [log], applicationActivities: nil)

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            // Handle iPad popover presentation
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = rootVC.view
                popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: 100, width: 0, height: 0)
            }
            rootVC.present(activityVC, animated: true)
        }
    }
}
