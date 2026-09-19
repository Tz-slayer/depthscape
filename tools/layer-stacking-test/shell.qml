// Integration harness for the two layer-stacking mechanisms the plugin relies on.
//
// Run it with `qs -p tools/layer-stacking-test` (see setup.sh and README.md).
// Everything it creates lives on the `bottom` layer, exactly like the real
// plugin, so the measurement is taken on the real code path.
//
//   W1   magenta 400x400 @ logical (410,550)   mapped at t=0
//   FG   the real DepthDaemon                  mapped once the engine answers
//   W2   cyan    400x400 @ logical (1960,330)  mapped at t=LATE_WIDGET_MS
//
// W2 models what DMS does when its desktop-widget list changes: it rebuilds the
// widget surfaces (Modules/DesktopWidgetLayer.qml, `rebuildDebounce` 150ms then
// `rebuildApply` 32ms), which leaves them mapped *after* ours and therefore in
// front of ours, because layer surfaces stack by map order.
//
// The two probe points were chosen against the real mask entry for
// frieren-beyond-5120x2880-25925.jpg at threshold 0.30 / feather 0.08:
//
//   logical (2160, 530) -> image (4320,1060)   alpha 1.000   wallpaper rgb(11,21,50)
//   logical ( 610, 750) -> image (1220,1500)   alpha 0.000   wallpaper rgb(12,27,52)
//
// Note that only the *centre* of each panel is a single alpha value; the mask
// varies across the rest of the panel. probe.py therefore does not sample a
// point, it tests two competing hypotheses over the whole 400x400 rect.

import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    id: root

    // How long to wait before the "DMS rebuilt its widgets" event.
    readonly property int lateWidgetMs: 14000

    // ---- W1: an ordinary desktop widget, mapped first ----
    Variants {
        model: Quickshell.screens

        delegate: PanelWindow {
            required property var modelData

            screen: modelData
            anchors { left: true; top: true }
            WlrLayershell.margins { left: 410; top: 550 }
            implicitWidth: 400
            implicitHeight: 400
            color: "#ff00ff"

            WlrLayershell.namespace: "depthscape-test-widget-early"
            WlrLayershell.layer: WlrLayer.Bottom
            WlrLayershell.exclusiveZone: -1
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            mask: Region {}
        }
    }

    // ---- the real daemon, which maps the real foreground surfaces ----
    DepthDaemon {
        pluginId: "depthscape"
        pluginService: null
    }

    // ---- W2: a widget that appears later, i.e. DMS rebuilding its list ----
    Loader {
        id: lateWidgetLoader

        anchors.fill: parent
        active: false

        sourceComponent: Component {
            Variants {
                model: Quickshell.screens

                delegate: PanelWindow {
                    required property var modelData

                    screen: modelData
                    anchors { left: true; top: true }
                    WlrLayershell.margins { left: 1960; top: 330 }
                    implicitWidth: 400
                    implicitHeight: 400
                    color: "#00ffff"

                    WlrLayershell.namespace: "depthscape-test-widget-late"
                    WlrLayershell.layer: WlrLayer.Bottom
                    WlrLayershell.exclusiveZone: -1
                    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                    mask: Region {}
                }
            }
        }
    }

    Timer {
        interval: root.lateWidgetMs
        running: true
        onTriggered: {
            console.info("depthscape-test: mapping late widget");
            lateWidgetLoader.active = true;
        }
    }

    Component.onCompleted: console.info("depthscape-test: harness started")
}
