import QtQuick
import Quickshell
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets
import "widgets"

// Depthscape settings page.
//
// Layout rule: one card per *thing the user is configuring*, not one card per
// technical layer. Rows that only matter while a governing toggle is on sit
// below a SettingDivider inside the same card, so the dependency is visible
// instead of implied.
//
// Every reading control is one of the vendored `*SettingPlus` widgets or a
// SettingRow, which gives every row the same hover highlight, info tooltip,
// dirty-state reset affordance and disabled-opacity behaviour.
PluginSettings {
    id: root

    pluginId: "depthscape"

    readonly property var daemon: {
        if (typeof PluginService === "undefined" || !PluginService)
            return null;
        if (PluginService.pluginDaemonInstances && PluginService.pluginDaemonInstances["depthscape"])
            return PluginService.pluginDaemonInstances["depthscape"];
        if (PluginService.pluginInstances && PluginService.pluginInstances["depthscape"])
            return PluginService.pluginInstances["depthscape"];
        return null;
    }

    // Grouped visibility. Each of these gates whether a *whole group* of
    // dependent rows is worth showing, so the rows can fade as one unit
    // instead of each deciding for itself.
    readonly property bool cutoutActive: thresholdSetting.value > 0
    readonly property bool parallaxActive: parallaxEnabledSetting.value
    readonly property bool overviewActive: fadeInOverviewSetting.value

    readonly property bool isBiRefNet: (modelTypeSetting.value || "").indexOf("birefnet") !== -1

    function isModelReady(modelId) {
        if (!root.daemon || !root.daemon.availableModels)
            return false;
        for (let i = 0; i < root.daemon.availableModels.length; i++) {
            if (root.daemon.availableModels[i].id === modelId)
                return root.daemon.availableModels[i].ready === true;
        }
        return false;
    }

    function getModelInfo(modelId) {
        if (!root.daemon || !root.daemon.availableModels)
            return null;
        for (let i = 0; i < root.daemon.availableModels.length; i++) {
            if (root.daemon.availableModels[i].id === modelId)
                return root.daemon.availableModels[i];
        }
        return null;
    }

    function formatBytes(bytes) {
        if (!bytes || bytes <= 0) return "0 MB";
        const mb = bytes / 1000000;
        if (mb >= 1000) {
            return (mb / 1000).toFixed(2) + " GB";
        }
        return Math.round(mb) + " MB";
    }

    property bool refreshingControls: false

    function refreshControls(item) {
        const outer = !root.refreshingControls;
        root.refreshingControls = true;
        if (item.settingKey !== undefined && item.value !== undefined) {
            item.value = root.loadValue(item.settingKey, item.defaultValue);
            if (typeof item.load === "function") item.load();
            if (typeof item.loadValue === "function") item.loadValue();
        }
        if (item.children) {
            for (let i = 0; i < item.children.length; i++) {
                refreshControls(item.children[i]);
            }
        }
        if (outer) root.refreshingControls = false;
    }

    function requestAction(action) {
        if (!pluginService)
            return;
        pluginService.savePluginData(pluginId, "action", action);
    }

    // Restores every control to the default it already declares. The page used
    // to keep a second hand-written copy of all fifteen defaults, which drifted
    // from the controls whenever one changed; walking the tree means the
    // control's own `defaultValue` is the only source of truth.
    //
    // `revertToDefault()` on the vendored controls exists for this walk --
    // `resetToDefault()` moves the control but never persists.
    function revertItem(item) {
        if (typeof item.revertToDefault === "function") {
            item.revertToDefault();
            // The control just wrote its own subtree's settings; walking into
            // it again would re-run the same writes.
            return;
        }
        const children = item.children;
        if (!children)
            return;
        for (let i = 0; i < children.length; i++) {
            revertItem(children[i]);
        }
    }

    function resetDefaults() {
        if (!pluginService)
            return;
        root.revertItem(root);
        root.requestAction("resetDefaults");
        if (typeof ToastService !== "undefined" && ToastService.showInfo) {
            ToastService.showInfo("Depthscape", I18n.tr("Settings restored to defaults"), "", "depthscape-settings-reset");
        }
    }

    // ── 1. Depth Effect ─────────────────────────────────────────────────────
    SettingsCard {
        id: effectSection

        SectionTitle {
            text: I18n.tr("Depth Effect")
            icon: "layers"
        }

        ToggleSettingPlus {
            id: effectEnabledSetting
            settingKey: "effectEnabled"
            label: I18n.tr("Enable Depthscape")
            description: I18n.tr("Split the wallpaper into depth planes and draw the foreground subject over desktop widgets and windows. Turning this off returns the wallpaper untouched.")
            defaultValue: true
        }

        Item {
            width: parent.width
            implicitHeight: effectGroup.implicitHeight
            visible: effectEnabledSetting.value
            // Kept out of the layout when off rather than merely hidden, so the
            // card shrinks; the sibling groups in this page do the same.
            height: visible ? implicitHeight : 0
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.shortDuration } }

            Column {
                id: effectGroup
                width: parent.width
                spacing: Theme.spacingM

                SettingDivider {
                    text: I18n.tr("Effect Layers")
                    description: I18n.tr("What Depthscape is allowed to draw between the wallpaper background and the foreground subject.")
                    groupActive: effectEnabledSetting.value
                }

                ToggleSettingPlus {
                    id: widgetsEnabledSetting
                    settingKey: "widgetsEnabled"
                    label: I18n.tr("Show Desktop Widgets")
                    description: I18n.tr("Draw Depthscape's desktop widgets between the background and foreground subject layers. They stay stationary while the scene slides, which is what creates the sense of depth.")
                    defaultValue: true
                }

                ToggleSettingPlus {
                    id: autoGenerateSetting
                    settingKey: "autoGenerate"
                    label: I18n.tr("Generate Automatically")
                    description: I18n.tr("Recompute the cutout images whenever the wallpaper or the cutout sliders change. Turn this off to apply changes manually with the Regenerate action.")
                    defaultValue: true
                }
            }
        }
    }

    // ── 2. AI Architecture & Model ──────────────────────────────────────────
    SettingsCard {
        id: modelSection

        SectionTitle {
            text: I18n.tr("AI Model & Architecture")
            icon: "auto_awesome"
        }

        SelectionSettingPlus {
            id: modelTypeSetting
            settingKey: "modelType"
            label: I18n.tr("Model Architecture & Variant")
            description: I18n.tr("Choose between Monocular Depth Estimation (Depth Anything V2) and Salient Subject Segmentation (BiRefNet). Models auto-download on first use.")
            defaultValue: "small"
            options: [
                { label: I18n.tr("Depth Anything V2 Small (~99 MB, Fast)"), value: "small" },
                { label: I18n.tr("Depth Anything V2 Base (~389 MB, Balanced)"), value: "base" },
                { label: I18n.tr("Depth Anything V2 Large (~1.34 GB, High Quality)"), value: "large" },
                { label: I18n.tr("BiRefNet Lite (~224 MB, Salient Foreground)"), value: "birefnet-lite" },
                { label: I18n.tr("BiRefNet General (~973 MB, Ultra Precision)"), value: "birefnet" }
            ]
        }

        SettingRow {
            id: modelArchitectureRow
            label: I18n.tr("Active Architecture")
            description: root.isBiRefNet
                ? I18n.tr("BiRefNet (Bilateral Reference Network) specializes in salient object and character segmentation. It outputs high-resolution foreground masks, making it ideal for portraits, anime, and sharp character cutout.")
                : I18n.tr("Depth Anything V2 is a foundation model for monocular depth estimation. It estimates continuous 3D relative scene depth across the entire wallpaper.")
            showReset: false

            StatusChip {
                icon: root.isBiRefNet ? "person" : "view_in_ar"
                iconColor: Theme.primary
                emphasized: true
                text: root.isBiRefNet
                    ? I18n.tr("Salient Subject Segmentation (BiRefNet)")
                    : I18n.tr("Relative Depth Estimation (Depth Anything)")
                detail: root.isBiRefNet ? I18n.tr("1024×1024 Mask Logits") : I18n.tr("Dynamic ViT Depth Map")
            }
        }

        SettingRow {
            id: modelStatusRow
            label: I18n.tr("Selected Model Status")
            description: I18n.tr("Read-only state of the neural engine. The model is downloaded to ~/.local/share/depthscape/models on first use, or on demand using the actions below.")
            showReset: false

            StatusChip {
                readonly property bool ready: root.isModelReady(modelTypeSetting.value)
                readonly property bool busy: root.daemon && root.daemon.modelBusy

                icon: busy
                    ? "hourglass_top"
                    : ready
                    ? "check_circle"
                    : "cloud_download"
                iconColor: busy
                    ? Theme.primary
                    : ready
                    ? Theme.success
                    : Theme.warning
                emphasized: !ready || busy
                text: busy
                    ? I18n.tr("Downloading and verifying model weights...")
                    : ready
                    ? I18n.tr("Model installed and ready on disk")
                    : I18n.tr("Model not downloaded (auto-pull on first use)")
                detail: {
                    const info = root.getModelInfo(modelTypeSetting.value);
                    return info ? root.formatBytes(info.size) : modelTypeSetting.value;
                }
            }
        }

        SettingRow {
            id: modelActionsRow
            label: I18n.tr("Model Actions")
            description: I18n.tr("Install or re-verify the active model weights against upstream SHA-256 checksums, or trigger immediate wallpaper cutout generation.")
            showReset: false

            Row {
                width: parent.width
                spacing: Theme.spacingS

                DankButton {
                    readonly property bool ready: root.isModelReady(modelTypeSetting.value)
                    readonly property bool busy: root.daemon && root.daemon.modelBusy

                    text: busy
                        ? I18n.tr("Downloading...")
                        : ready
                        ? I18n.tr("Re-verify / Reinstall")
                        : I18n.tr("Download Model Now")
                    iconName: busy ? "hourglass_top" : (ready ? "sync" : "download")
                    enabled: !busy
                    onClicked: root.requestAction("install:" + modelTypeSetting.value)
                }

                DankButton {
                    readonly property bool ready: root.isModelReady(modelTypeSetting.value)
                    readonly property bool busy: root.daemon && root.daemon.modelBusy

                    text: I18n.tr("Regenerate Now")
                    iconName: "refresh"
                    enabled: ready && !busy
                    onClicked: root.requestAction("generate")
                }
            }
        }

        SettingDivider {
            text: I18n.tr("Model Storage & On-Demand Pull")
            description: I18n.tr("Overview of model weights stored in ~/.local/share/depthscape/models. Click any model to select it, or use Pull to download it.")
            groupActive: root.daemon && root.daemon.availableModels && root.daemon.availableModels.length > 0
            visible: groupActive
        }

        Column {
            width: parent.width
            spacing: Theme.spacingS
            visible: root.daemon && root.daemon.availableModels && root.daemon.availableModels.length > 0

            Repeater {
                model: root.daemon && root.daemon.availableModels ? root.daemon.availableModels : []

                delegate: StyledRect {
                    id: modelRowItem
                    required property var modelData
                    required property int index

                    readonly property bool isSelected: modelTypeSetting.value === modelData.id
                    readonly property bool isInstalled: modelData.ready === true
                    readonly property bool isBusy: root.daemon && root.daemon.modelBusy && (root.daemon.installingModel === modelData.id || (!root.daemon.installingModel && modelTypeSetting.value === modelData.id))

                    width: parent.width
                    implicitHeight: 48
                    height: implicitHeight
                    radius: Theme.cornerRadius
                    color: isSelected
                        ? Theme.withAlpha(Theme.primary, 0.1)
                        : Theme.withAlpha(Theme.surfaceContainerHigh, 0.4)
                    border.width: isSelected ? 1 : 0
                    border.color: Theme.withAlpha(Theme.primary, 0.4)

                    MouseArea {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.right: actionRow.left
                        cursorShape: isSelected ? Qt.ArrowCursor : Qt.PointingHandCursor
                        onClicked: {
                            if (!isSelected) {
                                modelTypeSetting.value = modelData.id;
                            }
                        }
                    }

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingM
                        width: parent.width - actionRow.width - Theme.spacingM * 3

                        DankIcon {
                            name: modelData.id.indexOf("birefnet") !== -1 ? "person" : "view_in_ar"
                            size: 18
                            color: isSelected ? Theme.primary : Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            width: parent.width - 24

                            Row {
                                spacing: Theme.spacingXS
                                StyledText {
                                    text: modelData.name || modelData.id
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: isSelected ? Font.DemiBold : Font.Medium
                                    color: Theme.surfaceText
                                    elide: Text.ElideRight
                                }

                                Rectangle {
                                    visible: isSelected
                                    width: activeText.implicitWidth + 8
                                    height: 16
                                    radius: 8
                                    color: Theme.withAlpha(Theme.primary, 0.2)
                                    anchors.verticalCenter: parent.verticalCenter

                                    StyledText {
                                        id: activeText
                                        anchors.centerIn: parent
                                        text: I18n.tr("ACTIVE")
                                        font.pixelSize: 9
                                        font.weight: Font.Bold
                                        color: Theme.primary
                                    }
                                }
                            }

                            StyledText {
                                text: (modelData.id.indexOf("birefnet") !== -1
                                    ? I18n.tr("Salient Subject")
                                    : I18n.tr("Depth Estimation"))
                                    + " • " + root.formatBytes(modelData.size)
                                font.pixelSize: Theme.fontSizeExtraSmall
                                color: Theme.surfaceVariantText
                            }
                        }
                    }

                    Row {
                        id: actionRow
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingS

                        StatusChip {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 105
                            icon: isBusy
                                ? "hourglass_top"
                                : isInstalled
                                ? "check_circle"
                                : "cloud_download"
                            iconColor: isBusy
                                ? Theme.primary
                                : isInstalled
                                ? Theme.success
                                : Theme.warning
                            text: isBusy
                                ? I18n.tr("Downloading")
                                : isInstalled
                                ? I18n.tr("Ready")
                                : I18n.tr("Missing")
                        }

                        DankButton {
                            anchors.verticalCenter: parent.verticalCenter
                            text: isBusy ? I18n.tr("Busy") : (isInstalled ? I18n.tr("Verify") : I18n.tr("Pull"))
                            iconName: isBusy ? "hourglass_top" : (isInstalled ? "sync" : "download")
                            enabled: !root.daemon || !root.daemon.modelBusy
                            onClicked: root.requestAction("install:" + modelData.id)
                        }
                    }
                }
            }
        }
    }

    // ── 3. Cutout & Parallax ────────────────────────────────────────────────
    // The two halves of the same visual effect: the cutout decides *what* is a
    // foreground plane, parallax decides how far that plane travels. Grouping
    // them keeps the sliders that interact next to each other.
    SettingsCard {
        id: cutoutSection

        SectionTitle {
            text: I18n.tr("Cutout & Parallax")
            icon: "animation"
        }

        SettingDivider {
            text: root.isBiRefNet ? I18n.tr("Subject Segmentation Cutout") : I18n.tr("Depth Cutout")
            description: root.isBiRefNet
                ? I18n.tr("Where the subject mask is split into foreground and background. Tuning these sliders re-runs only the instant edge refinement step, not the neural network.")
                : I18n.tr("Where the depth map is split into a foreground subject and a background plate. Both sliders re-run only the fast split step, not the neural inference.")
        }

        SliderSettingPlus {
            id: thresholdSetting
            settingKey: "threshold"
            label: root.isBiRefNet ? I18n.tr("Subject Cutout Threshold") : I18n.tr("Foreground Depth Threshold")
            description: root.isBiRefNet
                ? I18n.tr("Confidence threshold (0% - 100%). Lower values retain subtle subject details and hair; higher values isolate only high-confidence foreground.")
                : I18n.tr("Depth cutoff point (0% - 100%). Lower values bring more depth layers in front of desktop widgets.")
            minimum: 0
            maximum: 100
            defaultValue: 30
            unit: "%"
            leftLabel: root.isBiRefNet ? "0% (Loose)" : "0%"
            rightLabel: root.isBiRefNet ? "100% (Strict)" : "100%"
        }

        SliderSettingPlus {
            id: featherSetting
            settingKey: "feather"
            label: root.isBiRefNet ? I18n.tr("Silhouette Edge Refinement") : I18n.tr("Edge Feather")
            description: root.isBiRefNet
                ? I18n.tr("Guided filter radius (0% - 50%). Refines the AI subject mask using high-resolution luminance edges from the original wallpaper.")
                : I18n.tr("Width of the soft transition zone around the cutoff (0% - 50%). Guided filter recovers fine hair and silhouette contours.")
            minimum: 0
            maximum: 50
            defaultValue: 8
            unit: "%"
            leftLabel: "0%"
            rightLabel: "50%"
            enabled: root.cutoutActive
        }

        ToggleSettingPlus {
            id: parallaxEnabledSetting
            settingKey: "parallaxEnabled"
            label: I18n.tr("Navigation Parallax")
            description: I18n.tr("Slide the scene as you navigate between workspaces and columns over stationary desktop widgets.")
            defaultValue: true
        }

        Item {
            width: parent.width
            implicitHeight: parallaxGroup.implicitHeight
            visible: root.parallaxActive
            height: visible ? implicitHeight : 0
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.shortDuration } }

            Column {
                id: parallaxGroup
                width: parent.width
                spacing: Theme.spacingM

                SettingDivider {
                    text: I18n.tr("Motion")
                    description: I18n.tr("How far the scene travels per navigation step, and the limit it approaches asymptotically. Measured against the output's own size, so multi-monitor setups stay consistent.")
                    groupActive: root.parallaxActive
                }

                SliderSettingPlus {
                    id: parallaxStepVerticalSetting
                    settingKey: "parallaxStepVertical"
                    label: I18n.tr("Vertical Step")
                    description: I18n.tr("Displacement on the first workspace step as per-mille (‰) of output screen height.")
                    minimum: 0
                    maximum: 200
                    defaultValue: 60
                    unit: "‰"
                    leftLabel: "0‰"
                    rightLabel: "200‰"
                }

                SliderSettingPlus {
                    id: parallaxStepHorizontalSetting
                    settingKey: "parallaxStepHorizontal"
                    label: I18n.tr("Horizontal Step")
                    description: I18n.tr("Displacement on the first column step as per-mille (‰) of output screen width. Columns only exist where a workspace has windows, so on an empty workspace the horizontal axis stays put.")
                    minimum: 0
                    maximum: 200
                    defaultValue: 35
                    unit: "‰"
                    leftLabel: "0‰"
                    rightLabel: "200‰"
                }

                SliderSettingPlus {
                    id: parallaxTravelSetting
                    settingKey: "parallaxTravel"
                    label: I18n.tr("Total Travel Limit")
                    description: I18n.tr("Asymptotic distance limit as a percentage of the longer screen edge. The scene approaches this reserve but never exceeds it.")
                    minimum: 0
                    maximum: 30
                    defaultValue: 12
                    unit: "%"
                    leftLabel: "0%"
                    rightLabel: "30%"
                }

                SliderSettingPlus {
                    id: parallaxDurationSetting
                    settingKey: "parallaxDuration"
                    label: I18n.tr("Motion Duration")
                    description: I18n.tr("Duration of the parallax slide animation in milliseconds (0 is instant snap).")
                    minimum: 0
                    maximum: 600
                    defaultValue: 240
                    unit: "ms"
                    leftLabel: "0ms"
                    rightLabel: "600ms"
                }

                ToggleSettingPlus {
                    id: parallaxInvertedSetting
                    settingKey: "parallaxInverted"
                    label: I18n.tr("Invert Direction")
                    description: I18n.tr("Invert the movement direction when navigating. The background always moves opposite to the foreground.")
                    defaultValue: false
                }
            }
        }
    }

    // ── 4. Overview & Widgets ───────────────────────────────────────────────
    SettingsCard {
        id: overviewSection

        SectionTitle {
            text: I18n.tr("Overview & Widgets")
            icon: "blur_on"
        }

        ToggleSettingPlus {
            id: fadeInOverviewSetting
            settingKey: "fadeInOverview"
            label: I18n.tr("Dim Layers in Overview")
            description: I18n.tr("Dim the subject cutout and desktop widgets while niri's overview is active, keeping the background backdrop continuous across every workspace card.")
            defaultValue: true
        }

        Item {
            width: parent.width
            implicitHeight: overviewGroup.implicitHeight
            visible: root.overviewActive
            height: visible ? implicitHeight : 0
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.shortDuration } }

            Column {
                id: overviewGroup
                width: parent.width
                spacing: Theme.spacingM

                SettingDivider {
                    text: I18n.tr("Transition")
                    description: I18n.tr("How far the layers dim and how long the cross-fade takes when overview opens or closes.")
                    groupActive: root.overviewActive
                }

                SliderSettingPlus {
                    id: overviewOpacitySetting
                    settingKey: "overviewOpacity"
                    label: I18n.tr("Resting Opacity")
                    description: I18n.tr("Resting opacity of the foreground and widgets while overview stays open (per-mille ‰).")
                    minimum: 0
                    maximum: 1000
                    defaultValue: 120
                    unit: "‰"
                    leftLabel: "0‰"
                    rightLabel: "1000‰"
                }

                SliderSettingPlus {
                    id: overviewFadeDurationSetting
                    settingKey: "overviewFadeDuration"
                    label: I18n.tr("Fade Duration")
                    description: I18n.tr("Cross-fade duration when entering or leaving overview. Should match Motion Duration above so the two animations read as one motion.")
                    minimum: 0
                    maximum: 1000
                    defaultValue: 240
                    unit: "ms"
                    leftLabel: "0ms"
                    rightLabel: "1000ms"
                }
            }
        }
    }

    // ── 5. Desktop Widgets Layout ───────────────────────────────────────────
    SettingsCard {
        id: widgetsSection

        SectionTitle {
            text: I18n.tr("Desktop Widgets Layout")
            icon: "widgets"
        }

        SettingRow {
            id: layoutPathRow
            label: I18n.tr("Layout File")
            description: I18n.tr("A JSON array. Each entry sets a widget type (e.g. clock), pixel coordinates (x, y), and widget-specific options. Depthscape watches the file, so edits apply without a restart.")
            showReset: false

            StatusChip {
                icon: "description"
                iconColor: Theme.secondary
                text: I18n.tr("$XDG_DATA_HOME/depthscape/widgets.json")
                detail: I18n.tr("JSON")
            }
        }

        SettingRow {
            id: layoutActionRow
            label: I18n.tr("Example Layout")
            description: I18n.tr("Writes a commented sample layout to the path above. This overwrites the existing file, so copy any edits you have made first.")
            showReset: false

            DankButton {
                text: I18n.tr("Write Example Layout")
                iconName: "edit"
                onClicked: root.requestAction("exampleLayout")
            }
        }
    }

    // ── 6. Maintenance ──────────────────────────────────────────────────────
    SettingsCard {
        id: maintenanceSection

        SectionTitle {
            text: I18n.tr("Maintenance")
            icon: "build"
        }

        SettingRow {
            id: resetRow
            label: I18n.tr("Restore Defaults")
            description: I18n.tr("Returns every control on this page to its default value. Generated cutouts are left on disk; use Clear Cache to remove those too.")
            showReset: false

            DankButton {
                text: I18n.tr("Reset Defaults")
                iconName: "restore"
                onClicked: root.resetDefaults()
            }
        }

        SettingRow {
            id: cacheRow
            label: I18n.tr("Cache")
            description: I18n.tr("Depth inference, refined masks and split images are cached per wallpaper. Clearing forces a full re-inference on the next wallaper change, which takes seconds rather than milliseconds.")
            showReset: false

            Row {
                width: parent.width
                spacing: Theme.spacingS

                DankButton {
                    text: I18n.tr("Clear Cache")
                    iconName: "delete"
                    onClicked: root.requestAction("clearCache")
                }

                DankButton {
                    text: I18n.tr("Reset Parallax Position")
                    iconName: "center_focus_strong"
                    onClicked: {
                        if (typeof Proc !== "undefined" && Proc.runCommand)
                            Proc.runCommand("reset-parallax", ["dms", "ipc", "call", "depthscape", "resetParallax"], function() {});
                    }
                }
            }
        }
    }

    // ── 7. IPC Commands (Collapsible) ───────────────────────────────────────
    SettingsCard {
        id: ipcSection

        SectionTitle {
            id: ipcTitle
            text: I18n.tr("IPC Commands")
            icon: "terminal"
            collapsible: true
            settingKey: "ipcCommandsExpanded"
        }

        Column {
            width: parent.width
            spacing: Theme.spacingS
            visible: ipcTitle.isExpanded

            Repeater {
                model: [
                    { text: "dms ipc call depthscape generate", label: I18n.tr("Regenerate all monitor splits") },
                    { text: "dms ipc call depthscape install", label: I18n.tr("Download & verify selected depth model") },
                    { text: "dms ipc call depthscape clearCache", label: I18n.tr("Clear depth and split cache entries") },
                    { text: "dms ipc call depthscape remap", label: I18n.tr("Re-map the three surfaces on every output") },
                    { text: "dms ipc call depthscape resetParallax", label: I18n.tr("Re-center parallax on current workspace") },
                    { text: "dms ipc call depthscape debug", label: I18n.tr("Query daemon status and split outputs") },
                    { text: "dms ipc call depthscape parallax", label: I18n.tr("Query real-time parallax offsets") },
                    { text: "dms ipc call depthscape services", label: I18n.tr("Inspect compositor service availability") }
                ]

                delegate: CopyBox {
                    label: modelData.label
                    text: modelData.text
                }
            }
        }
    }

    // ── 8. Usage Guide (Collapsible) ────────────────────────────────────────
    SettingsCard {
        id: guideSection

        SectionTitle {
            id: guideTitle
            text: I18n.tr("Usage Guide")
            icon: "menu_book"
            collapsible: true
            settingKey: "usageGuideExpanded"
        }

        UsageGuide {
            expanded: guideTitle.isExpanded
            items: [
                I18n.tr("<b>Required niri layer rule.</b> Add a rule matching namespace <b>^depthscape:</b> with <b>place-within-backdrop true</b> to <b>~/.config/niri/dms/local/custom.kdl</b>. Without it niri clones each surface per workspace card instead of sharing one backdrop, and you get a separate copy of the wallpaper in every overview tile."),
                I18n.tr("<b>Three-tier cache.</b> Neural depth inference runs once per wallpaper. Adjusting the threshold or feather sliders only re-runs the fast split step, so those controls stay responsive even on a 5K wallpaper."),
                I18n.tr("<b>Stationary widgets frame the motion.</b> Desktop widgets never move. The wallpaper scene slides behind them, which is what makes the depth read as real rather than as a sliding image."),
                I18n.tr("<b>Navigation is polled, not signalled.</b> The plugin reads compositor state through <b>niri msg --json</b> because the plugin daemon cannot see NiriService. Offsets therefore settle within one poll interval, not instantly.")
            ]
        }
    }

    // ── 9. About & Repository ───────────────────────────────────────────────
    PluginAbout {
        repoUrl: "https://github.com/Tz-slayer/depthscape"
    }
}
