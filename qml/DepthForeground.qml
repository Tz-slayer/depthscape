import QtQuick
import Quickshell
import Quickshell.Wayland
import Qt5Compat.GraphicalEffects

// Full-screen, click-through foreground layer.
//
// This surface is what makes the whole effect possible. It sits on the `bottom`
// layer, which layer-shell orders above `background` (the wallpaper) and below
// ordinary application windows, which the compositor places between `bottom`
// and `top`. That is exactly the stacking an iOS depth lock screen uses.
//
// Nothing in the documented DMS plugin API provides such a layer. It exists
// only because a plugin may create its own PanelWindow, the same technique
// DankIsland uses for its overlay surface.
//
// STACKING CAVEAT — read before moving this surface to another layer.
//
// DMS draws desktop widgets on `bottom` too (DesktopPluginWrapper.qml, the
// default branch of `WlrLayershell.layer`), not on `background` as the plugin
// docs claim. So the foreground shares a layer with the widgets it is supposed
// to occlude, and the layer-shell *layer* alone does not order the two.
//
// Within a layer, niri/smithay stack surfaces by **map order**: the surface
// mapped last is drawn on top (measured, see docs/depthscape.md §14.1).
// DMS relies on the same rule and rebuilds its widgets whenever the instance
// list changes (DesktopWidgetLayer.qml: "Layer surfaces stack by map order").
// DepthDaemon therefore re-maps this surface after such a rebuild — do not
// remove that, or the foreground silently drops behind the widgets.
//
// MASKING — why OpacityMask and not MultiEffect.
//
// `MultiEffect { maskEnabled: true; maskSource: <hidden Image> }` does NOT work
// reliably here. Measured: 28 of 63 opaque sample points came out unmasked,
// with `layer.effect: MultiEffect` and with MultiEffect-as-an-item alike.
// The cause is that `layer.enabled: true` on an *invisible* Image does not
// reliably produce an up-to-date layer texture, and the mask Image (1.4 MB PNG,
// 5120x2880) is exactly that. `OpacityMask` keeps its sources live internally,
// and measured 63/63 correct on the same fixture.
//
// The cost is a dependency DMS itself does not use: Qt5Compat.GraphicalEffects
// (packaged as qt6-5compat / qml6-module-qt5compat-graphicaleffects). It is
// listed in plugin.json `dependencies` and checked by StartupCheck.qml.
PanelWindow {
    id: root

    // Deliberately NOT called `screen`: PanelWindow already has a `screen`
    // property, and redeclaring it shadows the base one, which makes every
    // instance fall back to the compositor's default output instead of the one
    // it was handed. Assign `screen: targetScreen` below instead.
    // (DankIsland's IslandWindow uses the same indirection.)
    required property var targetScreen

    // Overridable so the component stays testable, and because a compositor
    // that does not place regular windows between `bottom` and `top` would
    // need a different layer (see docs/depthscape.md §14.1).
    property int layer: WlrLayer.Bottom

    property string wallpaperPath: ""
    property string maskPath: ""

    readonly property bool active: wallpaperPath !== "" && maskPath !== ""

    screen: root.targetScreen
    visible: root.active
    color: "transparent"
    implicitWidth: root.targetScreen ? root.targetScreen.width : 0
    implicitHeight: root.targetScreen ? root.targetScreen.height : 0

    WlrLayershell.namespace: "dms:plugins:depthscape-foreground"
    WlrLayershell.layer: root.layer
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
        top: true
        left: true
        right: true
        bottom: true
    }

    // An empty input region makes the surface completely click-through, so the
    // desktop widgets underneath keep receiving input normally.
    mask: Region {}

    // The wallpaper, kept off-screen: only its texture is used.
    Image {
        id: wallpaperImage

        anchors.fill: parent
        source: root.wallpaperPath !== "" ? "file://" + root.wallpaperPath : ""
        fillMode: Image.PreserveAspectCrop
        cache: false
        visible: false
        layer.enabled: true
    }

    // The mask is RGBA with the coverage in the alpha channel (see
    // docs/depthscape.md §7.2). OpacityMask reads exactly that alpha.
    Image {
        id: maskImage

        anchors.fill: parent
        source: root.maskPath !== "" ? "file://" + root.maskPath : ""
        fillMode: Image.PreserveAspectCrop
        cache: false
        visible: false
        layer.enabled: true
    }

    OpacityMask {
        anchors.fill: parent
        source: wallpaperImage
        maskSource: maskImage
    }
}

