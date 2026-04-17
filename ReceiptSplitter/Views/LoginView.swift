import SwiftUI

struct LoginView: View {
    @Binding var email: String
    @Binding var password: String

    let isSubmitting: Bool
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "envelope")
                    .foregroundStyle(AppTheme.royal)
                TextField("Email", text: $email)
#if os(iOS)
                    .autocapitalization(.none)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled(true)
#endif
            }
            .appInputField()

            HStack {
                Image(systemName: "lock")
                    .foregroundStyle(AppTheme.royal)
                SecureField("Password", text: $password)
            }
            .appInputField()

            Button("Sign In", action: onSubmit)
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.gold)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .disabled(isSubmitting)
        }
    }
}
