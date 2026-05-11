import SwiftUI

struct JoinGroupView: View {
    @EnvironmentObject private var groupStore: GroupStore
    @Environment(\.dismiss) private var dismiss
    @State private var groupIdString: String = ""
    @State private var inviteCode: String = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Group") {
                    TextField("Group ID (UUID)", text: $groupIdString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    TextField("Invite code", text: $inviteCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
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
                        guard let id = UUID(uuidString: groupIdString.trimmingCharacters(in: .whitespaces)) else {
                            error = "Group ID must be a valid UUID"
                            return
                        }
                        error = nil
                        working = true
                        Task {
                            let joined = await groupStore.join(
                                groupId: id,
                                inviteCode: inviteCode.trimmingCharacters(in: .whitespaces)
                            )
                            working = false
                            if joined != nil { dismiss() }
                            else { error = groupStore.lastError ?? "Could not join" }
                        }
                    }
                    .disabled(working || groupIdString.isEmpty || inviteCode.isEmpty)
                }
            }
        }
    }
}
