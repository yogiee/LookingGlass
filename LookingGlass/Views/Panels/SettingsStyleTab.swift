import SwiftUI
import AppKit

struct SettingsStyleTab: View {
    @AppStorage("colorSchemeRaw") private var colorSchemeRaw = AppColorScheme.system.rawValue
    @AppStorage("chatFontChoice") private var chatFontChoice = ChatFontChoice.system.rawValue
    @AppStorage("fontSize") private var fontSize = 14.0
    @AppStorage("lineHeight") private var lineHeight = 1.2
    @AppStorage("userName") private var userName = ""
    @AppStorage("userAvatarVersion") private var userAvatarVersion = 0

    var body: some View {
        Form {
            appearanceSection
            profileSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Color Mode", selection: $colorSchemeRaw) {
                ForEach(AppColorScheme.allCases, id: \.rawValue) { scheme in
                    Text(scheme.rawValue).tag(scheme.rawValue)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                Picker("Chat Font", selection: $chatFontChoice) {
                    ForEach(ChatFontChoice.allCases) { choice in
                        Text(choice.label).font(choice.font(13)).tag(choice.rawValue)
                    }
                }
                Text("Prose & input. Code always uses the system monospace.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Font Size")
                    Spacer()
                    Text("\(Int(fontSize)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $fontSize, in: 11...22, step: 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Line Height")
                    Spacer()
                    Text(String(format: "%.2f×", lineHeight))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $lineHeight, in: 1.0...1.5, step: 0.05)
            }
        }
    }

    // MARK: Profile

    private var profileSection: some View {
        Section("Profile") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                FocusedTextField("Your name", text: $userName)
                Text("Alice uses your name in conversation.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                avatarPreview
                VStack(alignment: .leading, spacing: 4) {
                    Text("Avatar")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Text("Shown next to your messages")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(spacing: 4) {
                    Button("Choose…") { pickAvatar() }
                    if AvatarStore.userAvatar(version: userAvatarVersion) != nil {
                        Button("Remove") {
                            AvatarStore.clearUserAvatar()
                            userAvatarVersion &+= 1
                        }
                        .foregroundStyle(.red)
                    }
                }
                .font(.system(size: 11))
            }
        }
    }

    private var avatarPreview: some View {
        Group {
            if let img = AvatarStore.userAvatar(version: userAvatarVersion) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                let initials = userName.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Y"
                    : String(userName.trimmingCharacters(in: .whitespaces).prefix(1).uppercased())
                Circle().fill(Color.accentColor)
                    .overlay(Text(initials).font(.system(size: 16, weight: .bold)).foregroundStyle(.white))
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    private func pickAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if AvatarStore.saveUserAvatar(from: url) {
                userAvatarVersion &+= 1
            }
        }
    }
}
