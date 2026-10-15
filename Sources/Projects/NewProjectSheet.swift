import SwiftUI
import PocketKit
import PocketUI

struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var instructions = ""

    let onCreate: (String, String?) -> Void

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project Details") {
                    TextField("Project name", text: $name)
                        .accessibilityLabel("Project name")

                    VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                        Text("Instructions (optional)")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                        TextEditor(text: $instructions)
                            .frame(minHeight: 100)
                            .accessibilityLabel("Project instructions")
                    }
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityLabel("Cancel creating project")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedInst = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                        onCreate(trimmedName, trimmedInst.isEmpty ? nil : trimmedInst)
                        dismiss()
                    }
                    .disabled(!isValid)
                    .accessibilityLabel("Create project")
                    .accessibilityHint("Creates the project with specified name and instructions")
                }
            }
        }
    }
}
