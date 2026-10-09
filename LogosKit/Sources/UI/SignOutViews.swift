import Domain
import SwiftUI

/// Settings' last section: Sign out, which first tries to send, then asks to confirm with what will be removed.
struct SignOutSection: View {
    let model: SignOutModel

    var body: some View {
        Section {
            Button(role: .destructive) {
                Task { await model.start() }
            } label: {
                HStack {
                    Text("Sign Out")
                    if model.step == .sending || model.step == .signingOut {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(model.step == .sending || model.step == .signingOut)
            .confirmationDialog(
                "Sign out?",
                isPresented: Binding(
                    get: { if case .confirming = model.step { true } else { false } },
                    // Closing runs a button first (Cancel too, for a tap outside), so closing itself changes nothing.
                    set: { _ in }),
                titleVisibility: .visible,
                presenting: summary
            ) { _ in
                Button("Sign Out and Remove", role: .destructive) {
                    Task { await model.confirm() }
                }
                Button("Cancel", role: .cancel) { model.cancel() }
            } message: { summary in
                Text(SignOutModel.message(for: summary))
            }
        } footer: {
            if case .failed(let message) = model.step {
                Text(message).foregroundStyle(.red)
            } else {
                Text("To change Server, account or Library, sign out, then sign in again.")
            }
        }
    }

    private var summary: SignOutSummary? {
        if case .confirming(let summary) = model.step { summary } else { nil }
    }
}

/// The banner above every tab while sync can't run: needs sign-in (tap to sign in again) or Server too old.
struct ConnectionBannerView: View {
    let model: SignInAgainModel

    var body: some View {
        if let banner = model.banner {
            Group {
                switch banner {
                case .needsSignIn:
                    Button {
                        model.open()
                    } label: {
                        content(banner, systemImage: "person.crop.circle.badge.exclamationmark")
                    }
                    .buttonStyle(.plain)
                case .serverTooOld:
                    content(banner, systemImage: "exclamationmark.triangle")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
        }
    }

    private func content(_ banner: ConnectionBanner, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.subheadline.weight(.semibold))
                Text(banner.detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if banner == .needsSignIn {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The sheet the needs-sign-in banner opens: Server address and username filled in, the password to type.
struct SignInAgainSheet: View {
    @Bindable var model: SignInAgainModel
    @FocusState private var passwordFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("abs.example.com", text: $model.address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
                    SecureField("Password", text: $model.password)
                        .textContentType(.password)
                        .focused($passwordFocused)
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
                    if model.errorPlacement == .general, let message = model.errorMessage {
                        Text(message).foregroundStyle(.red)
                    } else {
                        Text("Sign in as the same account to carry on where you left off. Nothing is removed.")
                    }
                }
            }
            .navigationTitle("Sign In Again")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(model.isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.isPresented = false }
                }
            }
            .onAppear { passwordFocused = true }
        }
    }

    @ViewBuilder
    private func errorText(for placement: SignInModel.ErrorPlacement) -> some View {
        if model.errorPlacement == placement, let message = model.errorMessage {
            Text(message).foregroundStyle(.red)
        }
    }

    private func submit() {
        Task { await model.submit() }
    }
}
