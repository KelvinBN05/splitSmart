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

                ContentView(currentUser: user)
            }
        }
    }
}

private struct AuthView: View {
    @EnvironmentObject private var sessionStore: SessionStore

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
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
            .onChange(of: mode) {
                sessionStore.authErrorMessage = nil
            }

            if mode == .signIn {
                LoginView(
                    email: $email,
                    password: $password,
                    isSubmitting: sessionStore.isAuthenticating,
                    onSubmit: submit
                )
            } else {
                RegisterView(
                    email: $email,
                    password: $password,
                    confirmPassword: $confirmPassword,
                    isSubmitting: sessionStore.isAuthenticating,
                    onSubmit: submit
                )
            }

            if let localValidationError {
                Text(localValidationError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if let authError = sessionStore.authErrorMessage {
                Text(authError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if sessionStore.isAuthenticating {
                ProgressView(mode == .signIn ? "Signing in..." : "Creating account...")
                    .font(.footnote)
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(authBackgroundColor)
    }

    private var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var localValidationError: String? {
        guard !normalizedEmail.isEmpty || !password.isEmpty || !confirmPassword.isEmpty else { return nil }

        if !normalizedEmail.contains("@") || !normalizedEmail.contains(".") {
            return "Enter a valid email address."
        }

        if password.count < 6 {
            return "Password must be at least 6 characters."
        }

        if mode == .signUp && password != confirmPassword {
            return "Passwords do not match."
        }

        return nil
    }

    private var canSubmit: Bool {
        localValidationError == nil && !normalizedEmail.isEmpty && !password.isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        sessionStore.authErrorMessage = nil

        Task {
            if mode == .signIn {
                await sessionStore.signIn(email: normalizedEmail, password: password)
            } else {
                await sessionStore.signUp(email: normalizedEmail, password: password)
            }
        }
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
