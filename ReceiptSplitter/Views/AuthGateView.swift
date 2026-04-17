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
            AppTheme.pageGradient
                .ignoresSafeArea()

            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Text("SplitSmart")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.ink)
                    Text(mode == .signIn ? "Sign in to manage your receipts." : "Create an account to start splitting receipts.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.muted)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 18) {
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
                        authMessage(localValidationError, color: AppTheme.danger, iconName: "exclamationmark.triangle.fill")
                    }

                    if let authError = sessionStore.authErrorMessage {
                        authMessage(authError, color: AppTheme.danger, iconName: "exclamationmark.triangle.fill")
                    }

                    if sessionStore.isAuthenticating {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(mode == .signIn ? "Signing in..." : "Creating account...")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(AppTheme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.shield")
                            Text("Private receipts stay tied to your account.")
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                    }
                }
                .padding(22)
                .appCard(cornerRadius: 28)
            }
            .padding(24)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func authMessage(_ message: String, color: Color, iconName: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(color)
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(color)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
