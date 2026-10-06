import SwiftUI

extension View {
    /// The Cancel and confirm pair every editing sheet carries. Leave `confirm` nil for a sheet that
    /// can only be dismissed.
    func sheetToolbar(
        cancel: LocalizedStringKey = "Cancel",
        onCancel: @escaping () -> Void,
        confirm: LocalizedStringKey? = nil,
        canConfirm: Bool = true,
        onConfirm: @escaping () -> Void = {}
    ) -> some View {
        toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(cancel, action: onCancel)
            }
            if let confirm {
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirm, action: onConfirm)
                        .disabled(!canConfirm)
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
