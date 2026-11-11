import QtQuick
import QtQuick3D
import "native/Depthscape/Spatial3D" as Spatial3D

Item {
    id: root
    property string sceneLayer: "background"
    property string sourcePath: ""
    property string originalPath: sourcePath
    property string backgroundPath: ""
    property string depthPath: ""
    property string mattePath: ""
    property real pointerX: 0
    property real pointerY: 0
    property real motionScale: 1
    property real outputAspect: width / Math.max(1, height)
    property real sourceAspect: outputAspect
    readonly property bool ready: geometry.valid
    // Pointer tilt. The camera turns by these angles at full pointer deflection.
    //
    // The vertical field of view is fixed at 42°, so near the centre both axes
    // move the same *fraction* of the frame per degree; pixels therefore scale
    // with the axis length. To make a full sweep move the scene the same number
    // of pixels horizontally and vertically, the long axis gets the reference
    // 4° and the short axis gets 4° × (long / short).
    //
    //   landscape        yaw 4.0°              pitch 4.0° × aspect
    //     32:9 (3.56)    4.0                   10.4  (gain clamped at 2.6)
    //     21:9 (2.33)    4.0                    9.3
    //     16:9 (1.78)    4.0                    7.1
    //     16:10 (1.60)   4.0                    6.4
    //     3:2  (1.50)    4.0                    6.0
    //     4:3  (1.33)    4.0                    5.3
    //     1:1  (1.00)    4.0                    4.0
    //   portrait         yaw 4.0° / aspect      pitch 4.0°
    //     3:4  (0.75)    5.3                    4.0
    //     9:16 (0.56)    7.1                    4.0
    //     9:21 (0.43)    9.3                    4.0
    readonly property real tiltDegrees: 4
    readonly property real tiltGainLimit: 2.6
    readonly property bool landscape: root.outputAspect >= 1
    readonly property real horizontalTiltGain: root.landscape
        ? 1 : Math.min(root.tiltGainLimit, 1 / root.outputAspect)
    readonly property real verticalTiltGain: root.landscape
        ? Math.min(root.tiltGainLimit, root.outputAspect) : 1
    readonly property real yawRadians: pointerX * tiltDegrees * horizontalTiltGain
        * motionScale * Math.PI / 180
    readonly property real pitchRadians: -pointerY * tiltDegrees * verticalTiltGain
        * motionScale * Math.PI / 180
    /// Enlargement so the orbit never reveals the image edge. Owned by
    /// DepthSpatialScene so the shader fallback frames the image identically.
    property real imageZoom: 1.0

    readonly property real focusDistance: geometry.focusDistance
    readonly property real focusHalfHeight: focusDistance * Math.tan(Math.PI * 42 / 360)

    function encodeFileUrl(path) {
        if (!path)
            return "";
        const clean = path.startsWith("file://") ? path.slice(7) : path;
        return "file://" + clean.split("/").map(s => encodeURIComponent(s)).join("/");
    }

    function requestRender() {
        view3d.update();
        if (Window.window)
            Window.window.update();
    }

    onPointerXChanged: requestRender()
    onPointerYChanged: requestRender()
    onMotionScaleChanged: requestRender()
    onOutputAspectChanged: requestRender()
    onSourceAspectChanged: requestRender()
    onReadyChanged: if (ready) requestRender()

    View3D {
        id: view3d
        anchors.fill: parent
        renderMode: View3D.Offscreen
        environment: SceneEnvironment {
            backgroundMode: SceneEnvironment.Transparent
            antialiasingMode: SceneEnvironment.MSAA
            antialiasingQuality: SceneEnvironment.Medium
        }
        camera: camera
        Node {
            id: sceneRoot
            Node { id: focusTarget; position: Qt.vector3d(0, 0, -root.focusDistance) }
            PerspectiveCamera {
                id: camera
                clipNear: 0.01
                clipFar: 100
                fieldOfView: 42
                lookAtNode: focusTarget
                position: Qt.vector3d(
                    root.focusDistance * Math.sin(root.yawRadians) * Math.cos(root.pitchRadians),
                    root.focusDistance * Math.sin(root.pitchRadians),
                    -root.focusDistance + root.focusDistance * Math.cos(root.yawRadians) * Math.cos(root.pitchRadians))
            }

            Model {
                visible: root.sceneLayer === "background" && geometry.valid
                position: Qt.vector3d(0, 0, -geometry.backgroundDistance)
                source: "#Rectangle"
                scale: Qt.vector3d(
                    root.imageZoom * 2 * geometry.backgroundDistance * Math.tan(Math.PI * 42 / 360) * root.outputAspect / 100,
                    root.imageZoom * 2 * geometry.backgroundDistance * Math.tan(Math.PI * 42 / 360) / 100, 1)
                materials: [backgroundMaterial]
            }

            Model {
                visible: geometry.valid
                position: root.sceneLayer === "foreground" ? Qt.vector3d(
                    -root.pointerX * root.motionScale * root.focusHalfHeight * root.outputAspect * 0.01,
                    root.pointerY * root.motionScale * root.focusHalfHeight * 0.01, 0) : Qt.vector3d(0, 0, 0)
                geometry: Spatial3D.DepthMeshGeometry {
                    id: geometry
                    depthPath: root.encodeFileUrl(root.depthPath)
                    mattePath: root.encodeFileUrl(root.mattePath)
                    outputAspect: root.outputAspect
                    sourceAspect: root.sourceAspect
                    imageZoom: root.imageZoom
                    foreground: root.sceneLayer === "foreground"
                }
                materials: [root.sceneLayer === "foreground" ? subjectMaterial : backgroundMaterial]
            }
        }
    }

    CustomMaterial {
        id: backgroundMaterial
        shadingMode: CustomMaterial.Unshaded
        cullMode: Material.NoCulling
        vertexShader: Qt.resolvedUrl("shaders/mesh_background.vert")
        fragmentShader: Qt.resolvedUrl("shaders/mesh_background.frag")
        property TextureInput backgroundTexture: TextureInput {
            texture: Texture {
                source: root.encodeFileUrl(root.backgroundPath)
                minFilter: Texture.Linear
                magFilter: Texture.Linear
                tilingModeHorizontal: Texture.ClampToEdge
                tilingModeVertical: Texture.ClampToEdge
            }
        }
    }

    CustomMaterial {
        id: subjectMaterial
        shadingMode: CustomMaterial.Unshaded
        cullMode: Material.NoCulling
        depthDrawMode: Material.NeverDepthDraw
        sourceBlend: CustomMaterial.One
        destinationBlend: CustomMaterial.OneMinusSrcAlpha
        vertexShader: Qt.resolvedUrl("shaders/mesh_subject.vert")
        fragmentShader: Qt.resolvedUrl("shaders/mesh_subject.frag")
        property TextureInput sourceTexture: TextureInput {
            texture: Texture {
                // The caller supplies the already-downscaled photo, so this stays
                // a plain file texture: correct orientation, and no full-resolution
                // wallpaper upload behind the display's back.
                source: root.encodeFileUrl(root.originalPath)
                minFilter: Texture.Linear
                magFilter: Texture.Linear
                tilingModeHorizontal: Texture.ClampToEdge
                tilingModeVertical: Texture.ClampToEdge
            }
        }
        property TextureInput matteTexture: TextureInput {
            texture: Texture {
                source: root.encodeFileUrl(root.mattePath)
                minFilter: Texture.Linear
                magFilter: Texture.Linear
                tilingModeHorizontal: Texture.ClampToEdge
                tilingModeVertical: Texture.ClampToEdge
            }
        }
        property TextureInput backgroundTexture: TextureInput {
            texture: Texture {
                source: root.encodeFileUrl(root.backgroundPath)
                minFilter: Texture.Linear
                magFilter: Texture.Linear
                tilingModeHorizontal: Texture.ClampToEdge
                tilingModeVertical: Texture.ClampToEdge
            }
        }
    }
}
