import SwiftUI

struct LoginView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var vm = LoginViewModel()
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case username, password
    }

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            VStack(spacing: 12) {
                Text("Sign In")
                    .font(.title)
                    .bold()
                if let base = session.baseURL {
                    Text(base.host ?? base.absoluteString)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 20) {
                TextField("Username", text: $vm.username)
                    .textFieldStyle(.plain)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .focused($focusedField, equals: .username)
                    .padding()
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(12)

                SecureField("Password", text: $vm.password)
                    .focused($focusedField, equals: .password)
                    .padding()
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(12)

                if let error = vm.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Button {
                    Task { await vm.login(using: session) }
                } label: {
                    if vm.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Log In")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(vm.isLoading)
            }
            .frame(maxWidth: 600)

            Button("Change Instance") {
                session.clearInstance()
            }
            .font(.caption)

            Spacer()
        }
        .padding(60)
        .onAppear { focusedField = .username }
    }
}
