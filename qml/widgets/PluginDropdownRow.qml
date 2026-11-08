import QtQuick
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets

Item {
    id: root

    required property string settingKey
    required property string label
    property string defaultValue: ""
    property string value: defaultValue
    property int dropdownWidth: 240
    property alias options: dropdown.options
    property alias optionValues: dropdown.optionValues
    property alias optionIcons: dropdown.optionIcons
    readonly property bool modified: value !== defaultValue

    width: parent ? parent.width : 0
    implicitHeight: Math.max(Theme.iconButtonSize, dropdown.implicitHeight, labelText.implicitHeight)
    height: implicitHeight
    opacity: enabled ? 1 : 0.38

    Behavior on opacity {
        NumberAnimation {
            duration: Theme.shortDuration
        }
    }

    function findSettings() {
        let p = root.parent;
        while (p) {
            if (p.saveValue !== undefined && p.loadValue !== undefined)
                return p;
            p = p.parent;
        }
        return null;
    }

    function normalizeValue(candidate) {
        const keys = (Array.isArray(dropdown.optionValues) && dropdown.optionValues.length > 0)
            ? dropdown.optionValues
            : (Array.isArray(dropdown.options) ? dropdown.options : []);
        if (keys.length === 0)
            return candidate !== undefined && candidate !== null && candidate !== "" ? String(candidate) : defaultValue;
        const str = String(candidate ?? "");
        if (keys.indexOf(str) >= 0)
            return str;
        if (keys.indexOf(defaultValue) >= 0)
            return defaultValue;
        return String(keys[0]);
    }

    function loadValue() {
        const settings = findSettings();
        if (settings && settings.pluginService && settingKey !== "") {
            const raw = settings.loadValue(settingKey, defaultValue);
            value = normalizeValue(raw);
        } else {
            value = normalizeValue(defaultValue);
        }
    }

    function commitValue(nextValue) {
        const next = normalizeValue(nextValue);
        value = next;
        const settings = findSettings();
        if (settings && settingKey !== "")
            settings.saveValue(settingKey, next);
    }

    function resetToDefault() {
        commitValue(defaultValue);
    }

    onValueChanged: {
        if (dropdown.currentValue !== value)
            dropdown.currentValue = value;
    }

    onSettingKeyChanged: loadValue()
    onDefaultValueChanged: loadValue()
    onOptionsChanged: loadValue()
    onOptionValuesChanged: loadValue()
    Component.onCompleted: Qt.callLater(loadValue)

    StyledText {
        id: labelText
        anchors.left: parent.left
        anchors.right: trailingRow.left
        anchors.rightMargin: Theme.spacingM
        anchors.verticalCenter: parent.verticalCenter
        text: root.label
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Theme.fontWeightMedium
        color: Theme.surfaceText
        elide: Text.ElideRight
    }

    Row {
        id: trailingRow
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingS

        DActionButton {
            buttonSize: Theme.iconButtonSize
            iconName: "restart_alt"
            iconSize: Theme.iconSizeMedium
            iconColor: Theme.surfaceVariantText
            tooltipText: I18n.tr("Reset to default")
            Accessible.name: I18n.tr("Reset to default")
            visible: root.modified
            enabled: root.enabled && root.modified
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.resetToDefault()
        }

        DDropdown {
            id: dropdown
            anchors.verticalCenter: parent.verticalCenter
            downKeyOpens: false
            backgroundColor: Theme.chipSurfaceNested
            enabled: root.enabled
            Accessible.name: root.label
            dropdownWidth: root.dropdownWidth
            width: root.width > 0
                ? Math.min(root.dropdownWidth, Math.max(140, Math.floor(root.width * 0.62)))
                : root.dropdownWidth
            Component.onCompleted: currentValue = root.value
            onValueChanged: selected => root.commitValue(selected)
        }
    }
}
