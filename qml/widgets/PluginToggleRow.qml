import QtQuick
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets

Item {
    id: root

    required property string settingKey
    required property string label
    property bool defaultValue: false
    property bool value: defaultValue
    readonly property bool modified: value !== defaultValue

    width: parent ? parent.width : 0
    implicitHeight: Math.max(Theme.iconButtonSize, labelText.implicitHeight)
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

    function loadValue() {
        const settings = findSettings();
        if (settings && settings.pluginService && settingKey !== "") {
            const loaded = settings.loadValue(settingKey, defaultValue);
            value = Boolean(loaded);
        } else {
            value = defaultValue;
        }
    }

    function commitValue(nextValue) {
        const next = Boolean(nextValue);
        value = next;
        const settings = findSettings();
        if (settings && settingKey !== "")
            settings.saveValue(settingKey, next);
    }

    function resetToDefault() {
        commitValue(defaultValue);
    }

    onSettingKeyChanged: loadValue()
    onDefaultValueChanged: loadValue()
    Component.onCompleted: Qt.callLater(loadValue)

    MouseArea {
        anchors.left: parent.left
        anchors.right: trailingRow.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        enabled: root.enabled
        cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.commitValue(!root.value)
    }

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

        DToggle {
            anchors.verticalCenter: parent.verticalCenter
            hideText: true
            text: root.label
            checked: root.value
            enabled: root.enabled
            onToggled: isChecked => root.commitValue(isChecked)
        }
    }
}
