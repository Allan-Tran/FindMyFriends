import SwiftUI

struct JoinGroupView: View {
    @EnvironmentObject private var groupStore: GroupStore
    @Environment(\.dismiss) private var dismiss
    @State private var inviteCode: String = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Invite code", text: $inviteCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                } header: {
                    Text("Join group")
                } footer: {
                    Text("Ask the group admin for the 8-character code.")
                }
                if let error = error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Join group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") {
                        error = nil
                        working = true
                        Task {
                            let joined = await groupStore.join(
                                inviteCode: inviteCode.trimmingCharacters(in: .whitespaces).uppercased()
                            )
                            working = false
                            if joined != nil { dismiss() }
                            else { error = groupStore.lastError ?? "Could not join" }
                        }
                    }
                    .disabled(working || inviteCode.count < 4)
                }
            }
        }
    }
}
