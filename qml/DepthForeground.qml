import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Services

// The foreground layer renders above DMS desktop widgets (on WlrLayer.Background)
// and below normal application windows.
//
// In standard depth mode, it masks the wallpaper with the depth mask (alpha > 0)
// so only the near-plane subject is drawn, occluding desktop widgets underneath.
// In spatial 3D mode, it can render the 3D depth mesh.
//
// DUAL-SLOT TRANSITION:
// Matches DMS's native wallpaper transition (SessionData.wallpaperTransition, 1000ms).
// Maintains an active slot (current) and an incoming slot (next), cross-fading them
// smoothly so widgets are never exposed and subjects never pop during wallpaper switches.
PanelWindow {
    id: root

    required property var targetScreen
    property string foregroundPath: ""
    property string wallpaperPath: ""
    property string maskPath: ""
    property var bbox: null
    property real imageWidth: 0
    property real imageHeight: 0
    property string backgroundPath: ""
    property string depthPath: ""
    property string mattePath: ""
    property string influencePath: ""
    property real pointerX: 0
    property real pointerY: 0
    property real spatialTravel: 0.03
    property real outputAspect: 16 / 9
    property real sourceAspect: 16 / 9
    property bool spatialEnabled: false
    property bool spatialAssetsReady: false
    property bool spatialDisplayActive: false
    property bool effectEnabled: true
    property bool revealed: false
    property real maxTravel: 0
    property real offsetX: 0
    property real offsetY: 0

    function encodeFileUrl(path) {
        if (!path)
            return "";
        const clean = path.startsWith("file://") ? path.slice(7) : path;
        return "file://" + clean.split("/").map(s => encodeURIComponent(s)).join("/");
    }

    onPointerXChanged: if (root.spatialDisplayActive) foregroundContent.update()
    onPointerYChanged: if (root.spatialDisplayActive) foregroundContent.update()

    signal foregroundReady()

    screen: root.targetScreen
    visible: (root.effectEnabled || root.spatialEnabled)
        && (root.foregroundPath !== "" || root.wallpaperPath !== "")
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

    mask: Region {}

    readonly property real screenWidth: targetScreen ? targetScreen.width : 0
    readonly property real screenHeight: targetScreen ? targetScreen.height : 0
    readonly property real dpr: (targetScreen && targetScreen.devicePixelRatio) ? targetScreen.devicePixelRatio : 1
    readonly property real marginX: root.maxTravel > 0 ? screenWidth * (root.maxTravel + 0.001) : 0
    readonly property real marginY: root.maxTravel > 0 ? screenHeight * (root.maxTravel + 0.001) : 0

    // --- Dual-slot transition state machine ---
    // Slot 1 (current)
    property string currentWp: ""
    property string currentMask: ""
    property var currentBbox: null
    property real currentImgW: 0
    property real currentImgH: 0

    // Slot 2 (incoming)
    property string incomingWp: ""
    property string incomingMask: ""
    property var incomingBbox: null
    property real incomingImgW: 0
    property real incomingImgH: 0

    // Transition progress: 0.0 = 100% current, 1.0 = 100% incoming
    property real transitionProgress: 0.0
    property bool isTransitioning: false

    readonly property int transitionDuration: (SessionData.wallpaperTransition === "none") ? 0 : 1000

    function updateTargets() {
        const wantedWp = root.wallpaperPath;
        const wantedMask = root.maskPath;
        const wantedBbox = root.bbox;
        const wantedW = root.imageWidth;
        const wantedH = root.imageHeight;

        // Initial setup: cold start
        if (currentWp === "" && incomingWp === "") {
            currentWp = wantedWp;
            currentMask = wantedMask;
            currentBbox = wantedBbox;
            currentImgW = wantedW;
            currentImgH = wantedH;
            transitionProgress = 0.0;
            return;
        }

        // If target matches what is already showing in current and we're not transitioning, nothing to do
        if (!isTransitioning && currentWp === wantedWp && currentMask === wantedMask) {
            currentBbox = wantedBbox;
            currentImgW = wantedW;
            currentImgH = wantedH;
            return;
        }

        // If target matches what is already incoming
        if (isTransitioning && incomingWp === wantedWp && incomingMask === wantedMask) {
            incomingBbox = wantedBbox;
            incomingImgW = wantedW;
            incomingImgH = wantedH;
            return;
        }

        // If a transition was in progress and user changed wallpaper again, commit current progress
        if (isTransitioning) {
            transitionAnim.stop();
            if (transitionProgress >= 0.5 && incomingMask !== "") {
                currentWp = incomingWp;
                currentMask = incomingMask;
                currentBbox = incomingBbox;
                currentImgW = incomingImgW;
                currentImgH = incomingImgH;
            }
            transitionProgress = 0.0;
            isTransitioning = false;
        }

        // Staging incoming slot
        incomingWp = wantedWp;
        incomingMask = wantedMask;
        incomingBbox = wantedBbox;
        incomingImgW = wantedW;
        incomingImgH = wantedH;

        // If no mask is available yet for incoming, fade out current smoothly (synchronized with background transition)
        if (wantedMask === "") {
            isTransitioning = true;
            transitionProgress = 0.0;
            transitionAnim.restart();
            return;
        }

        // Wait until incoming images are Ready before cross-fading
        checkIncomingReady();
    }

    function checkIncomingReady() {
        if (!isTransitioning && incomingWp !== "" && incomingMask !== "") {
            if (incomingWpSource.status === Image.Ready && incomingMaskSource.status === Image.Ready) {
                startTransition();
            }
        }
    }

    function startTransition() {
        if (root.transitionDuration === 0) {
            finishTransition();
            return;
        }
        isTransitioning = true;
        transitionProgress = 0.0;
        transitionAnim.restart();
    }

    function finishTransition() {
        transitionAnim.stop();
        if (incomingMask !== "") {
            currentWp = incomingWp;
            currentMask = incomingMask;
            currentBbox = incomingBbox;
            currentImgW = incomingImgW;
            currentImgH = incomingImgH;
        } else {
            // Faded out to empty
            currentWp = incomingWp;
            currentMask = "";
            currentBbox = null;
        }
        incomingWp = "";
        incomingMask = "";
        incomingBbox = null;
        transitionProgress = 0.0;
        isTransitioning = false;
    }

    NumberAnimation {
        id: transitionAnim
        target: root
        property: "transitionProgress"
        from: 0.0
        to: 1.0
        duration: root.transitionDuration
        easing.type: Easing.InOutCubic
        onFinished: root.finishTransition()
    }

    onWallpaperPathChanged: updateTargets()
    onMaskPathChanged: updateTargets()
    onBboxChanged: updateTargets()

    function checkReady() {
        if (root.spatialSceneReady) {
            root.foregroundReady();
            return;
        }
        if (!root.dedicatedCutoutActive) {
            if (currentWpSource.status === Image.Ready && currentMaskSource.status === Image.Ready) {
                root.foregroundReady();
            }
        } else if (foregroundImg.status === Image.Ready) {
            root.foregroundReady();
        }
    }

    onSpatialSceneReadyChanged: {
        if (spatialSceneReady)
            root.foregroundReady();
    }

    Component.onCompleted: {
        updateTargets();
        root.checkReady();
    }

    Item {
        anchors.fill: parent

        Item {
            x: -root.marginX + root.offsetX
            y: Math.min(0, root.offsetY)
            width: root.screenWidth + 2 * root.marginX
            height: root.screenHeight + 2 * root.marginY
            opacity: root.revealed ? 1 : 0
            Behavior on opacity {
                NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
            }

            Item {
                id: foregroundContent
                width: parent.width
                height: parent.height

                layer.enabled: root.overviewBlurActive && root.revealed
                layer.effect: MultiEffect {
                    blurEnabled: true
                    blur: 0.8
                    blurMax: 75
                    autoPaddingEnabled: false
                }

                // Standard depth mode: Dual-slot cross-fading foreground
                Item {
                    id: maskedStandardForeground
                    anchors.fill: parent
                    visible: root.effectEnabled && !root.dedicatedCutoutActive && spatialScene.opacity < 0.995
                    opacity: Math.max(0.0, 1.0 - spatialScene.opacity)

                    // --- SLOT 1 (Current / Outgoing) ---
                    Item {
                        id: currentSlot
                        anchors.fill: parent
                        visible: root.currentMask !== ""
                        opacity: {
                            if (currentWpSource.status !== Image.Ready || currentMaskSource.status !== Image.Ready)
                                return 0.0;
                            return root.isTransitioning ? (1.0 - root.transitionProgress) : 1.0;
                        }

                        readonly property real srcAspect: currentWpSource.implicitWidth / Math.max(1, currentWpSource.implicitHeight)
                        readonly property real outAspect: width / Math.max(1, height)
                        readonly property real cropX: srcAspect > outAspect ? outAspect / srcAspect : 1
                        readonly property real cropY: srcAspect > outAspect ? 1 : srcAspect / outAspect

                        readonly property vector4d subRect: {
                            const w = root.currentImgW > 0 ? root.currentImgW : currentWpSource.implicitWidth;
                            const h = root.currentImgH > 0 ? root.currentImgH : currentWpSource.implicitHeight;
                            if (!root.currentBbox || root.currentBbox.length < 4 || w <= 0 || h <= 0)
                                return Qt.vector4d(0, 0, 1, 1);
                            const u0 = Math.max(0, (root.currentBbox[0] - 2) / w);
                            const v0 = Math.max(0, (root.currentBbox[1] - 2) / h);
                            const u1 = Math.min(1, (root.currentBbox[2] + 3) / w);
                            const v1 = Math.min(1, (root.currentBbox[3] + 3) / h);
                            const px0 = Math.max(0, Math.min(1, 0.5 + (u0 - 0.5) / currentSlot.cropX));
                            const py0 = Math.max(0, Math.min(1, 0.5 + (v0 - 0.5) / currentSlot.cropY));
                            const px1 = Math.max(0, Math.min(1, 0.5 + (u1 - 0.5) / currentSlot.cropX));
                            const py1 = Math.max(0, Math.min(1, 0.5 + (v1 - 0.5) / currentSlot.cropY));
                            if (px1 <= px0 || py1 <= py0)
                                return Qt.vector4d(0, 0, 0, 0);
                            return Qt.vector4d(px0, py0, px1 - px0, py1 - py0);
                        }

                        Image {
                            id: currentWpSource
                            anchors.fill: parent
                            source: root.encodeFileUrl(root.currentWp)
                            fillMode: Image.PreserveAspectCrop
                            sourceSize: Qt.size(
                                Math.max(1, Math.round(parent.width * root.dpr)),
                                Math.max(1, Math.round(parent.height * root.dpr)))
                            cache: true
                            asynchronous: true
                            smooth: true
                            visible: false
                            onStatusChanged: {
                                if (status === Image.Ready)
                                    root.checkReady();
                            }
                        }

                        Image {
                            id: currentMaskSource
                            anchors.fill: parent
                            source: root.encodeFileUrl(root.currentMask)
                            fillMode: Image.PreserveAspectCrop
                            sourceSize: Qt.size(
                                Math.max(1, Math.round(parent.width * root.dpr)),
                                Math.max(1, Math.round(parent.height * root.dpr)))
                            cache: true
                            asynchronous: true
                            smooth: true
                            visible: false
                            onStatusChanged: {
                                if (status === Image.Ready)
                                    root.checkReady();
                            }
                        }

                        ShaderEffect {
                            x: currentSlot.subRect.x * parent.width
                            y: currentSlot.subRect.y * parent.height
                            width: currentSlot.subRect.z * parent.width
                            height: currentSlot.subRect.w * parent.height
                            visible: width > 0 && height > 0
                            property var source: currentWpSource
                            property var maskSource: currentMaskSource
                            property vector2d cropScale: Qt.vector2d(currentSlot.cropX, currentSlot.cropY)
                            property vector4d subRect: currentSlot.subRect
                            fragmentShader: Qt.resolvedUrl("shaders/masked_foreground.frag.qsb")
                        }
                    }

                    // --- SLOT 2 (Incoming / Next) ---
                    Item {
                        id: incomingSlot
                        anchors.fill: parent
                        visible: root.isTransitioning && root.incomingMask !== ""
                        opacity: {
                            if (incomingWpSource.status !== Image.Ready || incomingMaskSource.status !== Image.Ready)
                                return 0.0;
                            return root.transitionProgress;
                        }

                        readonly property real srcAspect: incomingWpSource.implicitWidth / Math.max(1, incomingWpSource.implicitHeight)
                        readonly property real outAspect: width / Math.max(1, height)
                        readonly property real cropX: srcAspect > outAspect ? outAspect / srcAspect : 1
                        readonly property real cropY: srcAspect > outAspect ? 1 : srcAspect / outAspect

                        readonly property vector4d subRect: {
                            const w = root.incomingImgW > 0 ? root.incomingImgW : incomingWpSource.implicitWidth;
                            const h = root.incomingImgH > 0 ? root.incomingImgH : incomingWpSource.implicitHeight;
                            if (!root.incomingBbox || root.incomingBbox.length < 4 || w <= 0 || h <= 0)
                                return Qt.vector4d(0, 0, 1, 1);
                            const u0 = Math.max(0, (root.incomingBbox[0] - 2) / w);
                            const v0 = Math.max(0, (root.incomingBbox[1] - 2) / h);
                            const u1 = Math.min(1, (root.incomingBbox[2] + 3) / w);
                            const v1 = Math.min(1, (root.incomingBbox[3] + 3) / h);
                            const px0 = Math.max(0, Math.min(1, 0.5 + (u0 - 0.5) / incomingSlot.cropX));
                            const py0 = Math.max(0, Math.min(1, 0.5 + (v0 - 0.5) / incomingSlot.cropY));
                            const px1 = Math.max(0, Math.min(1, 0.5 + (u1 - 0.5) / incomingSlot.cropX));
                            const py1 = Math.max(0, Math.min(1, 0.5 + (v1 - 0.5) / incomingSlot.cropY));
                            if (px1 <= px0 || py1 <= py0)
                                return Qt.vector4d(0, 0, 0, 0);
                            return Qt.vector4d(px0, py0, px1 - px0, py1 - py0);
                        }

                        Image {
                            id: incomingWpSource
                            anchors.fill: parent
                            source: root.encodeFileUrl(root.incomingWp)
                            fillMode: Image.PreserveAspectCrop
                            sourceSize: Qt.size(
                                Math.max(1, Math.round(parent.width * root.dpr)),
                                Math.max(1, Math.round(parent.height * root.dpr)))
                            cache: true
                            asynchronous: true
                            smooth: true
                            visible: false
                            onStatusChanged: {
                                if (status === Image.Ready)
                                    root.checkIncomingReady();
                            }
                        }

                        Image {
                            id: incomingMaskSource
                            anchors.fill: parent
                            source: root.encodeFileUrl(root.incomingMask)
                            fillMode: Image.PreserveAspectCrop
                            sourceSize: Qt.size(
                                Math.max(1, Math.round(parent.width * root.dpr)),
                                Math.max(1, Math.round(parent.height * root.dpr)))
                            cache: true
                            asynchronous: true
                            smooth: true
                            visible: false
                            onStatusChanged: {
                                if (status === Image.Ready)
                                    root.checkIncomingReady();
                            }
                        }

                        ShaderEffect {
                            x: incomingSlot.subRect.x * parent.width
                            y: incomingSlot.subRect.y * parent.height
                            width: incomingSlot.subRect.z * parent.width
                            height: incomingSlot.subRect.w * parent.height
                            visible: width > 0 && height > 0
                            property var source: incomingWpSource
                            property var maskSource: incomingMaskSource
                            property vector2d cropScale: Qt.vector2d(incomingSlot.cropX, incomingSlot.cropY)
                            property vector4d subRect: incomingSlot.subRect
                            fragmentShader: Qt.resolvedUrl("shaders/masked_foreground.frag.qsb")
                        }
                    }
                }

                // Dedicated cutout image mode (if an explicit non-spatial foreground asset is provided)
                Image {
                    id: foregroundImg
                    anchors.fill: parent
                    visible: root.dedicatedCutoutActive && !root.spatialDisplayActive
                    source: root.dedicatedCutoutActive ? root.encodeFileUrl(root.foregroundPath) : ""
                    fillMode: Image.PreserveAspectCrop
                    sourceSize: Qt.size(Math.max(1, Math.round(parent.width)), Math.max(1, Math.round(parent.height)))
                    cache: true
                    asynchronous: true
                    retainWhileLoading: true
                    smooth: true
                    opacity: root.revealed && status === Image.Ready && !root.spatialDisplayActive ? 1 : 0
                    onStatusChanged: {
                        if (status === Image.Ready)
                            root.foregroundReady();
                    }
                    Behavior on opacity {
                        NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }

                // Spatial 3D scene (Quick3D mesh)
                DepthSpatialScene {
                    id: spatialScene
                    anchors.fill: parent
                    visible: root.spatialBuildActive || opacity > 0.002
                    opacity: root.spatialDisplayActive ? 1.0 : (root.spatialBuildActive ? 0.001 : 0.0)
                    Behavior on opacity {
                        NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                    }
                    surfaceVisible: root.visible
                    sceneLayer: "foreground"
                    sourcePath: root.foregroundPath !== "" ? root.foregroundPath : root.wallpaperPath
                    originalPath: root.wallpaperPath
                    backgroundPath: root.backgroundPath
                    depthPath: root.depthPath
                    mattePath: root.mattePath
                    influencePath: root.influencePath
                    pointerX: root.pointerX
                    pointerY: root.pointerY
                    spatialTravel: root.spatialTravel
                    spatialEnabled: root.spatialBuildActive
                    outputAspect: root.effectiveOutputAspect
                    sourceAspect: root.effectiveSourceAspect
                }
            }
        }
    }

    readonly property bool dedicatedCutoutActive: !root.spatialEnabled && root.foregroundPath !== ""
    readonly property real effectiveOutputAspect: root.screenWidth > 0 && root.screenHeight > 0
        ? (root.screenWidth / root.screenHeight)
        : root.outputAspect
    readonly property real effectiveSourceAspect: (root.imageWidth > 0 && root.imageHeight > 0)
        ? (root.imageWidth / root.imageHeight)
        : ((currentWpSource.implicitWidth > 0 && currentWpSource.implicitHeight > 0)
            ? (currentWpSource.implicitWidth / currentWpSource.implicitHeight)
            : root.effectiveOutputAspect)
    readonly property bool spatialBuildActive: root.spatialEnabled && root.spatialAssetsReady
        && root.wallpaperPath !== "" && root.backgroundPath !== ""
        && root.depthPath !== "" && root.mattePath !== "" && root.influencePath !== ""
    readonly property bool spatialSceneReady: spatialScene.sceneReady
    readonly property bool spatialNativeReady: spatialScene.nativeReady
    readonly property int spatialNativeStatus: spatialScene.nativeStatus
    readonly property alias foregroundItem: foregroundContent
    readonly property alias spatialSceneItem: spatialScene
    readonly property real foregroundAspect: root.effectiveSourceAspect
    readonly property bool overviewBlurActive:
        CompositorService.isNiri
        && (SettingsData.blurWallpaperOnOverview ?? false)
        && NiriService.inOverview
        && root.visible
}
