import AuthenticationServices
import DesignSystem
import SwiftUI

struct WelcomeFlow: View {
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            WelcomeView { showSignIn = true }
                .navigationDestination(isPresented: $showSignIn) { SignInView() }
        }
    }
}

struct WelcomeView: View {
    var onContinue: () -> Void
    @State private var page = 0

    struct Card: Identifiable {
        let id: Int
        let illustration: Illustration.Kind
        let title: String
        let body: String
    }

    let cards = [
        Card(id: 0, illustration: .free, title: "Know when you're both free",
             body: "Nudge quietly checks your calendars and taps you both on the shoulder when there's time to talk."),
        Card(id: 1, illustration: .call, title: "Call in one tap",
             body: "Accept the nudge and you're on a video call. Skip it and we'll let them know you'll catch up soon."),
        Card(id: 2, illustration: .photos, title: "Your photos join the conversation",
             body: "Mention the hike or the cake and the photo appears. Afterward, we remember what matters for next time."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.xs) {
                BrandMark(size: 18)
                Text("Nudge").font(.system(.headline, design: .rounded, weight: .semibold)).foregroundStyle(Palette.ink)
            }
            .padding(.top, Space.m)

            TabView(selection: $page) {
                ForEach(cards) { card in
                    VStack(spacing: Space.xl) {
                        Illustration(card.illustration)
                            .frame(width: 240, height: 180)
                            .padding(.vertical, Space.xl)
                            .frame(maxWidth: .infinity)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous))
                        VStack(spacing: Space.s) {
                            Text(card.title).font(Typography.largeTitle).displayTracking()
                                .foregroundStyle(Palette.ink).multilineTextAlignment(.center)
                            Text(card.body).font(.body).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, Space.s)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.margin)
                    .padding(.top, Space.l)
                    .tag(card.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: Space.xs) {
                ForEach(cards) { c in
                    Capsule().fill(c.id == page ? Palette.lavenderStrong : Palette.divider)
                        .frame(width: c.id == page ? 20 : 8, height: 8)
                }
            }
            .animation(Motion.move, value: page)
            .padding(.bottom, Space.l)
            .accessibilityHidden(true)

            NudgeButton(page == cards.count - 1 ? "Get started" : "Continue") {
                if page < cards.count - 1 { withAnimation(Motion.move) { page += 1 } } else { onContinue() }
            }
            .padding(.horizontal, Space.margin)
            .padding(.bottom, Space.m)
        }
        .nudgeBackground()
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @State private var devName = ""
    @State private var working = false

    var body: some View {
        VStack(spacing: Space.l) {
            Spacer()
            BrandMark(size: 64)
            VStack(spacing: Space.s) {
                Text("Stay close to your people").font(Typography.largeTitle).displayTracking()
                    .foregroundStyle(Palette.ink).multilineTextAlignment(.center)
                Text("Sign in to find the moments you and your friends are both free.")
                    .font(.body).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, Space.l)
            Spacer()

            VStack(spacing: Space.s) {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    guard case .success(let auth) = result,
                          let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                          let tokenData = cred.identityToken else {
                        if case .failure(let e) = result, (e as? ASAuthorizationError)?.code != .canceled {
                            app.session.error = "Sign in didn't complete. Try again."
                        }
                        return
                    }
                    let name = cred.fullName.flatMap { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
                    Task {
                        working = true
                        await app.session.signInWithApple(identityToken: String(decoding: tokenData, as: UTF8.self), fullName: name?.nonEmptyString)
                        working = false
                    }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: Radius.input + 2, style: .continuous))
                .disabled(working)

                if let error = app.session.error {
                    Text(error).font(.footnote).foregroundStyle(Palette.roseStrong).multilineTextAlignment(.center)
                }

                #if DEBUG
                DevSignIn(name: $devName, working: $working)
                #endif

                Text("By continuing you'll be asked to review our Terms.")
                    .font(.footnote).foregroundStyle(Palette.inkTertiary).multilineTextAlignment(.center)
                    .padding(.top, Space.xs)
            }
            .padding(.horizontal, Space.margin)
            .padding(.bottom, Space.m)
        }
        .nudgeBackground()
        .navigationBarBackButtonHidden(false)
    }
}

#if DEBUG
/// DEBUG-only: sign in as a dev-stage test user (POST /auth/dev) so the simulator can reach the backend.
private struct DevSignIn: View {
    @Environment(AppModel.self) private var app
    @Binding var name: String
    @Binding var working: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Developer sign-in").font(.footnote.weight(.semibold)).foregroundStyle(Palette.inkSecondary)
            HStack(spacing: Space.xs) {
                TextField("test username", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(NudgeTextFieldStyle())
                NudgeButton("Go", kind: .secondary, size: .medium, fullWidth: false, isLoading: working) {
                    Task {
                        working = true
                        await app.session.devSignIn(username: name)
                        working = false
                    }
                }
                .disabled(name.count < 3)
            }
        }
        .padding(Space.s)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}
#endif

extension String {
    var nonEmptyString: String? {
        let t = trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
