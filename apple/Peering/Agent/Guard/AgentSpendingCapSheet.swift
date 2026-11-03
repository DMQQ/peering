import PeeringKit
import RemoteCore
import SwiftUI

/// A chat's cap on spend and on context. Past either, the messages waiting behind a turn are held for the person.
struct AgentSpendingCapSheet: View {
    let sessionID: UUID

    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var costText = ""
    @State private var percentText = ""

    private var cap: AgentSpendingCap {
        AgentSpendingCap(
            costUSD: AgentSpendingGuard.parsedCost(costText),
            contextPercent: AgentSpendingGuard.parsedPercent(percentText)
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "No limit"), text: $costText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("cap.cost")
                } header: {
                    Text("Cost in US dollars")
                }
                Section {
                    TextField(String(localized: "No limit"), text: $percentText)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("cap.context")
                } header: {
                    Text("Context, percent of the window")
                } footer: {
                    Text("When a turn ends past either cap, Peering warns you here and holds the messages waiting in this chat until you send them on.")
                }
                if model.agentSpendingCap(for: sessionID) != nil {
                    Button(String(localized: "Remove cap"), role: .destructive) {
                        model.setAgentSpendingCap(nil, for: sessionID)
                        dismiss()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ColorPalette.backdrop)
            .navigationTitle(String(localized: "Spending cap"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        model.setAgentSpendingCap(cap.isEmpty ? nil : cap, for: sessionID)
                        dismiss()
                    }
                }
            }
        }
        .onAppear(perform: load)
        .presentationDetents([.medium, .large])
    }

    private func load() {
        let current = model.agentSpendingCap(for: sessionID)
        costText = current?.costUSD.map { $0.formatted(.number.precision(.fractionLength(0 ... 2))) } ?? ""
        percentText = current?.contextPercent.map(String.init) ?? ""
    }
}
