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
// reliably produce an up-to-date layer texture, and the mask Image is exactly
// that. `OpacityMask` keeps its sources live internally, and measured 63/63
// correct on the same fixture.
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

    // Parallax offsets in output logical pixels, supplied by DepthParallax.
    // The two layers are moved by different amounts so the scene reads as
    // having depth; see the LAYERING note below.
    property real backgroundX: 0
    property real backgroundY: 0
    property real foregroundX: 0
    property real foregroundY: 0

    // Spare area the background layer must carry, in output logical pixels, so
    // that shifting it never pulls its border into view. Supplied by the
    // tracker, which is the only thing that knows how far an offset can reach.
    property real reserveX: 0
    property real reserveY: 0

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

    // LAYERING — why this surface draws the wallpaper twice.
    //
    // With no parallax there is only one thing to draw: the masked foreground.
    // The background is the compositor's own wallpaper, which is a separate
    // surface beneath this one and needs no help from us.
    //
    // Parallax breaks that arrangement. Two layers can only move by different
    // amounts if we own both of them, and the compositor's wallpaper cannot be
    // asked to shift. So this surface also draws the full wallpaper underneath
    // its own foreground copy, and the two move at different rates.
    //
    // The duplicate is not visible at rest: both copies are the same image at
    // the same scale, and the foreground sits exactly on top of the region it
    // was cut from. It only becomes visible while navigating, which is the
    // whole point.
    //
    // The alternative -- moving only the foreground and leaving the
    // compositor's wallpaper still -- was rejected. It is cheaper, but a
    // floating cut-out over a pinned background reads as a rendering glitch
    // rather than as depth, because the foreground sliding away from the
    // scenery it is composited from is exactly what a misaligned mask looks
    // like.

    // BACKGROUND COPY — the whole wallpaper, unmasked.
    //
    // This layer is the one that can expose an edge: behind it there is only
    // the compositor's own wallpaper. It therefore carries spare area around
    // the viewport, so a shift slides new material into view instead of
    // revealing a gap.
    //
    // Two ways to get that spare area, and only one is correct:
    //
    //   * `scale: 1 + eps` -- rejected. Scaling resamples about the layer's
    //     centre, which on its own displaces the background relative to the
    //     foreground by `size * eps / 2`: 25 logical pixels at a 2% overscan,
    //     larger than the parallax travel itself. The scene would be visibly
    //     doubled whenever the user stood still.
    //
    //   * A larger outer box with the image sized to the *viewport*, centred
    //     inside it -- what this does. The image keeps the exact geometry the
    //     foreground uses, so the two agree pixel for pixel at rest, and the
    //     surrounding spare area is what allows a shift. Overscan and parallax
    //     are therefore independent: the offsets below are applied on top of an
    //     image that has not moved at all.
    readonly property int backgroundOverscan: {
        // Cover the largest offset this layer can reach, from either direction,
        // with a margin so an extreme travel still does not clip.
        const travel = Math.max(reserveX, reserveY);
        return Math.ceil(travel) + 8;
    }

    Item {
        id: backgroundLayer

        // The viewport box, grown outwards by the overscan. Its centre is the
        // viewport's centre, so a child centred in it is centred on screen.
        x: -root.backgroundOverscan
        y: -root.backgroundOverscan
        width: parent.width + 2 * root.backgroundOverscan
        height: parent.height + 2 * root.backgroundOverscan

        Image {
            id: backgroundImage

            // Sized to the viewport, not to the enlarged box -- see the note
            // above. Centring it in the box keeps it aligned with the
            // foreground, which spans the viewport exactly.
            width: parent.width - 2 * root.backgroundOverscan
            height: parent.height - 2 * root.backgroundOverscan
            anchors.centerIn: parent
            source: root.wallpaperPath !== "" ? "file://" + root.wallpaperPath : ""
            fillMode: Image.PreserveAspectCrop
            cache: false
            visible: false
            layer.enabled: true
        }

        // The parallax shift is applied here, around the image rather than on
        // it, so it composes with the centring above instead of fighting it.
        transform: Translate {
            x: root.backgroundX
            y: root.backgroundY
        }
    }

    // Foreground copy: the wallpaper cut to the mask. Both inputs shift
    // FOREGROUND COPY — the wallpaper cut to the mask.
    //
    // Both inputs shift together, so the cut-out stays aligned with the scenery
    // it was taken from; a mask that lags its own image is the classic
    // misregistration artefact and would read as a halo.
    //
    // Unlike the background this layer needs no spare area. Where it moves away
    // from, the background layer is already exposed, and that is precisely the
    // intended effect: the near scenery slides aside and reveals what was
    // behind it. There is no gap to fill because the layer below is opaque.
    Item {
        id: foregroundLayer

        anchors.fill: parent

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

        // Applied to the whole layer, so the mask travels with the image it
        // masks. `Translate` rather than `x`/`y` so it does not disturb the
        // `anchors.fill` above.
        transform: Translate {
            x: root.foregroundX
            y: root.foregroundY
        }
    }
}

