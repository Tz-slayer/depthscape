import QtQuick
import Quickshell
import Quickshell.Wayland

// Top-most of the three Depthscape surfaces: the subject, cut out of the scene.
//
// WHY A PLAIN Image IS ENOUGH
//
// The engine writes a straight-alpha RGBA PNG whose colour channel holds the
// subject verbatim and whose alpha channel holds the coverage. Compositing that
// is exactly what sampling an RGBA image does, so there is no mask to marry it
// with, no shader, and no hidden layers.
//
// Straight alpha also means the previous `OpacityMask` from
// Qt5Compat.GraphicalEffects is gone. That module is one DMS itself does not use,
// so it was a dependency every user had to install for a plugin that otherwise
// needed nothing.
//
// LAYER AND ORDERING
//
// Same layer as the background and the widgets (`background`), mapped last so it
// draws above both — that is what puts the subject in front of the clock and
// gives the wallpaper its depth. DepthDaemon owns that sequencing; this file
// only has to be a correctly-behaved surface.
//
// `background` plus the `place-within-backdrop` rule, not `bottom`: see
// DepthBackground.qml for the whole argument. The short version is that the rule
// is what makes the surface shared across workspace cards instead of cloned into
// each one.
PanelWindow {
    id: root

    // Deliberately NOT called `screen` — see DepthBackground.qml.
    required property var targetScreen

    property string foregroundPath: ""

    /// Parallax offset in output logical pixels. The two layers move by
    /// *different* amounts — see the LAYERING note below for why.
    property real offsetX: 0
    property real offsetY: 0

    /// Opacity of the whole surface, driven by DepthDaemon so that all three
    /// fade together while the overview is open. Deliberately the same value the
    /// background receives: the silhouette has to stay registered against the
    /// hole it was cut from, and two disagreeing opacities mid-ramp read as a
    /// seam along the contour.
    property real overviewOpacity: 1

    readonly property bool active: foregroundPath !== ""

    screen: root.targetScreen
    visible: root.active
    color: "transparent"
    implicitWidth: root.targetScreen ? root.targetScreen.width : 0
    implicitHeight: root.targetScreen ? root.targetScreen.height : 0

    WlrLayershell.namespace: "depthscape:foreground"
    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
        top: true
        left: true
        right: true
        bottom: true
    }

    // Click-through: the subject looks like it is on the wallpaper, and it must
    // not swallow clicks meant for the widgets or the desktop beneath it.
    mask: Region {}

    // NO SPARE AREA HERE, AND THAT IS DELIBERATE.
    //
    // The background layer carries an overscan because behind *it* there is
    // nothing but the compositor's flat colour. This layer is different: behind
    // it is DepthBackground, opaque and already covering the whole viewport.
    // Where the subject moves away from, the background is exposed — and that is
    // precisely the intended effect, the near scenery sliding aside to reveal
    // what was behind it. There is no gap to fill because the layer below is
    // opaque, so an overscan here would only add texture to decode.
    //
    // The offset is a `Translate` and not a `x`/`y` on the Image, for the same
    // reason as the background: a translation cannot change the rendered size,
    // so this copy stays pixel-for-pixel registered with DepthBackground's while
    // both move.
    //
    // The wrapper also carries the overview fade. `PanelWindow` is a Wayland
    // surface and has no `opacity` of its own — assigning one is a startup
    // error — so the fade has to live on a content root like this one. Same
    // value as the background receives: the silhouette has to stay registered
    // against the hole it was cut from, and two disagreeing opacities mid-ramp
    // read as a seam along the contour.
    Item {
        id: shifted

        anchors.fill: parent
        opacity: root.overviewOpacity

        transform: Translate {
            x: root.offsetX
            y: root.offsetY
        }

        // Must scale identically to DepthBackground's Image, or the subject
        // drifts away from the hole it was cut out of. Both use
        // PreserveAspectCrop and both fill the same viewport rect, so they agree
        // by construction.
        Image {
            anchors.fill: parent
            source: root.foregroundPath !== "" ? "file://" + root.foregroundPath : ""
            fillMode: Image.PreserveAspectCrop
            // Same reasoning as the background: the URL is stable across
            // regenerations and these are full-screen RGBA textures.
            cache: false
            asynchronous: true
            smooth: true
        }
    }
}
