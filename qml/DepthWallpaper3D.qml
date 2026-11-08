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
    readonly property real yawRadians: pointerX * 4 * motionScale * Math.PI / 180
    readonly property real pitchRadians: -pointerY * 3 * motionScale * Math.PI / 180
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
                    1.16 * 2 * geometry.backgroundDistance * Math.tan(Math.PI * 42 / 360) * root.outputAspect / 100,
                    1.16 * 2 * geometry.backgroundDistance * Math.tan(Math.PI * 42 / 360) / 100, 1)
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
                    imageZoom: 1.16
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
