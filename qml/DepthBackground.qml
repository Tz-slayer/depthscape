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

    /// Parallax offset in output logical pixels, shared by all three surfaces of
    /// this output. Supplied by DepthParallax; see DepthParallax.qml for the
    /// curve and DepthForeground.qml for why the two layers move oppositely.
    property real offsetX: 0
    property real offsetY: 0

    /// Spare area this surface must carry on every side, in output logical
    /// pixels, so that a shift slides new material into view instead of pulling
    /// this surface's own border on screen. Comes from the tracker, which is the
    /// only thing that knows how far an offset can reach.
    property real reserve: 0

    /// Opacity of the whole surface, driven by DepthDaemon so that all three
    /// fade together while the overview is open. One value for all three, never
    /// per-surface: the foreground's silhouette has to stay registered against
    /// the hole it was cut from, and two disagreeing opacities mid-ramp read as
    /// a seam along the contour.
    property real overviewOpacity: 1

    readonly property bool active: backgroundPath !== ""

    /// Overscan in logical pixels. Rounded up and given a small margin so an
    /// extreme travel still does not clip.
    ///
    /// This is deliberately a *container* size rather than a scale factor on the
    /// image. See the note on the Image below.
    readonly property real overscan: root.reserve > 0 ? Math.ceil(root.reserve) + 8 : 0

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

    // THE OVERVIEW FADE
    //
    // `PanelWindow` is a Wayland surface, not a plain Item, and has no
    // `opacity` of its own — assigning one is a startup error. The fade
    // therefore has to live on a content root inside it, which is why every
    // visual in this file (the fill, the image, the blur) sits under this one
    // Item rather than directly under the window.
    //
    // One value for all three surfaces, never per-surface: the foreground's
    // silhouette has to stay registered against the hole it was cut from, and
    // two disagreeing opacities mid-ramp read as a seam along the contour.
    Item {
        id: fader

        anchors.fill: parent
        opacity: root.overviewOpacity

        // A flat colour behind the image, exactly as DMS's own wallpaper does
        // (`WallpaperBackground.qml` draws `effectiveWallpaperBackgroundColor`
        // before the image). Two things depend on it:
        //
        //   * While the image is still decoding, `color: "transparent"` would
        //     let whatever is below show through as a full-screen flash on every
        //     regeneration.
        //   * The image is scaled with `PreserveAspectCrop`, so on a wallpaper
        //     whose aspect ratio differs from the output there is nothing to
        //     crop and the thumbnail is letterboxed — the flat colour makes that
        //     look intentional instead of broken.
        //
        // The parallax shift is applied to the *container* below rather than to
        // this rectangle, so the fill never runs out from under the image: it is
        // grown with the container and simply stays behind everything.
        Rectangle {
            anchors.fill: container
            color: SettingsData.effectiveWallpaperBackgroundColor
        }

        // The oversized box. Its centre is the viewport's centre, so a child
        // sized to the viewport and centred in it occupies exactly the screen
        // rect.
        //
        // THE OVERSIZE IS ON THE BOX, NOT ON THE IMAGE, AND THAT IS THE WHOLE
        // POINT.
        //
        // A wallpaper on a 16:9 output from a 16:9 source is scaled with
        // `PreserveAspectCrop` and has no slack at all: shifting it eight pixels
        // exposes a stripe of whatever is behind. Spare area is the only fix,
        // and there are two ways to get it:
        //
        //   * `scale: 1 + eps` on the image — rejected. Scaling resamples about
        //     the image's *own centre* and displaces it by `size × eps / 2`,
        //     which at a realistic overscan is 25+ logical pixels — larger than
        //     the parallax travel itself. The scene would be visibly off-centre
        //     while the user stood still.
        //
        //   * A larger box with the image still sized to the viewport — what
        //     this does. The image keeps the exact geometry the foreground uses,
        //     so the two agree pixel for pixel at rest, and the surrounding
        //     spare area is what a shift slides into view. Overscan and parallax
        //     are therefore independent: the offset below is applied on top of
        //     an image that has not moved at all.
        Item {
            id: container

            x: -root.overscan
            y: -root.overscan
            width: parent.width + 2 * root.overscan
            height: parent.height + 2 * root.overscan

            // Applied here, around the image rather than on it, so it composes
            // with the centring below instead of fighting it. `Translate` cannot
            // change the image's rendered size, which is what keeps the two
            // layers aligned.
            transform: Translate {
                x: root.offsetX
                y: root.offsetY
            }

            // The image is emitted at the wallpaper's own resolution and aspect
            // ratio, so on an output smaller than the wallpaper it is scaled
            // *down* to fit. `PreserveAspectCrop` rather than `Stretch` because
            // the two surfaces must be scaled *identically* — any difference
            // between them shows up as a seam along the subject's silhouette.
            Image {
                id: backdrop

                // Sized to the VIEWPORT, not to the enlarged box — see the note
                // on `container`. Centring it in the box keeps it on screen at
                // rest and aligned with DepthForeground's copy.
                width: parent.width - 2 * root.overscan
                height: parent.height - 2 * root.overscan
                anchors.centerIn: parent

                source: root.backgroundPath !== "" ? "file://" + root.backgroundPath : ""
                fillMode: Image.PreserveAspectCrop
                // The cache is keyed by URL, and a regenerated image keeps the
                // same URL, so a changed file would be served from the old
                // texture. The daemon gives every generation a distinct path, but
                // disabling the cache also avoids holding two full-resolution
                // textures per output.
                cache: false
                asynchronous: true
                smooth: true
            }

            // Matching DMS's own overview blur exactly, so the shared backdrop
            // is indistinguishable from what the user sees with this plugin off.
            // The parameters are `WallpaperBackground.qml`'s
            // `overviewBlurLoader`: blur 0.8, blurMax 75, autoPaddingEnabled
            // false.
            //
            // `autoPaddingEnabled: false` matters: with padding on the effect
            // grows the item to make room for the blur, which shifts and shrinks
            // the image relative to the crisp state and reads as a zoom on every
            // overview toggle.
            //
            // Inside `container` rather than outside it, so the blurred result
            // moves with the image and is clipped by the same box.
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
    }
}
