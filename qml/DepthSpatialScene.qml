import QtQuick
import "DepthSpatialPointer.js" as SpatialPointer

// One registered spatial scene. The optional Quick3D renderer is preferred;
// the ShaderEffect remains active until it loads successfully, then acts as a
// useful fallback on systems without the native Quick3D module.
Item {
    id: root

    property string sceneLayer: "background" // background | foreground
    property string sourcePath: ""
    property string originalPath: sourcePath
    property string backgroundPath: ""
    property string depthPath: ""
    property string mattePath: ""
    property string influencePath: ""
    // Tilt at full pointer deflection, shared by the native mesh and the
    // shader fallback so both frame the wallpaper identically.
    readonly property real tiltDegrees: 4
    readonly property real tiltGainLimit: 2.6
    readonly property bool landscape: root.outputAspect >= 1
    readonly property real horizontalTiltGain: root.landscape
        ? 1 : Math.min(root.tiltGainLimit, 1 / Math.max(0.1, root.outputAspect))
    readonly property real verticalTiltGain: root.landscape
        ? Math.min(root.tiltGainLimit, root.outputAspect) : 1
    readonly property real motionScale: Math.max(0, root.spatialTravel / 0.1)
    readonly property real maxYawRadians: root.tiltDegrees * root.horizontalTiltGain
        * root.motionScale * Math.PI / 180
    readonly property real maxPitchRadians: root.tiltDegrees * root.verticalTiltGain
        * root.motionScale * Math.PI / 180

    /// Enlargement needed so the orbit never reveals the image edge:
    /// `cos(theta) + sin(theta)/tan(halfFov)` on the axis with the larger need.
    readonly property real imageZoom: {
        const halfV = Math.PI * 42 / 360;
        const halfH = Math.atan(Math.tan(halfV) * Math.max(0.1, root.outputAspect));
        const coverV = Math.cos(root.maxPitchRadians)
            + Math.sin(root.maxPitchRadians) / Math.tan(halfV);
        const coverH = Math.cos(root.maxYawRadians)
            + Math.sin(root.maxYawRadians) / Math.tan(halfH);
        return Math.max(1.0, coverV, coverH);
    }

    property real pointerX: 0
    property real pointerY: 0
    property real spatialTravel: 0.03
    property real outputAspect: width / Math.max(1, height)
    property real sourceAspect: outputAspect
    property bool spatialEnabled: true
    property bool surfaceVisible: true
    readonly property bool windowVisible: Window.window !== null && Window.window.visible
    readonly property bool hostVisible: surfaceVisible && windowVisible
    readonly property bool nativeReady: hostVisible && threeD.item && threeD.item.ready === true
    readonly property int nativeStatus: threeD.status
    readonly property bool assetPathsReady: sourcePath !== ""
        && backgroundPath !== "" && depthPath !== "" && mattePath !== ""
        && influencePath !== "" && (!foreground || originalPath !== "")
    readonly property bool fallbackActive: spatialEnabled && assetPathsReady
        && (threeD.status === Loader.Error || fallbackTimedOut)
    readonly property bool fallbackReady: fallbackActive
        && sourceTexture.status === Image.Ready
        && depthTexture.status === Image.Ready
        && (!foreground
            || (originalTexture.status === Image.Ready
                && matteTexture.status === Image.Ready
                && influenceTexture.status === Image.Ready
                && backgroundTexture.status === Image.Ready))
    readonly property bool sceneReady: spatialEnabled && assetPathsReady
        && ((nativeReady && !fallbackActive) || fallbackReady)
    readonly property real nativePointerX: threeD.item ? threeD.item.pointerX : 0
    readonly property real nativePointerY: threeD.item ? threeD.item.pointerY : 0
    readonly property real nativeMotionScale: threeD.item ? threeD.item.motionScale : 0
    readonly property real nativeImageZoom: threeD.item ? threeD.item.imageZoom : 0

    readonly property bool foreground: sceneLayer === "foreground"
    readonly property real cropX: sourceAspect > outputAspect ? outputAspect / sourceAspect : 1
    readonly property real cropY: sourceAspect > outputAspect ? 1 : sourceAspect / outputAspect
    property real easedPointerX: pointerCurve(pointerX)
    property real easedPointerY: pointerCurve(pointerY)
    property bool fallbackTimedOut: false
    property bool nativeLoaderAllowed: true

    function encodeFileUrl(path) {
        if (!path)
            return "";
        const clean = path.startsWith("file://") ? path.slice(7) : path;
        return "file://" + clean.split("/").map(s => encodeURIComponent(s)).join("/");
    }

    Timer {
        id: fallbackDeadline
        interval: 2500
        repeat: false
        running: root.spatialEnabled && root.assetPathsReady && root.hostVisible
            && !root.nativeReady && threeD.status !== Loader.Error && !root.fallbackTimedOut
        onTriggered: root.fallbackTimedOut = true
    }

    onHostVisibleChanged: {
        if (!hostVisible)
            fallbackTimedOut = false;
    }

    onNativeReadyChanged: {
        if (nativeReady)
            fallbackTimedOut = false;
    }
    onSpatialEnabledChanged: {
        nativeLoaderAllowed = true;
        if (!spatialEnabled)
            fallbackTimedOut = false;
    }
    onAssetPathsReadyChanged: {
        nativeLoaderAllowed = true;
        if (!assetPathsReady)
            fallbackTimedOut = false;
    }

    function pointerCurve(value) {
        return SpatialPointer.responsivePointer(value, 3);
    }

    function retryNativeSceneAfterAssetChange() {
        if (threeD.status === Loader.Error) {
            fallbackTimedOut = true;
            nativeLoaderAllowed = false;
            Qt.callLater(() => root.nativeLoaderAllowed = true);
            return;
        }
        fallbackTimedOut = false;
        if (spatialEnabled && assetPathsReady && !nativeReady)
            fallbackDeadline.restart();
    }

    Behavior on easedPointerX { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
    Behavior on easedPointerY { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

    // The shader path is loaded only when Quick3D is unavailable or its mesh
    // has not become valid within the fallback deadline.
    Item {
        id: shaderFallback
        anchors.fill: parent
        visible: root.fallbackActive

        // Keep these decoded QML images unloaded on the native Quick3D path.
        // Quick3D owns its own textures; decoding the same files here first
        // only delays the native scene and duplicates image-side memory.
        Image { id: sourceTexture; visible: false; source: root.fallbackActive && root.sourcePath ? root.encodeFileUrl(root.sourcePath) : ""; asynchronous: true }
        Image { id: originalTexture; visible: false; source: root.fallbackActive && root.originalPath ? root.encodeFileUrl(root.originalPath) : ""; asynchronous: true }
        Image { id: backgroundTexture; visible: false; source: root.fallbackActive && root.backgroundPath ? root.encodeFileUrl(root.backgroundPath) : ""; asynchronous: true }
        Image { id: depthTexture; visible: false; source: root.fallbackActive && root.depthPath ? root.encodeFileUrl(root.depthPath) : ""; asynchronous: true }
        Image { id: matteTexture; visible: false; source: root.fallbackActive && root.mattePath ? root.encodeFileUrl(root.mattePath) : ""; asynchronous: true }
        Image { id: influenceTexture; visible: false; source: root.fallbackActive && root.influencePath ? root.encodeFileUrl(root.influencePath) : ""; asynchronous: true }

        ShaderEffect {
            anchors.fill: parent
            property var source: root.foreground ? originalTexture : sourceTexture
            property var background: backgroundTexture
            property var matte: matteTexture
            property var influence: influenceTexture
            property var depthMap: depthTexture
            property vector2d pointer: Qt.vector2d(root.easedPointerX * root.spatialTravel / 0.1,
                root.easedPointerY * root.spatialTravel / 0.1)
            property vector2d cropScale: Qt.vector2d(root.cropX, root.cropY)
            property vector2d backgroundTexel: Qt.vector2d(
                1 / Math.max(1, backgroundTexture.sourceSize.width),
                1 / Math.max(1, backgroundTexture.sourceSize.height))
            property real foregroundOnly: root.foreground ? 1 : 0
            property real imageZoom: root.imageZoom
            fragmentShader: Qt.resolvedUrl("shaders/spatial_layered.frag.qsb")
            visible: sourceTexture.status === Image.Ready
                && (!root.foreground || originalTexture.status === Image.Ready)
                && depthTexture.status === Image.Ready
                && matteTexture.status === Image.Ready
                && influenceTexture.status === Image.Ready
                && backgroundTexture.status === Image.Ready
                && root.fallbackActive
        }

        ShaderEffect {
            anchors.fill: parent
            property var source: sourceTexture
            property var depthMap: depthTexture
            property vector2d pointer: Qt.vector2d(root.easedPointerX * root.spatialTravel / 0.1,
                root.easedPointerY * root.spatialTravel / 0.1)
            property vector2d cropScale: Qt.vector2d(root.cropX, root.cropY)
            fragmentShader: Qt.resolvedUrl("shaders/spatial_depth.frag.qsb")
            visible: sourceTexture.status === Image.Ready
                && depthTexture.status === Image.Ready
                && root.fallbackActive
                && !root.foreground
                && (matteTexture.status !== Image.Ready
                    || influenceTexture.status !== Image.Ready
                    || backgroundTexture.status !== Image.Ready)
        }
    }

    Loader {
        id: threeD
        anchors.fill: parent
        active: root.spatialEnabled && root.assetPathsReady && root.nativeLoaderAllowed && root.hostVisible
        source: Qt.resolvedUrl("DepthWallpaper3D.qml")
        onStatusChanged: {
            if (status === Loader.Error)
                root.fallbackTimedOut = true;
        }
        onLoaded: {
            if (item && !item.ready)
                fallbackDeadline.restart();
            if (item) {
                item.sceneLayer = root.sceneLayer;
                item.sourcePath = root.sourcePath;
                item.originalPath = root.originalPath;
                item.backgroundPath = root.backgroundPath;
                item.depthPath = root.depthPath;
                item.mattePath = root.mattePath;
                item.outputAspect = root.outputAspect;
                item.sourceAspect = root.sourceAspect;
                item.pointerX = root.easedPointerX;
                item.pointerY = root.easedPointerY;
                item.motionScale = root.motionScale;
                item.imageZoom = root.imageZoom;
                if (item.ready)
                    root.fallbackTimedOut = false;
            }
        }
    }

    onSceneLayerChanged: if (threeD.item) threeD.item.sceneLayer = sceneLayer
    onSourcePathChanged: {
        retryNativeSceneAfterAssetChange();
        if (threeD.item) threeD.item.sourcePath = sourcePath;
    }
    onOriginalPathChanged: {
        retryNativeSceneAfterAssetChange();
        if (threeD.item) threeD.item.originalPath = originalPath;
    }
    onBackgroundPathChanged: {
        retryNativeSceneAfterAssetChange();
        if (threeD.item) threeD.item.backgroundPath = backgroundPath;
    }
    onDepthPathChanged: {
        retryNativeSceneAfterAssetChange();
        if (threeD.item) threeD.item.depthPath = depthPath;
    }
    onMattePathChanged: {
        retryNativeSceneAfterAssetChange();
        if (threeD.item) threeD.item.mattePath = mattePath;
    }
    onEasedPointerXChanged: {
        if (threeD.item)
            threeD.item.pointerX = easedPointerX;
        if (Window.window)
            Window.window.update();
    }
    onEasedPointerYChanged: {
        if (threeD.item)
            threeD.item.pointerY = easedPointerY;
        if (Window.window)
            Window.window.update();
    }
    onSpatialTravelChanged: if (threeD.item) threeD.item.motionScale = motionScale
    onOutputAspectChanged: if (threeD.item) threeD.item.outputAspect = outputAspect
    onSourceAspectChanged: if (threeD.item) threeD.item.sourceAspect = sourceAspect
}
