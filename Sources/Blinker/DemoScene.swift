import AppKit
import SwiftUI

/// A mock desktop for README images: the menu bar with Blinker's green icon, the open menu, and
/// the notification it posts. Only drawn by `--snapshot --demo --scene`, always with made-up data.
struct DemoScene: View {
    @EnvironmentObject var store: Store
    let dark: Bool

    static let size = CGSize(width: 1200, height: 320)
    /// Where Blinker's icon sits in the menu bar; the menu opens centered under it.
    private let iconX: CGFloat = 640
    private let menuBarHeight: CGFloat = 30

    var body: some View {
        ZStack(alignment: .topLeading) {
            wallpaper
            menuBar
            MenuView()
                // The shadow belongs to the panel only, so it doesn't halo every control inside.
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 10))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .offset(x: iconX - 150, y: menuBarHeight + 6)
            if let wait = store.current {
                Banner(text: Store.notificationText(wait))
                    .frame(width: 344)
                    .offset(x: Self.size.width - 344 - 12, y: menuBarHeight + 8)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    /// A calm, plain wallpaper so the eye goes to the menu and the notification.
    private var wallpaper: some View {
        LinearGradient(colors: dark ? [Color(red: 0.10, green: 0.13, blue: 0.19), Color(red: 0.05, green: 0.07, blue: 0.11)]
                                    : [Color(red: 0.84, green: 0.88, blue: 0.93), Color(red: 0.74, green: 0.80, blue: 0.88)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var menuBar: some View {
        let ink: Color = dark ? .white : .black
        return HStack(spacing: 0) {
            Image(systemName: "apple.logo").font(.system(size: 15)).frame(width: 40)
            Text("Finder").fontWeight(.bold).padding(.trailing, 18)
            ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text($0).padding(.trailing, 18) }
            Spacer()
            // Blinker, open and blinking green.
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.green)
                .frame(width: 40, height: 22)
                .background(ink.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 0) {
                ForEach(["timer", "headphones", "lock.shield", "cloud"], id: \.self) { status($0) }
                HStack(spacing: 3) { Image(systemName: "server.rack"); Text("3") }.frame(width: 52)
                ForEach(["speaker.wave.2.fill", "wifi", "battery.75percent", "magnifyingglass", "switch.2"], id: \.self) {
                    status($0)
                }
                Text("Thu Nov 5  9:41 AM").frame(width: 150, alignment: .trailing)
            }
            .frame(width: Self.size.width - iconX - 20 - 12, alignment: .trailing)
            .padding(.trailing, 12)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(ink)
        .frame(width: Self.size.width, height: menuBarHeight)
        .background(dark ? Color.black.opacity(0.25) : Color.white.opacity(0.35))
    }

    private func status(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: symbol.hasPrefix("battery") ? 36 : 30)
    }
}

/// What Blinker's notification looks like, with the exact text `Store` posts.
private struct Banner: View {
    let text: (title: String, body: String)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(text.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("now").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(text.body).font(.system(size: 13)).lineLimit(2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.97))
            .shadow(color: .black.opacity(0.3), radius: 18, y: 6))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
    }
}
