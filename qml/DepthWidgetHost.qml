import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common

// Host for Depthscape's own desktop widgets.
//
// WHY NOT DMS DESKTOP WIDGETS
//
// DMS's desktop widgets are a good framework and the wrong tool here, for two
// reasons that are both structural rather than cosmetic:
//
//   1. They live on the `bottom` layer (DesktopPluginWrapper.qml, the default
//      branch of WlrLayershell.layer). Depthscape's three surfaces are on
//      `background`, the layer *below* `bottom`, so a DMS widget would always
//      draw over the subject. See DepthBackground.qml for why `background` plus
//      a `place-within-backdrop` rule is the arrangement that keeps the overview
//      from duplicating the wallpaper into every card.
//   2. They are instantiated per workspace card, so the same clock appears in
//      every workspace. A wallpaper is one image on one screen; it should not
//      be duplicated.
//
// So Depthscape hosts its own. The framework is deliberately small: a widget is
// an Item with `settings` and `editMode`, placed by coordinates, and the layer
// ordering comes from being mapped between the background and the foreground.
//
// STATE
//
// Layout lives in its own JSON file under the plugin's data directory rather
// than in DMS's plugin data. Two reasons:
//
//   * `savePluginData` emits `pluginDataChanged`, which DepthDaemon itself
//     listens to in order to invalidate masks. Writing layout through it would
//     make every drag rebuild every mask — and, because the daemon's own
//     bookkeeping writes plugin data too, risks a feedback loop.
//   * Layout is ours. Keeping it in our own directory means the schema can
//     change without negotiating with DMS's storage.
PanelWindow {
    id: root

    // Deliberately NOT called `screen` — see DepthBackground.qml.
    required property var targetScreen

    /// Absolute path to widgets.json, resolved by DepthDaemon.
    property string layoutPath: ""
    /// Whether widgets should be drawn at all (effect off ⇒ nothing to occlude).
    property bool widgetsEnabled: true

    /// Opacity of the whole surface, driven by DepthDaemon so that all three
    /// fade together while the overview is open.
    property real overviewOpacity: 1

    property var layout: []
    property bool loaded: false

    // screenName -> the widget host below, so positions can be read back.
    property var hosts: ({})

    readonly property bool active: root.widgetsEnabled && root.layout.length > 0

    screen: root.targetScreen
    visible: root.active
    color: "transparent"
    implicitWidth: root.targetScreen ? root.targetScreen.width : 0
    implicitHeight: root.targetScreen ? root.targetScreen.height : 0

    WlrLayershell.namespace: "depthscape:widgets"
    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
        top: true
        left: true
        right: true
        bottom: true
    }

    // Click-through. Widgets are drawn on the wallpaper, not interacted with;
    // the one exception is edit mode, which the settings page drives.
    mask: Region {}

    // ------------------------------------------------------------- overview fade

    // The only transform on the widgets is the overview fade, and it has to live
    // on a content item rather than on the window: `PanelWindow` is a Wayland
    // surface and has no `opacity` of its own.
    //
    // THE WIDGETS DO NOT MOVE WITH THE PARALLAX, and that is deliberate rather
    // than unfinished. They are drawn on the wallpaper — they are the thing the
    // subject stands in front of — so they are part of the frame the depth is
    // measured against. Sliding them would slide the reference itself, and the
    // subject would appear to move only because the clock moved under it. The
    // reference implementation leaves its widgets alone for the same reason.
    Item {
        id: fader

        anchors.fill: parent
        opacity: root.overviewOpacity

        // ------------------------------------------------------------------ loading

        FileView {
            id: layoutFile

            path: root.layoutPath
            blockLoading: false
            watchChanges: true
            printErrors: false

            onLoaded: root.applyLayout()
            onFileChanged: layoutFile.reload()
            onLoadFailed: error => {
                // A missing file is the normal first run, not an error worth
                // surfacing. An empty layout simply means no widgets.
                root.layout = [];
                root.loaded = true;
            }
        }

        // One loader per widget entry for this output. `Repeater` rather than
        // `Instantiator` because the delegates are visible items that need to be
        // laid out, and because the count is small (a handful of widgets).
        Repeater {
            model: root.targetScreen ? root.widgetsFor(root.targetScreen.name) : []

            delegate: Item {
                id: holder

                required property var modelData
                required property int index

                // Placement is in logical pixels from the top-left of the
                // output, matching the coordinate space the settings page
                // shows. Clamped so a layout made on a large monitor cannot push
                // a widget off a smaller one entirely.
                x: Math.max(0, Math.min((modelData.x ?? 0),
                    Math.max(0, root.width - width)))
                y: Math.max(0, Math.min((modelData.y ?? 0),
                    Math.max(0, root.height - height)))

                width: widgetItem ? widgetItem.implicitWidth : 0
                height: widgetItem ? widgetItem.implicitHeight : 0

                Loader {
                    id: widgetItem

                    anchors.fill: parent
                    asynchronous: false
                    source: root.sourceFor(holder.modelData.type)

                    onLoaded: {
                        if (!item)
                            return;
                        item.settings = holder.modelData.settings ?? {};
                        item.editMode = false;
                    }

                    onStatusChanged: {
                        if (status === Loader.Error)
                            console.warn("Depthscape: widget type not found: " + holder.modelData.type);
                    }
                }

                Component.onCompleted: {
                    const next = {};
                    for (const key in root.hosts)
                        next[key] = root.hosts[key];
                    next[holder.modelData.id ?? (holder.modelData.type + "_" + holder.index)] = holder;
                    root.hosts = next;
                }
            }
        }
    }

    // The overview fade is carried by `fader` above: `PanelWindow` is a Wayland
    // surface and has no `opacity` of its own.

    // ---------------------------------------------------------------- the host

    function applyLayout() {
        let parsed = null;
        try {
            parsed = JSON.parse(layoutFile.text());
        } catch (error) {
            parsed = null;
        }
        // Tolerate the two plausible shapes: a bare array, or an object with a
        // `widgets` key. Being liberal here costs nothing and saves a support
        // round-trip if the file is hand-edited.
        const rows = Array.isArray(parsed)
            ? parsed
            : (parsed && Array.isArray(parsed.widgets) ? parsed.widgets : []);
        layout = rows.filter(row => row && typeof row.type === "string");
        loaded = true;
    }

    function widgetsFor(screenName) {
        return layout.filter(row => {
            const target = row.screen;
            return !target || target === "" || target === screenName;
        });
    }

    // ---------------------------------------------------------------- the host

    /// Map a widget type from the layout file onto a QML component.
    ///
    /// A whitelist rather than a path from the JSON: the layout file lives in the
    /// user's data directory, and letting it name an arbitrary QML file to load
    /// would turn a data file into code execution.
    function sourceFor(type) {
        if (type === "clock")
            return Qt.resolvedUrl("DepthClockWidget.qml");
        return "";
    }

}
