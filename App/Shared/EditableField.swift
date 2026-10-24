import SwiftUI

extension View {
    /// T28: a plain text editor that looks editable. Placeholder while empty; a 1-pt accent border while focused
    /// (macOS draws the insertion point in the accent color itself). Use on every `TextEditor` / `.plain` field.
    func editableField<F: Hashable>(focused: FocusState<F?>.Binding, as value: F, isEmpty: Bool, placeholder: String) -> some View {
        self.focused(focused, equals: value)
            .overlay(alignment: .topLeading) {
                if isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(focused.wrappedValue == value ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: focused.wrappedValue == value ? 1 : 0.5)
                    .allowsHitTesting(false)
            }
            .accessibilityHint(placeholder)
    }
}
