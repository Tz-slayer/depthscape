import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets
import qs.Modules.Plugins
import qs.Services
import "widgets"

// Depthscape settings, designed according to DMS native plugin specifications
// and Material 3 Expressive guidelines:
// - Root is PluginSettings backed by DMS's PluginService and settings store.
// - Clean elevated container cards per functional section.
// - Native DMS controls with reset-to-default on every configurable setting.
// - Centered section card titles without redundant explanatory subtitles.
// - Per-output configuration with dynamic display binding and automatic cascading reload.
PluginSettings {
    id: root

    pluginId: "depthscape"

    property var daemon: null
    property int daemonLookupTries: 0
    property bool buildingEngine: false
    property bool downloadingEngine: (root.daemon && root.daemon.downloadingEngine) || root._localDownloadingEngine
    property bool _localDownloadingEngine: false
    property string buildOutput: ""
    property string chosenScreen: ""

    readonly property bool fgModelReady: {
        const list = root.foregroundModels || [];
        for (let i = 0; i < list.length; i++) {
            if (list[i].id === root.selectedFgStatusId)
                return list[i].ready === true;
        }
        return false;
    }

    function lookupDaemon() {
        if (typeof PluginService === "undefined" || !PluginService)
            return false;
        const daemons = PluginService.pluginDaemonInstances;
        if (daemons && daemons["depthscape"]) {
            root.daemon = daemons["depthscape"];
            return true;
        }
        const instances = PluginService.pluginInstances;
        if (instances && instances["depthscape"]) {
            root.daemon = instances["depthscape"];
            return true;
        }
        return false;
    }

    Timer {
        id: daemonLookup
        interval: 500
        repeat: true
        running: false
        onTriggered: {
            if (root.lookupDaemon() || ++root.daemonLookupTries >= 40)
                daemonLookup.running = false;
        }
    }

    Process {
        id: buildProcess

        command: []
        running: false
        stdout: StdioCollector {
            onStreamFinished: root.buildOutput = text.trim().split("\n").slice(-1)[0]
        }
        stderr: StdioCollector {
            onStreamFinished: root.buildOutput = text.trim().split("\n").slice(-1)[0]
        }
        onExited: exitCode => {
            root.buildingEngine = false;
            if (exitCode === 0) {
                root.buildOutput = "";
                root.saveValue("action", "rescanEngine");
            } else if (root.buildOutput === "") {
                root.buildOutput = I18n.trFor("depthscape", "Build failed (exit %1)").arg(exitCode);
            }
        }
    }

    function buildEngine() {
        if (root.buildingEngine || root.downloadingEngine)
            return;
        root.buildingEngine = true;
        root.buildOutput = "";
        buildProcess.command = ["sh", "-c", root.buildCommand];
        buildProcess.running = true;
    }

    Process {
        id: downloadEngineProcess

        command: []
        running: false
        stdout: StdioCollector {
            onStreamFinished: root.buildOutput = text.trim().split("\n").slice(-1)[0]
        }
        stderr: StdioCollector {
            onStreamFinished: root.buildOutput = text.trim().split("\n").slice(-1)[0]
        }
        onExited: exitCode => {
            root._localDownloadingEngine = false;
            if (exitCode === 0) {
                root.buildOutput = "";
                root.saveValue("action", "rescanEngine");
            } else if (root.buildOutput === "") {
                root.buildOutput = I18n.trFor("depthscape", "Download failed (exit %1)").arg(exitCode);
            }
        }
    }

    function downloadEngine() {
        if (root.downloadingEngine || root.buildingEngine)
            return;
        if (root.daemon && root.daemon.downloadPrebuiltEngine) {
            root.daemon.downloadPrebuiltEngine();
        } else {
            root._localDownloadingEngine = true;
            root.buildOutput = "";
            downloadEngineProcess.command = ["sh", root.pluginRoot + "/tools/download-engine.sh", root.pluginRoot];
            downloadEngineProcess.running = true;
        }
    }

    // Displays
    readonly property var screens: Quickshell.screens ?? []

    /// Whether DMS is replacing wallpapers on a timer, globally or per screen.
    readonly property bool wallpaperCyclingActive: {
        if (SessionData.perMonitorWallpaper) {
            for (const screen of root.screens) {
                const settings = SessionData.getMonitorCyclingSettings(screen.name);
                if (settings && settings.enabled === true)
                    return true;
            }
            return false;
        }
        return SessionData.wallpaperCyclingEnabled === true;
    }

    readonly property string defaultScreenName: {
        const focused = (typeof NiriService !== "undefined" && NiriService) ? NiriService.currentOutput : "";
        for (let i = 0; i < screens.length; i++)
            if (screens[i].name === focused)
                return screens[i].name;
        return screens.length > 0 ? screens[0].name : "";
    }

    readonly property var displayScreenNames: {
        const out = [];
        for (let i = 0; i < screens.length; i++)
            out.push(screens[i].name);
        return out;
    }

    function hasScreen(name) {
        for (let i = 0; i < screens.length; i++)
            if (screens[i].name === name)
                return true;
        return false;
    }

    readonly property string screenName: root.hasScreen(root.chosenScreen)
        ? root.chosenScreen : root.defaultScreenName

    function settingKeyFor(base) {
        return base + "_" + root.screenName;
    }

    function repairScreenChoice() {
        if (displayPicker && !root.hasScreen(displayPicker.value) && root.defaultScreenName !== "")
            displayPicker.commitValue(root.defaultScreenName);
    }

    onScreensChanged: Qt.callLater(root.repairScreenChoice)

    Binding {
        target: root
        property: "chosenScreen"
        value: displayPicker ? displayPicker.value : root.defaultScreenName
    }

    onChosenScreenChanged: root.reloadChildValues()

    function reloadChildValues() {
        if (displayPicker && displayPicker.loadValue)
            displayPicker.loadValue();
        if (effectToggle && effectToggle.loadValue)
            effectToggle.loadValue();
        if (thresholdSlider && thresholdSlider.loadValue)
            thresholdSlider.loadValue();
        if (featherSlider && featherSlider.loadValue)
            featherSlider.loadValue();
        if (spatialToggle && spatialToggle.loadValue)
            spatialToggle.loadValue();
        if (spatialTravelSlider && spatialTravelSlider.loadValue)
            spatialTravelSlider.loadValue();
    }

    Component.onCompleted: {
        if (!root.lookupDaemon())
            daemonLookup.running = true;
        Qt.callLater(root.repairScreenChoice);
    }

    // Models & Daemon state
    readonly property bool daemonFound: root.daemon !== null
    readonly property bool engineFound: root.daemonFound && root.daemon.enginePath !== ""
    readonly property bool modelReady: {
        const list = root.availableModels || [];
        for (let i = 0; i < list.length; i++) {
            if (list[i].id === root.currentModelType)
                return list[i].ready === true;
        }
        return false;
    }
    readonly property bool modelBusy: root.daemonFound && root.daemon.modelBusy === true
    readonly property string engineProblem: root.daemonFound ? (root.daemon.engineProblem || "") : ""
    /// Everything the engine card can act on. Ready means the card stays hidden.
    readonly property bool engineNeedsAttention: !root.daemonFound || !root.engineFound
        || root.modelBusy || !root.modelReady || !root.fgModelReady || root.engineProblem !== ""
    readonly property var availableModels: root.daemonFound ? root.daemon.availableModels : []
    readonly property var foregroundModels: root.daemonFound ? root.daemon.foregroundModels : []

    // Native 3D renderer. It is a Quick3D module compiled against this host's
    // Qt, so it cannot ship as a binary; while it is absent the spatial mode
    // falls back to a shader that only translates the image.
    readonly property bool spatial3dReady: root.daemonFound && root.daemon.spatial3dReady === true
    readonly property bool spatial3dBuilding: root.daemonFound && root.daemon.spatial3dBuilding === true
    readonly property string spatial3dProblem: root.daemonFound ? (root.daemon.spatial3dProblem || "") : ""
    readonly property bool spatial3dNeedsAttention: root.daemonFound && !root.spatial3dReady
    readonly property string spatial3dStatusText: root.spatial3dBuilding
        ? I18n.trFor("depthscape", "Building the 3D renderer...")
        : (root.spatial3dProblem !== ""
            ? root.spatial3dProblem
            : I18n.trFor("depthscape", "Native 3D renderer not built; spatial mode uses the flat shader fallback."))

    // Fixed model pair, matching what the daemon provisions on first run.
    readonly property string currentModelType: "small"
    readonly property string selectedFgStatusId: "spatial-isnet-anime"

    readonly property string pluginRoot: Qt.resolvedUrl("..").toString()
        .replace(/^file:\/\//, "").replace(/\/$/, "")
    readonly property string engineCommand: "cd \"" + root.pluginRoot + "/engine\" && cargo build --release"
    readonly property string buildCommand: "export PATH=\"$HOME/.cargo/bin:$PATH\"; " + root.engineCommand

    readonly property string statusText: {
        if (root.downloadingEngine)
            return root.buildOutput !== "" ? I18n.trFor("depthscape", "Downloading prebuilt engine... %1").arg(root.buildOutput) : I18n.trFor("depthscape", "Downloading prebuilt engine...");
        if (root.buildingEngine)
            return root.buildOutput !== "" ? I18n.trFor("depthscape", "Building engine... %1").arg(root.buildOutput) : I18n.trFor("depthscape", "Building engine...");
        if (!root.daemonFound)
            return I18n.trFor("depthscape", "Plugin is starting. Reopen this page in a moment.");
        if (!root.engineFound) {
            if (root.buildOutput !== "")
                return root.buildOutput;
            return I18n.trFor("depthscape", "Engine binary not found. Download prebuilt binary or press Build Engine.");
        }
        if (root.modelBusy) {
            const installing = root.daemon ? root.daemon.installingModel : "";
            const removing = root.daemon ? root.daemon.removingModel : "";
            const target = installing || removing;
            const info = root.daemon && root.daemon.modelInfo ? root.daemon.modelInfo(target) : null;
            const modelName = info ? info.name : (target || I18n.trFor("depthscape", "model"));
            return I18n.trFor("depthscape", "Working on %1").arg(modelName);
        }
        if (!root.modelReady && !root.fgModelReady)
            return I18n.trFor("depthscape", "Models not downloaded. Please select and download models.");
        if (!root.modelReady)
            return I18n.trFor("depthscape", "Depth model not downloaded.");
        if (!root.fgModelReady)
            return I18n.trFor("depthscape", "Matting model not downloaded.");
        return I18n.trFor("depthscape", "Ready · Depth model and matting model are ready.");
    }

    readonly property string statusIcon: root.downloadingEngine ? "hourglass_empty"
        : root.buildingEngine ? "hourglass_empty"
        : !root.daemonFound ? "hourglass_empty"
        : !root.engineFound ? "download"
        : root.modelBusy ? "hourglass_empty"
        : (root.modelReady && root.fgModelReady) ? "check_circle" : "info"

    readonly property color statusColor: {
        if (!root.engineFound)
            return (root.buildOutput !== "" && !root.buildingEngine && !root.downloadingEngine) ? Theme.error : Theme.warning;
        if (root.modelBusy || root.buildingEngine || root.downloadingEngine)
            return Theme.warning;
        if (!root.modelReady || !root.fgModelReady)
            return Theme.warning;
        return Theme.primary;
    }

    // ---------------------------------------------------------------- UI Layout

    // Display Selection
    SettingsCard {
        visible: root.screens.length > 1

        SectionTitle {
            text: I18n.tr("Display")
            icon: "desktop_windows"
        }

        SettingDivider {}

        PluginDropdownRow {
            id: displayPicker
            settingKey: "targetScreen"
            label: I18n.tr("Display")
            defaultValue: root.defaultScreenName
            options: root.displayScreenNames
            optionValues: root.displayScreenNames
        }
    }

    // Depth Wallpaper
    SettingsCard {
        SectionTitle {
            text: I18n.trFor("depthscape", "Depth Wallpaper")
            icon: "layers"
        }

        SettingDivider {}

        PluginToggleRow {
            id: effectToggle
            settingKey: root.settingKeyFor("effectEnabled")
            label: I18n.trFor("depthscape", "Depth Wallpaper")
            defaultValue: true
        }

        SettingDivider {
            visible: effectToggle.value
        }

        PluginSliderRow {
            id: thresholdSlider
            visible: effectToggle.value
            settingKey: root.settingKeyFor("threshold")
            label: I18n.trFor("depthscape", "Occlusion Threshold")
            defaultValue: 30
            minimum: 1
            maximum: 99
            unit: "%"
        }

        SettingDivider {
            visible: effectToggle.value
        }

        PluginSliderRow {
            id: featherSlider
            visible: effectToggle.value
            settingKey: root.settingKeyFor("feather")
            label: I18n.trFor("depthscape", "Edge Feather")
            defaultValue: 8
            minimum: 0
            maximum: 40
            unit: "%"
        }
    }

    // Spatial Wallpaper
    SettingsCard {
        SectionTitle {
            text: I18n.trFor("depthscape", "Spatial Wallpaper")
            icon: "view_in_ar"
        }

        SettingDivider {}

        PluginToggleRow {
            id: spatialToggle
            settingKey: root.settingKeyFor("spatialEnabled")
            label: I18n.trFor("depthscape", "Spatial Wallpaper")
            defaultValue: false
        }

        SettingDivider {
            visible: spatialToggle.value && root.spatial3dNeedsAttention
        }

        // Only while spatial is on: with the toggle off the fallback changes
        // nothing the user can see, so the notice would be pure noise.
        StyledRect {
            id: spatial3dNotice
            visible: spatialToggle.value && root.spatial3dNeedsAttention
            width: parent.width
            height: spatial3dColumn.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadiusS
            color: Theme.withAlpha(Theme.warning, 0.08)
            border.color: Theme.withAlpha(Theme.warning, 0.3)
            border.width: 1

            Column {
                id: spatial3dColumn
                x: Theme.spacingM
                y: Theme.spacingM
                width: parent.width - Theme.spacingM * 2
                spacing: Theme.spacingS

                Row {
                    width: parent.width
                    spacing: Theme.spacingM

                    DIcon {
                        name: root.spatial3dBuilding ? "hourglass_empty" : "view_in_ar"
                        size: 20
                        color: Theme.warning
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        width: parent.width - 20 - Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.spatial3dStatusText
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        wrapMode: Text.WordWrap
                    }
                }

                DButton {
                    text: I18n.trFor("depthscape", "Build 3D Renderer")
                    iconName: "build"
                    tooltipText: I18n.trFor("depthscape", "Compiles the Quick3D mesh plugin against this system's Qt. Needs cmake, a C++ compiler and Qt Quick3D development files.")
                    busy: root.spatial3dBuilding
                    enabled: !root.spatial3dBuilding
                    onClicked: {
                        if (root.daemon && root.daemon.buildSpatial3d)
                            root.daemon.buildSpatial3d();
                    }
                }
            }
        }

        SettingDivider {
            visible: spatialToggle.value
        }

        PluginSliderRow {
            id: spatialTravelSlider
            visible: spatialToggle.value
            settingKey: root.settingKeyFor("spatialTravel")
            label: I18n.trFor("depthscape", "Parallax Amplitude")
            defaultValue: 3
            minimum: 0
            maximum: 10
            unit: "%"
        }
    }

    // Engine recovery. The engine and both models are provisioned automatically,
    // so in the normal case there is nothing to show and nothing to press -- the
    // card is rendered only when something actually needs the user.
    SettingsCard {
        visible: root.engineNeedsAttention

        SectionTitle {
            text: I18n.trFor("depthscape", "Engine")
            icon: "memory"
        }

        SettingDivider {}

        // Models are fixed now (Depth Anything V2 Small + IS-Net Anime) and are
        // provisioned automatically on first run, so there is nothing to pick.

        // Status Card
        StyledRect {
            width: parent.width
            height: statusRow.implicitHeight + (Theme.spacingM * 2)
            radius: Theme.cornerRadiusS
            color: Theme.withAlpha(root.statusColor, 0.08)
            border.color: Theme.withAlpha(root.statusColor, 0.3)
            border.width: 1

            Row {
                id: statusRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Theme.spacingM
                spacing: Theme.spacingM

                DIcon {
                    name: root.statusIcon
                    size: 20
                    color: root.statusColor
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    width: parent.width - 20 - Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.statusText
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }
            }
        }

        SettingDivider {}

        // Action Buttons
        Flow {
            width: parent.width
            spacing: Theme.spacingS

            DButton {
                text: I18n.trFor("depthscape", "Download Engine")
                iconName: "download"
                tooltipText: I18n.trFor("depthscape", "Download prebuilt binary from GitHub Releases (no Rust needed)")
                visible: !root.engineFound
                busy: root.downloadingEngine
                enabled: root.daemonFound && !root.downloadingEngine && !root.buildingEngine
                onClicked: root.downloadEngine()
            }

            DButton {
                text: I18n.trFor("depthscape", "Build Engine")
                iconName: "build"
                tooltipText: root.engineCommand
                visible: !root.engineFound
                busy: root.buildingEngine
                enabled: root.daemonFound && !root.buildingEngine && !root.downloadingEngine
                onClicked: root.buildEngine()
            }

            DButton {
                text: I18n.trFor("depthscape", "Re-check Engine")
                iconName: "refresh"
                visible: !root.engineFound
                enabled: root.daemonFound && !root.buildingEngine && !root.downloadingEngine
                onClicked: root.saveValue("action", "rescanEngine")
            }

        }
    }

    // Cached artefacts only cover the wallpaper currently displayed, so a timed
    // wallpaper change always pays a fresh inference. Say it here rather than
    // letting the blank window read as a bug.
    StyledText {
        visible: root.wallpaperCyclingActive
        width: parent.width
        text: I18n.trFor("depthscape", "Wallpaper cycling is on, so each new wallpaper is analysed from scratch: the depth effect briefly disappears after every change.")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceTextSecondary
        wrapMode: Text.WordWrap
    }
}
