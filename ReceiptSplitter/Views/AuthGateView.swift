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
            ContentView(currentUser: user)
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
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.92, green: 0.96, blue: 1.00),
                    Color(red: 0.96, green: 0.98, blue: 1.00),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text("SplitSmart")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.06, green: 0.12, blue: 0.25))
                    Text("Scan receipts, split totals, and track everything in one place.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 16) {
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
                .padding(22)
                .background(.white.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 8)
            }
            .padding(24)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}
