import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Services

// The wallpaper, drawn unchanged apart from the workspace-following offset
// and an in-place blur while niri's overview is open. Bottom-most of the two
// Depthscape surfaces.
//
// WHY DRAW IT AT ALL
//
// The plugin could leave the wallpaper entirely to DMS and only supply the mask.
// It draws its own for one reason: the mask has to be applied to a widget layer
// that sits *above* a wallpaper, and a plugin cannot mask DMS's widgets — the
// framework hosts those and exposes no API to reach them. So Depthscape hosts
// its own widget layer, which means it also has to supply the wallpaper that
// layer is composited against. Drawing it here keeps the two in one place and
// independent of whatever DMS is doing with its own wallpaper.
//
// THE CANVAS IS OVERSIZED BY THE PARALLAX RESERVE
//
// The margin grows the canvas by the SAME factor on both axes (see
// DepthScrollMath.margin), so its aspect ratio still matches the source and
// `PreserveAspectCrop` has nothing to crop. That matters more here than in a
// plain wallpaper: the occlusion mask on the widget surface is drawn onto the
// *same* canvas geometry (see DepthBackgroundWidgetHost), and the two only stay
// pixel-aligned while the canvas never reframes the image. The margin depends
// only on the output size and the travel budget — never on the offset — so
// nothing here is recomputed while the canvas animates.
//
// When parallax is disabled the reserve is zero and this file degenerates to
// the plain full-screen image it was before, with no extra texture cost.
//
// LAYER *AND* THE SHARED BACKDROP
//
// Two separate things matter for Niri rendering:
//
//   1. The layer. `background` is the lowest of the four layer-shell layers, so
//      application windows and the bar are always drawn above us.
//
//   2. The `place-within-backdrop` rule places Depthscape's background surfaces
//      in Niri's shared backdrop behind the workspace cards and between them.
PanelWindow {
    id: root

    // Deliberately NOT called `screen`: PanelWindow already has a `screen`
    // property, and redeclaring it shadows the base one, so every instance would
    // fall back to the compositor's default output instead of the one it was
    // handed.
    required property var targetScreen

    property string wallpaperPath: ""

    // Workspace-following offset in logical pixels, driven by
    // DepthWorkspaceTracker through DepthDaemon. Zero when parallax is off.
    property real offsetX: 0
    property real offsetY: 0
    // Slack per axis as a FRACTION of that axis, plus the kill switch. The
    // canvas has to grow by the same factor on both axes or
    // PreserveAspectCrop silently reframes the image.
    property bool parallaxEnabled: false
    property real maxTravel: 0.25
    property bool spatialEnabled: false
    property bool spatialAssetsReady: false
    property bool spatialDisplayActive: false
    property real imageWidth: 0
    property real imageHeight: 0
    property string spatialBackgroundPath: ""
    property string spatialForegroundPath: ""
    property string spatialDepthPath: ""
    property string spatialMattePath: ""
    property string spatialInfluencePath: ""
    property real spatialPointerX: 0
    property real spatialPointerY: 0
    property real spatialTravel: 0.03
    property int motionDuration: 350

    function encodeFileUrl(path) {
        if (!path)
            return "";
        const clean = path.startsWith("file://") ? path.slice(7) : path;
        return "file://" + clean.split("/").map(s => encodeURIComponent(s)).join("/");
    }

    onSpatialPointerXChanged: if (root.spatialDisplayActive) canvas.update()
    onSpatialPointerYChanged: if (root.spatialDisplayActive) canvas.update()

    readonly property bool active: wallpaperPath !== ""

    // Reveal curtain, driven by DepthDaemon. Held false until the whole
    // composite is ready, then flipped true exactly once. While false the
    // canvas is fully transparent so DMS's own backdrop shows through; the
    // single fade-in that lifts it never exposes a half-built frame.
    property bool revealed: false

    // Fired the first time the wallpaper image finishes decoding, so the
    // daemon can include "image actually painted" in its reveal gate (a ready
    // mask is not enough — the wallpaper behind it still has to have loaded).
    signal backdropReady()

    screen: root.targetScreen
    visible: root.active
    color: "transparent"
    implicitWidth: root.targetScreen ? root.targetScreen.width : 0
    implicitHeight: root.targetScreen ? root.targetScreen.height : 0

    WlrLayershell.namespace: "depthscape:wallpaper"
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
    // widgets above it and the windows beyond them keep receiving input
    // normally.
    mask: Region {}

    // Geometry must come from the OUTPUT, never from this window's own width
    // and height: a PanelWindow that has not been mapped yet reports 0x0,
    // which would collapse the canvas and keep the image from ever loading.
    readonly property real screenWidth: targetScreen ? targetScreen.width : 0
    readonly property real screenHeight: targetScreen ? targetScreen.height : 0
    readonly property real dpr: (targetScreen && targetScreen.devicePixelRatio)
        ? targetScreen.devicePixelRatio : 1

    readonly property bool spatialReady: root.spatialEnabled && root.spatialAssetsReady
        && root.spatialBackgroundPath !== "" && root.spatialForegroundPath !== ""
        && root.spatialDepthPath !== "" && root.spatialMattePath !== ""
        && root.spatialInfluencePath !== ""
    readonly property bool spatialSceneReady: spatialScene.sceneReady
    readonly property bool spatialNativeReady: spatialScene.nativeReady
    readonly property int spatialNativeStatus: spatialScene.nativeStatus
    readonly property alias canvasItem: canvas
    readonly property alias spatialSceneItem: spatialScene
    readonly property real spatialCameraPointerX: spatialScene.nativePointerX
    readonly property real spatialCameraPointerY: spatialScene.nativePointerY
    readonly property real spatialCameraMotionScale: spatialScene.nativeMotionScale
    readonly property real effectiveOutputAspect: root.screenWidth / Math.max(1, root.screenHeight)
    readonly property real effectiveSourceAspect: (root.imageWidth > 0 && root.imageHeight > 0)
        ? (root.imageWidth / root.imageHeight)
        : root.effectiveOutputAspect
    readonly property real canvasTravel: root.parallaxEnabled ? Math.max(0, root.maxTravel) : 0
    readonly property real marginX: root.canvasTravel > 0
        ? Math.max(0, root.screenWidth) * (root.canvasTravel + 0.001) : 0
    readonly property real marginY: root.canvasTravel > 0
        ? Math.max(0, root.screenHeight) * (root.canvasTravel + 0.001) : 0
    readonly property real canvasWidth: root.screenWidth + 2 * root.marginX
    readonly property real canvasHeight: root.screenHeight + 2 * root.marginY

    onSpatialReadyChanged: {
        if (!spatialReady) {
            spatialLayer.x = 0;
            spatialLayer.y = 0;
        }
    }

    property bool initialized: false

    // A flat colour behind the image, exactly as DMS's own wallpaper does. Two
    // things depend on it: while the image is still decoding, `transparent` would
    // let whatever is below show through as a full-screen flash on every
    // regeneration, and the image is scaled with `PreserveAspectCrop`, so on a
    // wallpaper whose aspect ratio differs from the output there is nothing to
    // crop and the thumbnail is letterboxed.
    Rectangle {
        anchors.fill: parent
        color: SettingsData.effectiveWallpaperBackgroundColor
        visible: opacity > 0
    }

    // The oversized canvas that carries the parallax animation. Both the
    // wallpaper Image and the overview-blur Loader below are its children and
    // just anchor to it, so nothing needs a main-thread binding to read
    // `backdrop.x` / `backdrop.y` — that would pin the whole animation off
    // the render thread (see the `THE ANIMATION RUNS ON THE RENDER THREAD`
    // note under `backdrop` in git history). The animation lives entirely on
    // this wrapper's `x`/`y`.
    Item {
        id: canvas

        x: -root.marginX + root.offsetX
        // Top-anchored vertically: on the topmost workspace (steps = 0, offsetY = 0),
        // y is 0 so the wallpaper top aligns with the top of the screen. As the
        // user navigates downward through workspaces, offsetY becomes negative and
        // the canvas slides upward, revealing lower content. Math.min(0, ...)
        // guards against any positive overshoot, guaranteeing zero black gap at the top.
        y: Math.min(0, root.offsetY)
        width: root.canvasWidth
        height: root.canvasHeight

        // The curtain lives here, on the animated wrapper, so it does not
        // disturb the WlrLayershell mapping or the flat background Rectangle
        // below (which keeps covering the backdrop while we are transparent).
        // Opacity 0 composites the whole subtree to nothing, so an unready
        // Depthscape is simply invisible and DMS's wallpaper is what you see.
        opacity: root.revealed ? 1.0 : 0.0
        Behavior on opacity {
            enabled: root.initialized
            NumberAnimation {
                duration: 350
                easing.type: Easing.OutCubic
            }
        }

        // One per axis, so a vertical and a horizontal navigation at the same
        // time ease independently instead of fighting over a single animation.
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

        Item {
            id: spatialLayer

            x: 0
            y: 0
            width: parent.width
            height: parent.height

            Image {
                id: backdrop

                anchors.fill: parent

                source: root.encodeFileUrl(root.wallpaperPath)
                fillMode: Image.PreserveAspectCrop

            // Decode at exactly the canvas size in DEVICE pixels. This depends
            // only on the canvas size, not on the offset, so the image is
            // never re-decoded while you switch workspaces.
                sourceSize: Qt.size(
                    Math.max(1, Math.round(root.canvasWidth * root.dpr)),
                    Math.max(1, Math.round(root.canvasHeight * root.dpr)))
                cache: true
                asynchronous: true
                retainWhileLoading: true
                smooth: true

                property bool hasLoaded: false
                onStatusChanged: {
                    if (status === Image.Ready) {
                        hasLoaded = true;
                        root.backdropReady();
                    }
                }
                opacity: hasLoaded ? 1.0 : 0.0
                Behavior on opacity {
                    NumberAnimation { duration: 150 }
                }
            }

            DepthSpatialScene {
                id: spatialScene
                anchors.fill: parent
                visible: root.spatialReady || opacity > 0.002
                opacity: root.spatialDisplayActive ? 1.0 : (root.spatialReady ? 0.001 : 0.0)
                Behavior on opacity {
                    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                }
                surfaceVisible: root.visible
                spatialEnabled: root.spatialReady
                sceneLayer: "background"
                sourcePath: root.wallpaperPath
                originalPath: root.wallpaperPath
                backgroundPath: root.spatialBackgroundPath
                depthPath: root.spatialDepthPath
                mattePath: root.spatialMattePath
                influencePath: root.spatialInfluencePath
                pointerX: root.spatialPointerX
                pointerY: root.spatialPointerY
                spatialTravel: root.spatialTravel
                outputAspect: root.effectiveOutputAspect
                sourceAspect: root.effectiveSourceAspect
            }

        // Overview blur. `anchors.fill: parent` inside the animated canvas
        // means the Loader tracks the parallax offset without a main-thread
        // binding on `backdrop.x`, and it draws last among canvas's children
        // so `MultiEffect` occludes the unblurred wallpaper it is blurring.
        Loader {
            anchors.fill: parent
            active: root.overviewBlurActive
            sourceComponent: MultiEffect {
                anchors.fill: parent
                source: root.spatialDisplayActive ? spatialScene : backdrop
                blurEnabled: true
                blur: 0.8
                blurMax: 75
                autoPaddingEnabled: false
            }
        }
        }
    }

    // Mirror of DMS's `overviewBlurActive` in
    // `Modules/WallpaperBackground.qml` line 136, and the `MultiEffect`
    // parameters above match its `overviewBlurLoader` (line 1108-1115)
    // verbatim: `blurEnabled: true`, `blur: 0.8`, `blurMax: 75`,
    // `autoPaddingEnabled: false`. The backdrop therefore reads identically
    // whether Depthscape or DMS is drawing it. When the trigger is false the
    // Loader holds no item at all, so the outside-overview cost is one
    // boolean read per frame.
    readonly property bool overviewBlurActive:
        CompositorService.isNiri
        && SettingsData.blurWallpaperOnOverview
        && NiriService.inOverview
        && root.wallpaperPath !== ""

    Component.onCompleted: {
        initialized = true;
        if (backdrop.status === Image.Ready) {
            backdrop.hasLoaded = true;
            root.backdropReady();
        }
    }
}
