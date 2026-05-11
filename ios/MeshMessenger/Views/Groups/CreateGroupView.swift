import SwiftUI

struct CreateGroupView: View {
    @EnvironmentObject private var groupStore: GroupStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Group name", text: $name)
                    .autocorrectionDisabled(false)
            }
            .navigationTitle("New group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        working = true
                        Task {
                            let created = await groupStore.create(name: name.trimmingCharacters(in: .whitespaces))
                            working = false
                            if created != nil { dismiss() }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
            }
        }
    }
}
