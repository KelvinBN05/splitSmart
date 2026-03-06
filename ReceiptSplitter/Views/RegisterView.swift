import SwiftUI

struct RegisterView: View {
    @Binding var email: String
    @Binding var password: String
    @Binding var confirmPassword: String

    let isSubmitting: Bool
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "envelope")
                    .foregroundStyle(.secondary)
                TextField("Email", text: $email)
#if os(iOS)
                    .autocapitalization(.none)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled(true)
#endif
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
                SecureField("Password", text: $password)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.secondary)
                SecureField("Confirm Password", text: $confirmPassword)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button("Create Account", action: onSubmit)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(red: 0.04, green: 0.45, blue: 0.95))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(isSubmitting)
        }
    }
}
