import SwiftUI

struct LoginView: View {
    @Binding var email: String
    @Binding var password: String

    let isSubmitting: Bool
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            TextField("Email", text: $email)
                .textInputAutocapitalization(.never)
#if os(iOS)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled(true)
#endif

            SecureField("Password", text: $password)

            Button("Sign In", action: onSubmit)
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting)
        }
        .textFieldStyle(.roundedBorder)
    }
}
