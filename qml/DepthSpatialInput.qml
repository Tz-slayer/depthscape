import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Services

// Input-only surface on the workspace background, separate from the shared
// backdrop. Windows remain above it; the last pointer position is retained
// when the pointer leaves for a window.
PanelWindow {
    id: root

    required property var targetScreen
    property bool trackingEnabled: false
    property real pointerX: 0
    property real pointerY: 0
    readonly property bool hovered: hover.hovered || contextMouse.containsMouse

    screen: targetScreen
    visible: trackingEnabled
    color: "transparent"
    implicitWidth: targetScreen ? targetScreen.width : 0
    implicitHeight: targetScreen ? targetScreen.height : 0
    WlrLayershell.namespace: "depthscape-spatial-input"
    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    anchors { top: true; bottom: true; left: true; right: true }

    onTrackingEnabledChanged: if (!trackingEnabled) {
        pointerX = 0;
        pointerY = 0;
    }

    function updateNormalizedPointer(px, py, areaWidth, areaHeight) {
        const w = areaWidth > 0 ? areaWidth : (root.targetScreen ? root.targetScreen.width : 1);
        const h = areaHeight > 0 ? areaHeight : (root.targetScreen ? root.targetScreen.height : 1);
        root.pointerX = Math.max(-1, Math.min(1, px / Math.max(1, w) * 2 - 1));
        root.pointerY = Math.max(-1, Math.min(1, py / Math.max(1, h) * 2 - 1));
    }

    Item {
        id: inputSurface
        anchors.fill: parent

        HoverHandler {
            id: hover
            onPointChanged: {
                root.updateNormalizedPointer(point.position.x, point.position.y, inputSurface.width, inputSurface.height);
            }
        }

        // The input surface is above DMS's desktop input surface, so forward the
        // existing desktop right-click action through the same DMS service.
        MouseArea {
            id: contextMouse
            anchors.fill: parent
            enabled: CompositorService.desktopContextMenuEnabled
            acceptedButtons: Qt.RightButton
            hoverEnabled: true
            onPositionChanged: mouse => {
                root.updateNormalizedPointer(mouse.x, mouse.y, width, height);
            }
            onClicked: mouse => {
                if (PopoutService.desktopContextMenu)
                    PopoutService.desktopContextMenu.open(root.targetScreen, mouse.x, mouse.y, false);
            }
        }
    }
}
