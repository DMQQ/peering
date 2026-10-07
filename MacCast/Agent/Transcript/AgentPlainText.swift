import MacCastKit
import RemoteCore
import SwiftUI

struct AgentPlainText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 15.5))
            .foregroundStyle(.white.opacity(0.95))
            .lineSpacing(3)
            .textSelection(.enabled)
    }
}
