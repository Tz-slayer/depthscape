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

    /// Parallax offset in output logical pixels. The background receives exactly
    /// this value, not a fraction of it — see DepthDaemon.qml and DepthBackground.qml for why.
    property real offsetX: 0
    property real offsetY: 0
    property int motionDuration: 240
    property bool initialized: false

    /// Spare area this surface must carry on every side, in output logical
    /// pixels. The same value the background gets, so the two canvases are the
    /// same size and crop identically.
    property real reserve: 0

    /// Opacity of the whole surface, driven by DepthDaemon so that all three
    /// fade together while the overview is open. Deliberately the same value the
    /// background receives: the silhouette has to stay registered against the
    /// hole it was cut from, and two disagreeing opacities mid-ramp read as a
    /// seam along the contour.
    property real overviewOpacity: 1

    readonly property bool active: foregroundPath !== ""
    readonly property real dpr: (targetScreen && targetScreen.devicePixelRatio) ? targetScreen.devicePixelRatio : 1

    /// Overscan in logical pixels — byte-for-byte the same expression
    /// DepthBackground uses. The two surfaces have to lay out an identical
    /// rectangle or `PreserveAspectCrop` crops them differently and the subject
    /// no longer lines up with the hole it was cut from.
    readonly property real overscan: root.reserve > 0 ? Math.ceil(root.reserve) + 8 : 0

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

        // THIS LAYER HAS SPARE AREA TOO, and leaving it out was a bug.
        //
        // The earlier note here argued that no overscan was needed because the
        // background underneath is opaque, so wherever the subject slides away
        // from, the background simply shows through. That held while the two
        // layers moved by different amounts, because what showed through was the
        // far plane and reading it as depth was the point. It does not hold now
        // that they move together: this image's own border slides into the
        // viewport and cuts a straight edge across the subject, while the hole
        // the subject belongs in keeps going underneath it.
        //
        // The canvas is oversized and the image fills *that*, not the viewport.
        // Oversizing the box while keeping the image at viewport size — which is
        // what the background did — is what leaves a stripe of bare colour at
        // the edge on every shift: the box moves, the image inside it is no
        // wider than the screen was, and the gap between them comes on screen.
        //
        // It is a container size rather than a `scale` on the image for the
        // reason DepthBackground spells out: scaling resamples about the image's
        // own centre and displaces a static scene by `size × eps / 2`, which is
        // larger than the travel being reserved for.
        Item {
            id: container

            x: -root.overscan + root.offsetX
            y: -root.overscan + root.offsetY
            width: parent.width + 2 * root.overscan
            height: parent.height + 2 * root.overscan

            Behavior on x {
                enabled: root.initialized
                NumberAnimation {
                    duration: root.motionDuration
                    easing.type: Easing.OutCubic
                }
            }

            Behavior on y {
                enabled: root.initialized
                NumberAnimation {
                    duration: root.motionDuration
                    easing.type: Easing.OutCubic
                }
            }

            Image {
                id: cutout

                anchors.fill: parent
                source: root.foregroundPath !== "" ? "file://" + root.foregroundPath : ""
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(
                    Math.max(1, Math.round(container.width * root.dpr)),
                    Math.max(1, Math.round(container.height * root.dpr)))
                cache: true
                asynchronous: true
                retainWhileLoading: true
                smooth: true

                property bool hasLoaded: false
                onStatusChanged: {
                    if (status === Image.Ready)
                        hasLoaded = true;
                }
                opacity: hasLoaded ? 1.0 : 0.0
                Behavior on opacity {
                    NumberAnimation { duration: 150 }
                }
            }
        }
    }

    Component.onCompleted: initialized = true
}
