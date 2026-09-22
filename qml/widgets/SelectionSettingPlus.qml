import QtQuick
import qs.Common
import qs.Widgets

Item {
    id: root

    required property string settingKey
    required property string label
    property string description: ""
    required property var options
    property string defaultValue: ""
    property string value: defaultValue
    property bool isInitialized: false

    width: parent ? parent.width : 500
    implicitWidth: width
    implicitHeight: layoutColumn.implicitHeight
    height: implicitHeight
    
    // Dynamic Opacity for disabled state (Original DMS feature)
    opacity: enabled ? 1 : 0.5
    Behavior on opacity { NumberAnimation { duration: Theme.shortDuration } }

    readonly property bool isDirty: String(value) !== String(defaultValue)

    function resetToDefault() {
        console.log(`[SelectionSettingPlus] Resetting ${settingKey}`);
        value = defaultValue;
        // The dropdown only speaks labels, so the reset has to go through the
        // same map the binding uses. Writing the raw value worked only while
        // every default happened to be truthy.
        dropdown.currentValue = root.valueToLabel[defaultValue] !== undefined
            ? root.valueToLabel[defaultValue] : defaultValue;
    }

    // See ToggleSettingPlus.revertToDefault. The dropdown copy has to be moved
    // through the label map as well, and silently: assigning `value` alone
    // leaves `dropdown.currentValue` showing the old variant.
    function revertToDefault() {
        isInitialized = false;
        value = defaultValue;
        dropdown.currentValue = root.valueToLabel[defaultValue] !== undefined
            ? root.valueToLabel[defaultValue] : defaultValue;
        const settings = findSettings();
        if (settings)
            settings.saveValue(settingKey, defaultValue);
        isInitialized = true;
    }

    function loadValue() {
        const settings = findSettings();
        if (settings && settings.pluginService) {
            value = settings.loadValue(settingKey, defaultValue);
            isInitialized = true;
        }
    }

    Component.onCompleted: Qt.callLater(loadValue)

    readonly property var optionLabels: {
        const labels = []
        for (let i = 0; i < options.length; i++) {
            labels.push(options[i].label || options[i])
        }
        return labels
    }

    readonly property var valueToLabel: {
        const map = {}
        for (let i = 0; i < options.length; i++) {
            const opt = options[i]
            if (typeof opt === 'object') map[opt.value] = opt.label
            else map[opt] = opt
        }
        return map
    }

    readonly property var labelToValue: {
        const map = {}
        for (let i = 0; i < options.length; i++) {
            const opt = options[i]
            if (typeof opt === 'object') map[opt.label] = opt.value
            else map[opt] = opt
        }
        return map
    }

    // `labelToValue[label] ?? label` and not `|| label`: an option may legitimately
    // carry a falsy value, and `||` would then persist the option's display label
    // ("Follow focused output") as the setting. `hasOwnProperty` keeps the
    // lookup exact, so a label that happens to collide with Object.prototype
    // ("constructor") cannot resolve to something that was never offered.
    function valueForLabel(label) {
        return Object.prototype.hasOwnProperty.call(labelToValue, label) ? labelToValue[label] : label
    }

    onValueChanged: {
        const settings = findSettings()
        if (settings) settings.saveValue(settingKey, value)
    }

    function findSettings() {
        let item = parent
        while (item) {
            if (item.saveValue !== undefined && item.loadValue !== undefined) return item
            item = item.parent
        }
        return null
    }

    HoverHandler {
        id: rootHoverHandler
    }

    Rectangle {
        id: highlightBg
        anchors.fill: parent
        anchors.leftMargin: -12
        anchors.rightMargin: -12
        anchors.topMargin: -6
        anchors.bottomMargin: -6
        radius: Theme.cornerRadius
        color: rootHoverHandler.hovered ? Theme.withAlpha(Theme.primary, 0.08) : "transparent"
        Behavior on color { ColorAnimation { duration: 150 } }
    }

    Column {
        id: layoutColumn
        width: parent.width
        spacing: Theme.spacingXS

        // ── Label Row ─────────────────────────────────────────────────────────
        Item {
            width: parent.width
            height: 32

            Row {
                anchors.left: parent.left
                anchors.right: individualReset.visible ? individualReset.left : parent.right
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                StyledText {
                    text: root.label
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    width: Math.min(implicitWidth, parent.width - (infoIcon.visible ? 20 : 0))
                }

                DankIcon {
                    id: infoIcon
                    name: "info"
                    size: 16
                    color: Theme.primary
                    visible: root.description !== ""
                    anchors.verticalCenter: parent.verticalCenter
                    opacity: 0.6
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: sharedTooltip.show(root.description, infoIcon)
                        onExited: sharedTooltip.hide()
                    }
                }
            }

            Item {
                id: individualReset
                width: 28; height: 28
                visible: root.isDirty
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    anchors.fill: parent
                    radius: 14
                    color: resetArea.containsMouse ? Theme.primaryHoverLight : "transparent"
                }
                DankIcon {
                    name: "restart_alt"
                    size: 16
                    color: Theme.primary
                    anchors.centerIn: parent
                    opacity: 0.8
                }
                MouseArea {
                    id: resetArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.resetToDefault()
                }
            }
        }

        // ── Dropdown (Full Width) ─────────────────────────────────────────────
        DankDropdown {
            id: dropdown
            width: parent.width
            compactMode: true
            currentValue: root.valueToLabel[root.value] || root.value
            options: root.optionLabels
            onValueChanged: newValue => {
                root.value = root.valueForLabel(newValue)
            }
        }

        DankTooltipV2 { id: sharedTooltip }
    }
}
