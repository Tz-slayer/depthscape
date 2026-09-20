import QtQuick
// `MultiEffect` for the overview blur. This is stock Qt, unlike the
// Qt5Compat.GraphicalEffects module the old mask implementation needed.
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland

// Bottom-most of the three Depthscape surfaces: the wallpaper with the subject
// cut out of it.
//
// WHY WE DRAW THIS OURSELVES
//
// The engine emits a pair — `background.png` (the scene, with the subject's
// region replaced by a blurred fill) and `foreground.png` (the subject alone).
// Somebody has to draw the background, and it cannot be the compositor or DMS:
//
//   * DMS's own wallpaper draws the *whole* scene, subject included. Drawing our
//     foreground on top of that is arithmetically a no-op wherever the subject
//     is opaque — the two layers show the same pixels — so the depth effect is
//     invisible no matter how the layers are ordered. That is measured, not
//     assumed: recompositing the pair over DMS's wallpaper at threshold 0.3
//     differs from the plain wallpaper by MAE 0.0 across the subject.
//   * Letting the compositor put us in the overview backdrop is not an option
//     either: `place-within-backdrop` parks a surface at the very bottom of the
//     backdrop, underneath DMS's wallpaper and its overview blur, where it is
//     completely invisible (measured: 0.0% of sampled pixels).
//
// So Depthscape is a complete wallpaper replacement. When the effect is on, the
// user should switch DMS's wallpaper off (or to a flat colour) — the settings
// page says so. Nothing here reads or writes DMS's wallpaper configuration.
//
// LAYER AND ORDERING
//
// `background` layer, no `place-within-backdrop`. Within a layer, surfaces stack
// by map order — last mapped wins — and DepthDaemon sequences the three so that
// this one is mapped first, then the widgets, then the foreground. See
// DepthDaemon.qml for why the ordering only has to be established once.
//
// An earlier revision tried to reach the overview backdrop so the composite
// would not be repeated in every workspace card. It does not work, and the
// user's actual requirement is milder than that: the overview is allowed to show
// nothing of ours at all. DepthDaemon hides the foreground and the widgets while
// the overview is open, and this surface does what DMS's own wallpaper does —
// blurs itself, so the overview reads as blurred wallpaper rather than as a
// crisp image with our own widgets floating over it.
PanelWindow {
    id: root

    // Deliberately NOT called `screen`: PanelWindow already has a `screen`
    // property, and redeclaring it shadows the base one, so every instance would
    // fall back to the compositor's default output instead of the one it was
    // handed. Assign `screen: targetScreen` below instead.
    required property var targetScreen

    property string backgroundPath: ""

    /// Blur instead of drawing crisply — set while the niri overview is open.
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

    // Matching DMS's own overview blur exactly, so the two are indistinguishable
    // side by side. DMS's parameters are `WallpaperBackground.qml`'s
    // `overviewBlurLoader`: blur 0.8, blurMax 75, autoPaddingEnabled false.
    //
    // `autoPaddingEnabled: false` matters: with padding on, the effect grows the
    // item to make room for the blur, which would shift and shrink the image
    // relative to the crisp state and read as a zoom on every overview toggle.
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
