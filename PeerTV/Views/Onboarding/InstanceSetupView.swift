import SwiftUI

struct InstanceSetupView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var vm = InstanceSetupViewModel()
    @FocusState private var isURLFocused: Bool

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.tint)
                Text("PeerTV")
                    .font(.title)
                    .bold()
                Text("Enter your PeerTube instance URL")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 20) {
                TextField("https://peertube.example.com", text: $vm.urlText)
                    .textFieldStyle(.plain)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .focused($isURLFocused)
                    .padding()
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(12)

                if let error = vm.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Button {
                    Task { await vm.validate(using: session) }
                } label: {
                    if vm.isValidating {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Connect")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(vm.isValidating)
            }
            .frame(maxWidth: 600)

            Spacer()
        }
        .padding(60)
        .onAppear { isURLFocused = true }
    }
}
