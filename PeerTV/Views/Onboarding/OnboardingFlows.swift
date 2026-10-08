import SwiftUI

struct InstanceSetupScreen<Host: AccountLoginHost>: View {
    @ObservedObject var host: Host
    var onInstanceReady: (() -> Void)?
    var showsAnonymousEntry: Bool = true
    var onBrowseAnonymously: () -> Void = {}
    @StateObject private var vm = InstanceSetupViewModel()
    @FocusState private var isURLFocused: Bool
    @State private var showPopularServers = false

    var body: some View {
        OnboardingScreenLayout {
            VStack(spacing: 32) {
                OnboardingHeader(
                    title: "Connect",
                    subtitle: "Enter your PeerTube instance URL"
                )

                OnboardingFormCard {
                    TextField("https://peertube.example.com", text: $vm.urlText)
                        .textFieldStyle(.plain)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .focused($isURLFocused)
                        .onboardingTextFieldStyle()

                    if let error = vm.errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await vm.validate(using: host, onSuccess: onInstanceReady) }
                    } label: {
                        Group {
                            if vm.isValidating {
                                ProgressView()
                                    .tint(OnboardingPrimaryButtonColors.label)
                            } else {
                                Text("Connect")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .onboardingPrimaryButton()
                    .disabled(vm.isValidating)
                }
                .frame(maxWidth: 640)

                HStack(spacing: 20) {
                    OnboardingSecondaryButton(title: "Popular Servers") {
                        showPopularServers = true
                    }
                    if showsAnonymousEntry {
                        OnboardingSecondaryButton(title: "Browse Anonymously", action: onBrowseAnonymously)
                    }
                }
                .frame(maxWidth: 640)
            }
        }
        .onAppear { isURLFocused = true }
        .sheet(isPresented: $showPopularServers) {
            PopularServersPickerView(vm: vm) { server in
                showPopularServers = false
                vm.urlText = server.url.absoluteString
                Task { await vm.validate(using: host, onSuccess: onInstanceReady) }
            }
        }
    }
}

/// Curated public servers with live details from the directory; picking one connects to it.
struct PopularServersPickerView: View {
    @ObservedObject var vm: InstanceSetupViewModel
    let onSelect: (PopularServer) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Public servers anyone can watch. Pick one to connect, then sign in or browse anonymously.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 50)

                    LazyVStack(spacing: 16) {
                        ForEach(vm.popularServers) { server in
                            Button {
                                onSelect(server)
                            } label: {
                                serverRow(server)
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.horizontal, 50)
                }
                .padding(.top, 30)
                .padding(.bottom, 60)
            }
            .navigationTitle("Popular Servers")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if vm.isLoadingPopularServers {
                        ProgressView()
                    }
                }
            }
        }
        .task { await vm.loadPopularServers() }
    }

    private func serverRow(_ server: PopularServer) -> some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.displayName)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(server.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(server.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 16)

            if let directory = server.directory {
                VStack(alignment: .trailing, spacing: 4) {
                    if let videos = directory.totalLocalVideos {
                        Text("\(videos.formatted(.number.notation(.compactName))) videos")
                    }
                    if let users = directory.totalUsers {
                        Text("\(users.formatted(.number.notation(.compactName))) users")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
    }
}

struct LoginScreen<Host: AccountLoginHost>: View {
    @ObservedObject var host: Host
    var showsAnonymousEntry: Bool = true
    var onBrowseAnonymously: () -> Void = {}
    @StateObject private var vm = LoginViewModel()
    @FocusState private var focusedField: Field?
    @State private var pendingKeychainCredential: PendingKeychainCredential?
    @State private var pendingLoginCompletion: PendingLoginCompletion?
    @State private var showKeychainSaveAlert = false
    @State private var keychainSaveError: String?
    @State private var savedSignIns: [SavedInternetCredential] = []
    @State private var showSavedSignInPicker = false
    @State private var showRemoveSavedSignInPicker = false
    @State private var savedSignInPendingDeletion: SavedInternetCredential?
    @State private var showDeleteSavedSignInConfirm = false

    private enum Field: Hashable {
        case username, password, otp
    }

    private struct PendingKeychainCredential {
        let host: String
        let account: String
        let password: String
    }

    private struct PendingLoginCompletion {
        let tokens: OAuthTokenResponse
        let username: String
    }

    /// Names the selected server; "Change Instance" below the form goes back to pick another.
    private var instanceSubtitle: String {
        if let base = host.baseURL {
            return "Sign in to \(base.host ?? base.absoluteString)"
        }
        return "Sign in to your PeerTube account"
    }

    var body: some View {
        OnboardingScreenLayout {
            VStack(spacing: 32) {
                OnboardingHeader(
                    title: "Sign In",
                    subtitle: instanceSubtitle
                )

                OnboardingFormCard {
                    if !vm.needsOTP, !savedSignIns.isEmpty {
                        savedSignInControls
                    }

                    TextField("Username", text: $vm.username)
                        .textFieldStyle(.plain)
                        .textContentType(.username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .focused($focusedField, equals: .username)
                        .disabled(vm.needsOTP)
                        .opacity(vm.needsOTP ? 0.5 : 1)
                        .onboardingTextFieldStyle()

                    SecureField("Password", text: $vm.password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .disabled(vm.needsOTP)
                        .opacity(vm.needsOTP ? 0.5 : 1)
                        .onboardingTextFieldStyle()

                    if vm.needsOTP {
                        VStack(spacing: 8) {
                            Text("Enter the code from your authenticator app")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            TextField("Authenticator code", text: $vm.otpCode)
                                .textFieldStyle(.plain)
                                .textContentType(.oneTimeCode)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .focused($focusedField, equals: .otp)
                                .onboardingTextFieldStyle()
                        }
                    }

                    if let error = vm.errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await performLogin() }
                    } label: {
                        Group {
                            if vm.isLoading {
                                ProgressView()
                                    .tint(OnboardingPrimaryButtonColors.label)
                            } else {
                                Text(vm.needsOTP ? "Verify" : "Log In")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .onboardingPrimaryButton()
                    .disabled(vm.isLoading)
                }
                .frame(maxWidth: 640)

                if showsAnonymousEntry || host.baseURL != nil {
                    HStack(spacing: 24) {
                        if host.baseURL != nil {
                            Button("Change Instance") {
                                host.clearInstance()
                            }
                            .font(.callout)
                        }

                        if showsAnonymousEntry {
                            Button("Browse Anonymously") {
                                onBrowseAnonymously()
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
        .onAppear {
            reloadSavedSignIns()
            focusedField = .username
        }
        .onChange(of: host.baseURL?.absoluteString) { _, _ in
            reloadSavedSignIns()
        }
        .onChange(of: vm.needsOTP) { _, needsOTP in
            if needsOTP { focusedField = .otp }
        }
        .confirmationDialog(
            "Saved sign-in",
            isPresented: $showSavedSignInPicker,
            titleVisibility: .visible
        ) {
            ForEach(savedSignIns) { saved in
                Button(saved.account) {
                    applySavedSignIn(saved)
                }
            }
            Button("Remove saved sign-in…", role: .destructive) {
                showRemoveSavedSignInPicker = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Remove saved sign-in",
            isPresented: $showRemoveSavedSignInPicker,
            titleVisibility: .visible
        ) {
            ForEach(savedSignIns) { saved in
                Button("Remove \(saved.account)", role: .destructive) {
                    confirmDeleteSavedSignIn(saved)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Remove saved sign-in?", isPresented: $showDeleteSavedSignInConfirm) {
            Button("Remove", role: .destructive) {
                if let saved = savedSignInPendingDeletion {
                    deleteSavedSignIn(saved)
                }
            }
            Button("Cancel", role: .cancel) {
                savedSignInPendingDeletion = nil
            }
        } message: {
            if let saved = savedSignInPendingDeletion {
                Text("Remove the saved password for “\(saved.account)” on this server from iCloud Keychain?")
            }
        }
        .alert("Save to iCloud Keychain?", isPresented: $showKeychainSaveAlert) {
            Button("Save") {
                Task {
                    await savePendingKeychainCredential()
                    completePendingLogin()
                }
            }
            Button("Not Now", role: .cancel) {
                pendingKeychainCredential = nil
                completePendingLogin()
            }
        } message: {
            Text("Save your username and password for this server so they can autofill on your Apple devices signed into iCloud.")
        }
        .alert("Couldn’t Save Password", isPresented: Binding(
            get: { keychainSaveError != nil },
            set: { if !$0 { keychainSaveError = nil } }
        )) {
            Button("OK", role: .cancel) { keychainSaveError = nil }
        } message: {
            if let keychainSaveError {
                Text(keychainSaveError)
            }
        }
    }

    @ViewBuilder
    private var savedSignInControls: some View {
        VStack(spacing: 14) {
            if savedSignIns.count == 1, let saved = savedSignIns.first {
                HStack(spacing: 16) {
                    Button {
                        applySavedSignIn(saved)
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "key.fill")
                            Text("Fill saved sign-in for \(saved.account)")
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 18)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.card)

                    Button {
                        confirmDeleteSavedSignIn(saved)
                    } label: {
                        Image(systemName: "trash")
                            .font(.callout)
                            .frame(width: 56, height: 56)
                            .background(Color.white.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.card)
                    .accessibilityLabel("Remove saved sign-in for \(saved.account)")
                }
            } else {
                Button {
                    showSavedSignInPicker = true
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "key.fill")
                        Text("Choose saved sign-in (\(savedSignIns.count))")
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.card)
            }
        }
        .padding(.bottom, 6)
    }

    private func confirmDeleteSavedSignIn(_ saved: SavedInternetCredential) {
        savedSignInPendingDeletion = saved
        showDeleteSavedSignInConfirm = true
    }

    private func deleteSavedSignIn(_ saved: SavedInternetCredential) {
        savedSignInPendingDeletion = nil
        showDeleteSavedSignInConfirm = false
        showSavedSignInPicker = false
        showRemoveSavedSignInPicker = false

        savedSignIns.removeAll { $0.account == saved.account }
        if vm.username == saved.account {
            vm.password = ""
        }

        guard let baseURL = host.baseURL else { return }
        let hostKey = baseURL.host ?? baseURL.absoluteString
        _ = InternetCredentialSaver.delete(host: hostKey, account: saved.account)
        reloadSavedSignIns()
    }

    private func reloadSavedSignIns() {
        guard let baseURL = host.baseURL else {
            savedSignIns = []
            return
        }
        let hostKey = baseURL.host ?? baseURL.absoluteString
        savedSignIns = InternetCredentialSaver.savedCredentials(forHost: hostKey)
    }

    private func applySavedSignIn(_ saved: SavedInternetCredential) {
        vm.username = saved.account
        vm.password = saved.password
        vm.errorMessage = nil
        focusedField = .password
    }

    private func performLogin() async {
        guard let baseURL = host.baseURL else {
            vm.errorMessage = "No instance configured."
            return
        }
        let passwordSnapshot = vm.password
        let usernameSnapshot = vm.username
        let hostSnapshot = baseURL.host ?? baseURL.absoluteString

        let outcome = await vm.login(using: host)
        guard case .success(let tokens) = outcome else { return }

        if let conflict = host.addAccountConflictMessage(baseURL: baseURL, username: usernameSnapshot) {
            vm.errorMessage = conflict
            return
        }

        // Nothing to offer when this exact sign-in is already in the keychain.
        let alreadySaved = InternetCredentialSaver.savedCredentials(forHost: hostSnapshot).contains {
            $0.account == usernameSnapshot && $0.password == passwordSnapshot
        }
        if alreadySaved {
            host.didLogin(tokens: tokens, username: usernameSnapshot)
            vm.password = ""
            return
        }

        pendingLoginCompletion = PendingLoginCompletion(
            tokens: tokens,
            username: usernameSnapshot
        )
        pendingKeychainCredential = PendingKeychainCredential(
            host: hostSnapshot,
            account: usernameSnapshot,
            password: passwordSnapshot
        )
        showKeychainSaveAlert = true
    }

    /// Finishes login after the Keychain prompt — `didLogin` must not run earlier or `RootView` removes this screen before the alert appears.
    private func completePendingLogin() {
        guard let pending = pendingLoginCompletion else { return }
        pendingLoginCompletion = nil
        host.didLogin(tokens: pending.tokens, username: pending.username)
        vm.password = ""
    }

    private func savePendingKeychainCredential() async {
        guard let pending = pendingKeychainCredential else { return }
        pendingKeychainCredential = nil
        let result = InternetCredentialSaver.save(
            host: pending.host,
            account: pending.account,
            password: pending.password
        )
        switch result {
        case .saved:
            break
        case .failed(let message):
            keychainSaveError = message
        }
    }
}
