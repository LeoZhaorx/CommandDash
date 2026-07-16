import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CommandDash")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("打开") { openMainWindow() }
                    .buttonStyle(GlassCapsuleButtonStyle())
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(appState.commands) { command in
                        Button {
                            appState.run(command: command)
                        } label: {
                            HStack {
                                Text(command.name)
                                    .font(.system(size: 12))
                                Spacer()
                                Image(systemName: "play.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 260, height: 360)
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
