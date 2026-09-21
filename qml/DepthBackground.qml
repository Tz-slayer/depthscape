import QtQuick
// `MultiEffect` for the overview blur — stock Qt, unlike the
// Qt5Compat.GraphicalEffects module the old mask implementation needed.
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.Common

// Bottom-most of the three Depthscape surfaces: the wallpaper with the subject
// cut out of it. This is the one that owns the shared backdrop.
//
// WHY WE DRAW THIS OURSELVES
//
// The engine emits a pair — `background.png` (the scene, with the subject's
// region replaced by a blurred fill) and `foreground.png` (the subject alone).
// Somebody has to draw the background, and it cannot be DMS:
//
//   * DMS's own wallpaper draws the *whole* scene, subject included. Drawing our
//     foreground on top of that is arithmetically a no-op wherever the subject
//     is opaque — the two layers show the same pixels — so the depth effect is
//     invisible no matter how the layers are ordered. That is measured, not
//     assumed: recompositing the pair over DMS's wallpaper at threshold 0.3
//     differs from the plain wallpaper by MAE 2.19, and every bit of that
//     difference is on chrome we drew ourselves — none of it on the subject.
//
// So Depthscape draws its own background, and DMS's wallpaper stays mapped
// underneath as a fallback: it covers the brief window before our images have
// decoded, so switching wallpapers does not flash. Nothing here reads or writes
// DMS's wallpaper configuration.
//
// LAYER *AND* THE SHARED BACKDROP
//
// These are two separate things, and conflating them is what produced the bug
// this arrangement fixes. Both are required:
//
//   1. The layer. `background` is the lowest of the four layer-shell layers, so
//      application windows and the bar are always drawn above us — which is
//      what a wallpaper wants.
//
//   2. The `place-within-backdrop` rule. **A `background` surface is NOT
//      automatically part of niri's shared backdrop** — the single image that
//      spans every workspace card and the gaps between them in the overview.
//      It only joins the backdrop when a layer rule carrying
//      `place-within-backdrop true` matches its namespace:
//
//          layer-rule {
//              match namespace="^depthscape:"
//              place-within-backdrop true
//          }
//
//      Without that rule the surface is an ordinary background surface, and
//      niri clones it into *every* workspace card: the overview fills edge to
//      edge with one copy of the wallpaper per card, each cropped to its own
//      card geometry. That is exactly the failure this fixes, and no choice of
//      layer fixes it — the rule is the only lever. DMS's own wallpaper is in
//      the backdrop for the same reason, via a generated rule for `^quickshell$`.
//
// The rule is installed by the user (see README); a plugin cannot add one for
// itself. `^depthscape:` is a prefix match, so one rule covers all three of our
// surfaces.
//
// ORDERING
//
// Within the backdrop, surfaces stack by map order — last mapped wins — and
// DepthDaemon sequences the three so that this one is mapped first, then the
// widgets, then the foreground. This surface stays mapped across the overview
// (it *is* the backdrop); DepthDaemon hides only the widgets and the foreground
// there, so the overview shows a clean wallpaper rather than a clock floating in
// the background.
PanelWindow {
    id: root

    // Deliberately NOT called `screen`: PanelWindow already has a `screen`
    // property, and redeclaring it shadows the base one, so every instance would
    // fall back to the compositor's default output instead of the one it was
    // handed. Assign `screen: targetScreen` below instead.
    required property var targetScreen

    property string backgroundPath: ""

    /// Blur instead of drawing crisply — set while the niri overview is open, so
    /// the shared backdrop matches what DMS does with its own wallpaper
    /// (`SettingsData.blurWallpaperOnOverview`).
    property bool blurred: false

    readonly property bool active: backgroundPath !== ""

    screen: root.targetScreen
    visible: root.active
    color: "transparent"
    implicitWidth: root.targetScreen ? root.targetScreen.width : 0
    implicitHeight: root.targetScreen ? root.targetScreen.height : 0

    WlrLayershell.namespace: "depthscape:background"
    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
        top: true
        left: true
        right: true
        bottom: true
    }

    // An empty input region makes the surface completely click-through, so the
    // desktop widgets above it and the windows beyond them keep receiving input
    // normally.
    mask: Region {}

    // A flat colour behind the image, exactly as DMS's own wallpaper does
    // (`WallpaperBackground.qml` draws `effectiveWallpaperBackgroundColor`
    // before the image). Two things depend on it:
    //
    //   * While the image is still decoding, `color: "transparent"` would let
    //     whatever is below show through as a full-screen flash on every
    //     regeneration.
    //   * The image is scaled with `PreserveAspectCrop`, so on a wallpaper whose
    //     aspect ratio differs from the output there is nothing to crop and the
    //     thumbnail is letterboxed — the flat colour makes that look intentional
    //     instead of broken.
    Rectangle {
        anchors.fill: parent
        color: SettingsData.effectiveWallpaperBackgroundColor
    }

    // The image is emitted at the same aspect ratio as the wallpaper but at a
    // reduced resolution (long edge capped at 1920), so it is scaled up to fill
    // the output. `PreserveAspectCrop` rather than `Stretch` because the two
    // surfaces must be scaled *identically* — any difference between them shows
    // up as a seam along the subject's silhouette.
    Image {
        id: backdrop

        anchors.fill: parent
        source: root.backgroundPath !== "" ? "file://" + root.backgroundPath : ""
        fillMode: Image.PreserveAspectCrop
        // The cache is keyed by URL, and a regenerated image keeps the same URL,
        // so a changed file would be served from the old texture. The daemon
        // gives every generation a distinct path, but disabling the cache also
        // avoids holding two 1920x1080 textures per output.
        cache: false
        asynchronous: true
        smooth: true
    }

    // Matching DMS's own overview blur exactly, so the shared backdrop is
    // indistinguishable from what the user sees with this plugin off. The
    // parameters are `WallpaperBackground.qml`'s `overviewBlurLoader`: blur 0.8,
    // blurMax 75, autoPaddingEnabled false.
    //
    // `autoPaddingEnabled: false` matters: with padding on the effect grows the
    // item to make room for the blur, which shifts and shrinks the image relative
    // to the crisp state and reads as a zoom on every overview toggle.
    Loader {
        anchors.fill: parent
        active: root.blurred && root.active

        sourceComponent: MultiEffect {
            anchors.fill: parent
            source: backdrop
            blurEnabled: true
            blur: 0.8
            blurMax: 75
            autoPaddingEnabled: false
        }
    }

}
