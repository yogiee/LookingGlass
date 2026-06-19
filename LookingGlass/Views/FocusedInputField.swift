import SwiftUI

/// Single-line text field with the app's focus convention:
/// regularMaterial background + hairline border that brightens on focus.
/// Drop-in for `TextField(...).textFieldStyle(.roundedBorder)` in sheets and forms.
struct FocusedTextField: View {
    private let placeholder: String
    @Binding private var text: String
    private var font: Font

    init(_ placeholder: String, text: Binding<String>, font: Font = .system(size: 13)) {
        self.placeholder = placeholder
        self._text = text
        self.font = font
    }

    @FocusState private var isFocused: Bool

    var body: some View {
        // Placeholder is rendered as a ghost overlay (not the TextField's title) so a
        // grouped Form can't extract it as a row label and right-align the value. The
        // empty-title TextField + ZStack keeps the value left-aligned everywhere.
        ZStack(alignment: .leading) {
            if text.isEmpty, !placeholder.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .labelsHidden()
                .font(font)
        }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isFocused ? Color.primary.opacity(0.07) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isFocused ? 0.25 : 0.15), lineWidth: 0.5)
            )
            .focused($isFocused)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Multi-line text editor with the same focus convention.
/// Drop-in for `TextEditor(text: $x)` in sheets and forms.
struct FocusedTextEditor: View {
    @Binding var text: String
    var font: Font = .system(size: 13)
    var minHeight: CGFloat = 72
    var placeholder: String = ""

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty, !placeholder.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                    .padding(.leading, 11)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .textEditorStyle(.plain)
                .font(font)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .focused($isFocused)
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused ? Color.primary.opacity(0.07) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(isFocused ? 0.25 : 0.15), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
