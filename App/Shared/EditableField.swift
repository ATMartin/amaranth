import SwiftUI

extension View {
    /// T28: a plain text editor that looks editable. Placeholder while empty; on the Surface colour with a control-border
    /// outline, an accent border while focused (macOS draws the insertion point in the accent color itself). Use on every `TextEditor` / `.plain` field.
    func editableField<F: Hashable>(focused: FocusState<F?>.Binding, as value: F, isEmpty: Bool, placeholder: String) -> some View {
        self.focused(focused, equals: value)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.surface))
            .overlay(alignment: .topLeading) {
                if isEmpty {
                    Text(placeholder).foregroundStyle(Color.brandSecondary).padding(.leading, 9).padding(.top, 4).allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused.wrappedValue == value ? Color.brandAccent : Color.controlBorder,
                                  lineWidth: focused.wrappedValue == value ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
            .accessibilityHint(placeholder)
    }
}
