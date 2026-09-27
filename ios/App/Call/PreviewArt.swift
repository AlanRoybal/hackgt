import SwiftUI

/// Stand-in camera-roll photos for screenshot mode and the fallback when a photo URL fails. The pictures are
/// the Figma file's placeholder photography (Components › Image assets, Unsplash), bundled under
/// Assets.xcassets/Preview.
struct SceneryPhoto: View {
    let name: String

    var body: some View {
        FilledImage(asset: asset)
    }

    var asset: String {
        let n = name.lowercased()
        if n.contains("cake") || n.contains("birthday") { return "ph_cake" }
        if n.contains("beach") || n.contains("lake") { return "ph_beach" }
        if n.contains("dog") || n.contains("max") { return "ph_dog" }
        return "ph_mountain"
    }
}

/// Stand-in "video frame" of a person for screenshot mode (Figma img/vid_mom and img/vid_me).
struct PreviewVideoFrame: View {
    enum Style { case remote, me }
    let style: Style

    var body: some View {
        FilledImage(asset: style == .remote ? "vid_mom" : "vid_me")
    }
}

/// Fills whatever frame it's given, cropping the image rather than letting it push the layout.
private struct FilledImage: View {
    let asset: String

    var body: some View {
        Color.clear
            .overlay(Image(asset).resizable().scaledToFill())
            .clipped()
    }
}
