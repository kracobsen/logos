import Store
import SwiftUI
import Sync

/// What the app shows: sign-in until a Server identity is saved, then the tab shell.
public struct AppRootView: View {
    @State private var launch: LaunchModel
    @State private var signIn: SignInModel

    public init(database: AppDatabase, signIn: SignIn) {
        _launch = State(initialValue: LaunchModel(database: database))
        _signIn = State(initialValue: SignInModel(signIn: signIn))
    }

    public var body: some View {
        Group {
            if launch.identity == nil {
                SignInView(model: signIn)
            } else {
                RootView()
            }
        }
        .task { await launch.observe() }
    }
}
