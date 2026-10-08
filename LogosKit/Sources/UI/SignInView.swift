import SwiftUI
import Sync

/// One screen with the Server address, username and password. Errors appear in place, under what caused them.
struct SignInView: View {
    @Bindable var model: SignInModel
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case address
        case username
        case password
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.libraryOptions.isEmpty {
                    credentials
                } else {
                    libraryPicker
                }
            }
            .navigationTitle("Sign In")
            .disabled(model.isWorking)
        }
    }

    @ViewBuilder
    private var credentials: some View {
        Section {
            TextField("abs.example.com", text: $model.address)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .address)
                .submitLabel(.next)
                .onSubmit { focus = .username }
        } header: {
            Text("Server")
        } footer: {
            errorText(for: .address)
        }

        Section {
            TextField("Username", text: $model.username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .username)
                .submitLabel(.next)
                .onSubmit { focus = .password }
            SecureField("Password", text: $model.password)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .submitLabel(.go)
                .onSubmit(submit)
        } header: {
            Text("Account")
        } footer: {
            errorText(for: .credentials)
        }

        Section {
            Button(action: submit) {
                HStack {
                    Text("Sign In")
                    if model.isWorking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!model.canSubmit)
        } footer: {
            errorText(for: .general)
        }
    }

    @ViewBuilder
    private var libraryPicker: some View {
        Section {
            ForEach(model.libraryOptions) { library in
                Button(library.name) { model.choose(library) }
            }
        } header: {
            Text("Choose a Library")
        } footer: {
            if let message = model.errorMessage {
                Text(message).foregroundStyle(.red)
            } else {
                Text("Logos shows one book Library. To change it later, sign out and sign in again.")
            }
        }
        Section {
            Button("Cancel", role: .cancel) { model.cancelLibraryChoice() }
        }
    }

    @ViewBuilder
    private func errorText(for placement: SignInModel.ErrorPlacement) -> some View {
        if model.errorPlacement == placement, let message = model.errorMessage {
            Text(message).foregroundStyle(.red)
        }
    }

    private func submit() {
        focus = nil
        Task { await model.submit() }
    }
}
