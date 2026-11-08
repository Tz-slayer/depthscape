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
    property bool confirmPurge: false
    property bool buildingEngine: false
    property bool downloadingEngine: (root.daemon && root.daemon.downloadingEngine) || root._localDownloadingEngine
    property bool _localDownloadingEngine: false
    property string buildOutput: ""
    property string chosenScreen: ""

    readonly property string selectedFgStatusId: root.currentSpatialModel === "isnet-anime"
        ? "spatial-isnet-anime" : root.currentSpatialModel

    readonly property bool foregroundMissing: {
        if (!spatialToggle.value)
            return false;
        const list = root.foregroundModels || [];
        for (let i = 0; i < list.length; i++)
            if (list[i].id === root.selectedFgStatusId)
                return list[i].ready !== true;
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

    Timer {
        id: purgeConfirmTimer
        interval: 5000
        onTriggered: root.confirmPurge = false
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
                root.buildOutput = I18n.tr("Build failed (exit %1)").arg(exitCode);
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
                root.buildOutput = I18n.tr("Download failed (exit %1)").arg(exitCode);
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
        if (spatialModelPicker && spatialModelPicker.loadValue)
            spatialModelPicker.loadValue();
        if (modelPicker && modelPicker.loadValue)
            modelPicker.loadValue();
    }

    Component.onCompleted: {
        if (!root.lookupDaemon())
            daemonLookup.running = true;
        Qt.callLater(root.repairScreenChoice);
        Qt.callLater(root.syncModelValue);
        Qt.callLater(root.syncSpatialModelValue);
    }

    // Models & Daemon state
    readonly property bool daemonFound: root.daemon !== null
    readonly property bool engineFound: root.daemonFound && root.daemon.enginePath !== ""
    readonly property bool modelReady: root.daemonFound && root.daemon.modelReady === true
    readonly property bool modelBusy: root.daemonFound && root.daemon.modelBusy === true
    readonly property var availableModels: root.daemonFound ? root.daemon.availableModels : []
    readonly property var foregroundModels: root.daemonFound ? root.daemon.foregroundModels : []

    readonly property var modelIds: ["small", "base", "large"]
    readonly property var modelLabels: [
        "Depth Anything V2 Small (99MB)",
        "Depth Anything V2 Base (389MB)",
        "Depth Anything V2 Large (1.34GB)"
    ]

    readonly property var modelIcons: {
        const out = [];
        const list = root.availableModels || [];
        for (let i = 0; i < root.modelIds.length; i++) {
            let ready = false;
            for (let j = 0; j < list.length; j++) {
                if (list[j].id === root.modelIds[i]) {
                    ready = list[j].ready === true;
                    break;
                }
            }
            out.push(ready ? "check_circle" : "radio_button_unchecked");
        }
        return out;
    }

    property string currentModelType: "small"

    Binding {
        target: root
        property: "currentModelType"
        value: modelPicker ? modelPicker.value : "small"
    }

    function syncModelValue() {
        const stored = root.loadValue("modelType", "small");
        const valid = root.modelIds.indexOf(stored) >= 0 ? stored : "small";
        root.currentModelType = valid;
        if (modelPicker && modelPicker.value !== valid)
            modelPicker.commitValue(valid);
    }

    readonly property var fgModelIds: ["isnet-anime", "birefnet-lite", "birefnet"]
    readonly property var fgStatusIds: ["spatial-isnet-anime", "birefnet-lite", "birefnet"]
    readonly property var fgModelLabels: [
        "IS-Net Anime (168 MiB)",
        "BiRefNet Lite (224MB)",
        "BiRefNet General (973MB)"
    ]

    readonly property var fgModelIcons: {
        const out = [];
        const list = root.foregroundModels || [];
        for (let i = 0; i < root.fgStatusIds.length; i++) {
            let ready = false;
            for (let j = 0; j < list.length; j++) {
                if (list[j].id === root.fgStatusIds[i]) {
                    ready = list[j].ready === true;
                    break;
                }
            }
            out.push(ready ? "check_circle" : "radio_button_unchecked");
        }
        return out;
    }

    property string currentSpatialModel: "isnet-anime"

    Binding {
        target: root
        property: "currentSpatialModel"
        value: spatialModelPicker ? spatialModelPicker.value : "isnet-anime"
    }

    function syncSpatialModelValue() {
        const stored = root.loadValue("spatialModel", "isnet-anime");
        const valid = root.fgModelIds.indexOf(stored) >= 0 ? stored : "isnet-anime";
        root.currentSpatialModel = valid;
        if (spatialModelPicker && spatialModelPicker.value !== valid)
            spatialModelPicker.commitValue(valid);
    }

    readonly property string pluginRoot: Qt.resolvedUrl("..").toString()
        .replace(/^file:\/\//, "").replace(/\/$/, "")
    readonly property string engineCommand: "cd \"" + root.pluginRoot + "/engine\" && cargo build --release"
    readonly property string buildCommand: "export PATH=\"$HOME/.cargo/bin:$PATH\"; " + root.engineCommand

    readonly property string statusText: {
        if (root.downloadingEngine)
            return I18n.tr("Downloading prebuilt engine... ") + root.buildOutput;
        if (root.buildingEngine)
            return I18n.tr("Building engine... ") + root.buildOutput;
        if (!root.daemonFound)
            return I18n.tr("Plugin is starting. Reopen this page in a moment.");
        if (!root.engineFound) {
            if (root.buildOutput !== "")
                return root.buildOutput;
            return I18n.tr("Engine binary not found. Download prebuilt binary or press Build Engine.");
        }
        if (root.modelBusy)
            return I18n.tr("Working on ") + (root.daemon.installingModel || I18n.tr("model"));
        if (!root.modelReady)
            return I18n.tr("No model downloaded. Pick one above and press Download Model.");
        return I18n.tr("Ready · ") + (root.daemon.currentModelInfo
            ? root.daemon.currentModelInfo.name : root.daemon.modelType);
    }

    readonly property string statusIcon: root.downloadingEngine ? "hourglass_empty"
        : root.buildingEngine ? "hourglass_empty"
        : !root.daemonFound ? "hourglass_empty"
        : !root.engineFound ? "download"
        : root.modelBusy ? "hourglass_empty"
        : root.modelReady ? "check_circle" : "download"

    readonly property color statusColor: {
        if (!root.engineFound)
            return (root.buildOutput !== "" && !root.buildingEngine && !root.downloadingEngine) ? Theme.error : Theme.warning;
        if (root.modelBusy || root.buildingEngine || root.downloadingEngine)
            return Theme.warning;
        if (!root.modelReady)
            return Theme.warning;
        return Theme.primary;
    }

    // ---------------------------------------------------------------- UI Layout

    // Display Selection
    SettingsCard {
        visible: root.screens.length > 1

        SectionTitle {
            text: I18n.tr("Display Configuration")
            icon: "desktop_windows"
        }

        SettingDivider {}

        PluginDropdownRow {
            id: displayPicker
            settingKey: "targetScreen"
            label: I18n.tr("Target Display")
            defaultValue: root.defaultScreenName
            options: root.displayScreenNames
            optionValues: root.displayScreenNames
        }
    }

    // Depth Occlusion
    SettingsCard {
        SectionTitle {
            text: I18n.tr("Depth Occlusion")
            icon: "layers"
        }

        SettingDivider {}

        PluginToggleRow {
            id: effectToggle
            settingKey: root.settingKeyFor("effectEnabled")
            label: I18n.tr("Enable Depth Effect")
            defaultValue: true
        }

        SettingDivider {}

        PluginSliderRow {
            id: thresholdSlider
            settingKey: root.settingKeyFor("threshold")
            label: I18n.tr("Occlusion Threshold")
            defaultValue: 30
            minimum: 1
            maximum: 99
            unit: "%"
            enabled: effectToggle.value
        }

        SettingDivider {}

        PluginSliderRow {
            id: featherSlider
            settingKey: root.settingKeyFor("feather")
            label: I18n.tr("Edge Feather")
            defaultValue: 8
            minimum: 0
            maximum: 40
            unit: "%"
            enabled: effectToggle.value
        }
    }

    // Spatial 3D
    SettingsCard {
        SectionTitle {
            text: I18n.tr("Spatial 3D")
            icon: "view_in_ar"
        }

        SettingDivider {}

        PluginToggleRow {
            id: spatialToggle
            settingKey: root.settingKeyFor("spatialEnabled")
            label: I18n.tr("Spatial 3D Mesh Effect")
            defaultValue: false
        }

        SettingDivider {
            visible: spatialToggle.value
        }

        PluginDropdownRow {
            id: spatialModelPicker
            visible: spatialToggle.value
            settingKey: "spatialModel"
            label: I18n.tr("Foreground Model")
            defaultValue: "isnet-anime"
            options: root.fgModelLabels
            optionValues: root.fgModelIds
            optionIcons: root.fgModelIcons
        }

        SettingDivider {
            visible: spatialToggle.value
        }

        PluginSliderRow {
            id: spatialTravelSlider
            visible: spatialToggle.value
            settingKey: root.settingKeyFor("spatialTravel")
            label: I18n.tr("Motion Amplitude")
            defaultValue: 3
            minimum: 0
            maximum: 10
            unit: "%"
        }
    }

    // AI Depth Model & Engine
    SettingsCard {
        SectionTitle {
            text: I18n.tr("AI Depth Model")
            icon: "psychology"
        }

        SettingDivider {}

        PluginDropdownRow {
            id: modelPicker
            settingKey: "modelType"
            label: I18n.tr("Model Architecture")
            defaultValue: "small"
            options: root.modelLabels
            optionValues: root.modelIds
            optionIcons: root.modelIcons
        }

        SettingDivider {}

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
                text: I18n.tr("Download Engine")
                iconName: "download"
                tooltipText: I18n.tr("Download prebuilt binary from GitHub Releases (no Rust needed)")
                visible: !root.engineFound
                busy: root.downloadingEngine
                enabled: root.daemonFound && !root.downloadingEngine && !root.buildingEngine
                onClicked: root.downloadEngine()
            }

            DButton {
                text: I18n.tr("Build Engine")
                iconName: "build"
                tooltipText: root.engineCommand
                visible: !root.engineFound
                busy: root.buildingEngine
                enabled: root.daemonFound && !root.buildingEngine && !root.downloadingEngine
                onClicked: root.buildEngine()
            }

            DButton {
                text: I18n.tr("Re-check Engine")
                iconName: "refresh"
                visible: !root.engineFound
                enabled: root.daemonFound && !root.buildingEngine && !root.downloadingEngine
                onClicked: root.saveValue("action", "rescanEngine")
            }

            DButton {
                text: root.modelReady ? I18n.tr("Re-download Model") : I18n.tr("Download Model")
                iconName: "download"
                tooltipText: I18n.tr("Downloads the selected model only when you press this button.")
                busy: root.modelBusy
                enabled: root.engineFound && !root.modelBusy
                onClicked: root.saveValue("action", (root.modelReady ? "installForce:" : "install:") + root.currentModelType)
            }

            DButton {
                text: I18n.tr("Regenerate Depth")
                iconName: "refresh"
                enabled: root.modelReady && !root.modelBusy
                onClicked: root.saveValue("action", "generate")
            }

            DButton {
                text: I18n.tr("Clear Cache")
                iconName: "delete"
                enabled: root.engineFound && !root.modelBusy
                onClicked: root.saveValue("action", "clearCache")
            }

            DButton {
                text: root.confirmPurge ? I18n.tr("Confirm Removal") : I18n.tr("Remove Model Data")
                iconName: "delete_forever"
                tooltipText: I18n.tr("Deletes every downloaded model and all generated data. Do this before uninstalling Depthscape.")
                enabled: root.engineFound && !root.modelBusy
                textColor: root.confirmPurge ? Theme.error : Theme.buttonText
                backgroundColor: root.confirmPurge ? Theme.withAlpha(Theme.error, 0.12) : Theme.buttonBg
                onClicked: {
                    if (!root.confirmPurge) {
                        root.confirmPurge = true;
                        purgeConfirmTimer.restart();
                        return;
                    }
                    root.confirmPurge = false;
                    purgeConfirmTimer.stop();
                    root.saveValue("action", "uninstall");
                }
            }
        }

        // Spatial foreground fallback banner
        StyledRect {
            width: parent.width
            height: fgNoticeRow.implicitHeight + (Theme.spacingM * 2)
            radius: Theme.cornerRadiusS
            color: Theme.withAlpha(Theme.warning, 0.08)
            border.color: Theme.withAlpha(Theme.warning, 0.3)
            border.width: 1
            visible: root.foregroundMissing

            Row {
                id: fgNoticeRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Theme.spacingM
                spacing: Theme.spacingM

                DIcon {
                    name: "info"
                    size: 20
                    color: Theme.warning
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    width: parent.width - 20 - Theme.spacingM - fgDownloadBtn.width - Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    text: I18n.tr("Spatial foreground model not downloaded (depth-guided fallback is used).")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                DButton {
                    id: fgDownloadBtn
                    text: I18n.tr("Download")
                    iconName: "download"
                    anchors.verticalCenter: parent.verticalCenter
                    enabled: root.engineFound && !root.modelBusy
                    onClicked: root.saveValue("action", "install:" + root.selectedFgStatusId)
                }
            }
        }
    }
}
