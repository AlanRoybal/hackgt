import DesignSystem
import Models
import PhotosUI
import SwiftUI

/// ACC-3/4: handle with a live availability check, display name, optional avatar.
struct HandleView: View {
    @Environment(AppModel.self) private var app
    @State private var handle = ""
    @State private var displayName = ""
    @State private var check: Check = .idle
    @State private var working = false
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarImage: UIImage?
    @FocusState private var focused: Field?

    enum Field { case handle, name }
    enum Check: Equatable { case idle, checking, available, problem(String) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Choose your handle").font(Typography.largeTitle).displayTracking().foregroundStyle(Palette.ink)
                    Text("Friends use it to find you. You can't change it later, so pick one you like.")
                        .font(.body).foregroundStyle(Palette.inkSecondary)
                }
                .padding(.top, Space.xl)

                HStack {
                    Spacer()
                    let label = AvatarPickerLabel(image: avatarImage, name: displayName.isEmpty ? handle : displayName, seed: app.session.userId)
                    PhotosPicker(selection: $avatarItem, matching: .images) { label }
                    .accessibilityLabel("Choose a profile photo")
                    Spacer()
                }

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Handle").font(.footnote.weight(.semibold)).foregroundStyle(Palette.inkSecondary)
                    HStack(spacing: 0) {
                        Text("@").foregroundStyle(Palette.inkTertiary).padding(.trailing, Space.xs)
                        TextField("yourname", text: $handle)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textContentType(.username)
                            .focused($focused, equals: .handle)
                        statusIcon
                    }
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.body)
                    .padding(.horizontal, Space.m)
                    .frame(minHeight: 50)
                    .background(Palette.surfaceAlt, in: RoundedRectangle(cornerRadius: Radius.input, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                        .strokeBorder(NudgeTextFieldStyle.borderColor(fieldState), lineWidth: NudgeTextFieldStyle.borderWidth(fieldState)))
                    statusText
                }

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Your name").font(.footnote.weight(.semibold)).foregroundStyle(Palette.inkSecondary)
                    TextField("How friends see you", text: $displayName)
                        .textContentType(.name)
                        .focused($focused, equals: .name)
                        .textFieldStyle(NudgeTextFieldStyle(focused == .name ? .focused : .normal))
                }
            }
            .padding(.horizontal, Space.margin)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
        .nudgeBackground()
        .safeAreaInset(edge: .bottom) {
            NudgeButton("Continue", isLoading: working) { Task { await submit() } }
                .disabled(check != .available || displayName.nonEmptyString == nil)
                .padding(.horizontal, Space.margin)
                .padding(.vertical, Space.s)
                .background(Palette.bg)
        }
        .task(id: handle) { await runCheck() }
        .onChange(of: avatarItem) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data) { avatarImage = img }
            }
        }
        .onAppear {
            if displayName.isEmpty { displayName = app.session.me?.user.displayName ?? "" }
            focused = .handle
        }
        .sensoryFeedback(.success, trigger: check == .available)
    }

    @ViewBuilder var statusIcon: some View {
        switch check {
        case .checking: ProgressView().controlSize(.small)
        case .available: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.mintStrong)
        case .problem: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.roseStrong)
        case .idle: EmptyView()
        }
    }

    @ViewBuilder var statusText: some View {
        switch check {
        case .available: Text("@\(HandleRule.normalize(handle)) is available").font(.footnote).foregroundStyle(Palette.mintStrong)
        case .problem(let m): Text(m).font(.footnote).foregroundStyle(Palette.roseStrong)
        default: Text("3–20 letters, numbers, underscores or periods.").font(.footnote).foregroundStyle(Palette.inkSecondary)
        }
    }

    var fieldState: NudgeTextFieldStyle.State {
        switch check {
        case .available: .valid
        case .problem: .error
        default: focused == .handle ? .focused : .normal
        }
    }

    /// Validates locally, then asks the server 400 ms after the last keystroke (ACC-3.1).
    private func runCheck() async {
        let h = HandleRule.normalize(handle)
        guard !h.isEmpty else { check = .idle; return }
        if let problem = HandleRule.validate(h) { check = .problem(problem.message); return }
        check = .checking
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        if app.isPreview { check = .available; return }
        do {
            let r = try await app.api.handleAvailability(h)
            guard !Task.isCancelled else { return }
            switch (r.available, r.reason) {
            case (true, _): check = .available
            case (false, .taken?): check = .problem("That handle is taken.")
            case (false, .reserved?): check = .problem(HandleRule.Problem.reserved.message)
            default: check = .problem("That handle isn't allowed.")
            }
        } catch {
            check = .problem("Couldn't check right now.")
        }
    }

    private func submit() async {
        working = true
        defer { working = false }
        do {
            var me = try await app.api.claimHandle(HandleRule.normalize(handle))
            var patch = MePatch(displayName: displayName.nonEmptyString)
            if let avatarImage, let jpeg = avatarImage.resizedJPEG(maxEdge: 512) {
                let upload = try await app.api.avatarUploadURL()
                var req = URLRequest(url: upload.uploadUrl)
                req.httpMethod = "PUT"
                req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
                _ = try? await URLSession.shared.upload(for: req, from: jpeg)
                patch.avatarKey = upload.avatarKey
            }
            me = try await app.api.updateMe(patch)
            app.apply(me: me)
        } catch APIError.server(409, _, _) {
            check = .problem("Someone just took that handle.")
        } catch {
            check = .problem(error.localizedDescription)
        }
    }
}

import Networking

extension UIImage {
    func resizedJPEG(maxEdge: CGFloat, quality: CGFloat = 0.85) -> Data? {
        let scale = min(1, maxEdge / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
            .jpegData(compressionQuality: quality)
    }
}

private struct AvatarPickerLabel: View, Sendable {
    let image: UIImage?
    let name: String
    let seed: String?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image {
                Image(uiImage: image).resizable().scaledToFill().frame(width: 96, height: 96).clipShape(Circle())
            } else {
                AvatarView(name: name, size: AvatarSize.hero, seed: seed)
            }
            Image(systemName: "camera.fill").font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.lavenderStrong)
                .frame(width: 32, height: 32)
                .background(Palette.lavender, in: Circle())
                .overlay(Circle().strokeBorder(Palette.bg, lineWidth: 3))
        }
    }
}
