import SwiftUI

enum AnonymousRestrictionCopy {
    static let title = "Not Available"
    static let message = "This action is not available in anonymous mode."
}

extension View {
    func anonymousRestrictionAlert(
        isPresented: Binding<Bool>,
        onGoToLogin: @escaping () -> Void
    ) -> some View {
        alert(AnonymousRestrictionCopy.title, isPresented: isPresented) {
            Button("Close", role: .cancel) {}
            Button("Go to Login") {
                onGoToLogin()
            }
        } message: {
            Text(AnonymousRestrictionCopy.message)
        }
    }
}
