import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct AuthGateView: View {
    @EnvironmentObject private var sessionStore: SessionStore

    var body: some View {
        switch sessionStore.state {
        case .loading:
            ProgressView("Loading session...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
            AuthView()
        case .signedIn(let user):
            VStack(spacing: 0) {
                HStack {
                    Text(user.email ?? "SplitSmart")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Sign Out") {
                        sessionStore.signOut()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial)

                ContentView()
            }
        }
    }
}

private struct AuthView: View {
    @EnvironmentObject private var sessionStore: SessionStore

    @State private var email = ""
    @State private var password = ""
    @State private var mode: Mode = .signIn

    private enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign In"
        case signUp = "Create Account"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("SplitSmart")
                .font(.system(size: 34, weight: .bold, design: .rounded))

            Picker("Auth Mode", selection: $mode) {
                ForEach(Mode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
#if os(iOS)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled(true)
#endif

                SecureField("Password", text: $password)
            }
            .textFieldStyle(.roundedBorder)

            if let authError = sessionStore.authErrorMessage {
                Text(authError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button(mode.rawValue) {
                Task {
                    if mode == .signIn {
                        await sessionStore.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
                    } else {
                        await sessionStore.signUp(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
        }
        .padding(24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(authBackgroundColor)
    }

    private var authBackgroundColor: Color {
#if os(iOS)
        return Color(UIColor.systemGroupedBackground)
#elseif os(macOS)
        return Color(NSColor.windowBackgroundColor)
#else
        return Color(.systemGray6)
#endif
    }
}
