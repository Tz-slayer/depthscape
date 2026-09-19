import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets

// Desktop status tile.
//
// Doubles as a live demonstration: this widget renders on the same layer-shell
// layer as the foreground surface (`bottom`), and the foreground is re-mapped
// after this widget is built, so the wallpaper's near scenery passes in front
// of this tile whenever the effect is active. See `docs/depthscape.md` §14.1.
Item {
    id: root

    property var pluginService: null
    property string pluginId: ""
    property bool editMode: false
    property real widgetWidth: 220
    property real widgetHeight: 160
    property real minWidth: 180
    property real minHeight: 120

    property var status: ({})

    readonly property var outputs: status.outputs ?? []
    readonly property bool busy: outputs.some(row => row.state === "processing" || row.state === "pending")

    // A desktop widget *instance* does not get the full PluginService. The
    // framework injects a reduced wrapper (`DesktopPluginWrapper.
    // instanceScopedPluginService`) that exposes only plugin data —
    // `loadPluginData` / `pluginDataChanged` — and drops the state API:
    // there is no `loadPluginState` and no `pluginStateChanged` on it. DMS's
    // own `PluginSettings.qml` guards for exactly that with
    // `if (pluginService && pluginService.loadPluginState)`.
    //
    // Since `desktopWidgetInstances` is the only way a desktop widget is ever
    // created, that wrapper is always what we get. So read the plugin's own
    // state file the same way PluginService reads it internally.
    readonly property string stateFilePath: pluginId === ""
        ? ""
        : Paths.strip(Paths.state) + "/plugins/" + pluginId + "_state.json"

    FileView {
        id: stateFile

        path: root.stateFilePath
        blockLoading: true
        watchChanges: true
        printErrors: false

        onLoaded: root.applyState()
        onFileChanged: stateFile.reload()
        onLoadFailed: error => {
            root.status = {};
        }
    }

    function applyState() {
        let parsed = null;
        try {
            parsed = JSON.parse(stateFile.text());
        } catch (error) {
            parsed = null;
        }
        status = parsed && parsed.status ? parsed.status : {};
    }

    function refresh() {
        if (stateFilePath !== "")
            stateFile.reload();
    }

    function stateColor(state) {
        if (state === "ready")
            return Theme.primary;
        if (state === "error")
            return Theme.error;
        if (state === "processing" || state === "pending")
            return Theme.primary;
        return Theme.surfaceVariantText;
    }

    function stateLabel(row) {
        if (row.state === "ready") {
            const seconds = (row.elapsedMs || 0) / 1000;
            return row.cacheHit === true
                ? I18n.tr("Ready (cached)")
                : I18n.tr("Ready in %1s").arg(seconds.toFixed(1));
        }
        if (row.state === "processing")
            return I18n.tr("Analysing");
        if (row.state === "pending")
            return I18n.tr("Queued");
        if (row.state === "error")
            return row.message || I18n.tr("Failed");
        return I18n.tr("No image wallpaper");
    }

    Rectangle {
        anchors.fill: parent
        radius: Theme.cornerRadius
        color: Theme.surfaceContainer
        opacity: 0.85
        border.color: root.editMode ? Theme.primary : "transparent"
        border.width: root.editMode ? 2 : 0

        Column {
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingS

            Row {
                width: parent.width
                spacing: Theme.spacingS

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "layers"
                    size: Theme.iconSizeSmall
                    color: Theme.primary
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Depthscape"
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                }
            }

            StyledText {
                width: parent.width
                text: root.status.enabled === true
                    ? I18n.tr("Depth effect on")
                    : I18n.tr("Depth effect off")
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }

            StyledText {
                width: parent.width
                visible: root.status.modelReady !== true
                text: I18n.tr("Model not installed")
                color: Theme.error
                font.pixelSize: Theme.fontSizeSmall
                wrapMode: Text.WordWrap
            }

            ListView {
                width: parent.width
                height: Math.max(0, parent.height - y)
                clip: true
                spacing: Theme.spacingXS
                model: root.outputs

                delegate: Row {
                    required property var modelData

                    width: ListView.view.width
                    spacing: Theme.spacingXS

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 6
                        height: 6
                        radius: 3
                        color: root.stateColor(modelData.state)
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: (modelData.name || "") + " · " + root.stateLabel(modelData)
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                        elide: Text.ElideRight
                        width: parent.width - 12
                    }
                }
            }
        }
    }

    // `pluginId` is injected by the wrapper in its `onLoaded`, which runs
    // *after* this item's Component.onCompleted — so the FileView above is
    // bound to `stateFilePath` rather than refreshed from here.
    Component.onCompleted: root.refresh()
}
