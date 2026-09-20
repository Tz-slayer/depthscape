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
PanelWindow {
    id: root

    // Deliberately NOT called `screen` — see DepthBackground.qml.
    required property var targetScreen

    property string foregroundPath: ""

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

    // Must scale identically to DepthBackground's Image, or the subject drifts
    // away from the hole it was cut out of. Both use PreserveAspectCrop and both
    // fill the same rect, so they agree by construction.
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
