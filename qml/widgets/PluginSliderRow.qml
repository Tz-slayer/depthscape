import QtQuick
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets

Column {
    id: root

    required property string settingKey
    required property string label
    property int defaultValue: 0
    property int value: defaultValue
    property int minimum: 0
    property int maximum: 100
    property int step: 1
    property string unit: ""
    readonly property bool modified: value !== defaultValue

    width: parent ? parent.width : 0
    spacing: Theme.spacingS
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
            const raw = Number(settings.loadValue(settingKey, defaultValue));
            value = Number.isFinite(raw) ? Math.round(raw) : defaultValue;
        } else {
            value = defaultValue;
        }
    }

    function commitValue(nextValue) {
        const clamped = Math.max(minimum, Math.min(maximum, Math.round(nextValue)));
        value = clamped;
        const settings = findSettings();
        if (settings && settingKey !== "")
            settings.saveValue(settingKey, clamped);
    }

    function resetToDefault() {
        commitValue(defaultValue);
    }

    function nudge(direction) {
        const stepAmt = Math.max(1, step);
        const next = Math.max(minimum, Math.min(maximum, slider.value + direction * stepAmt));
        if (next === value)
            return;
        commitValue(next);
    }

    onValueChanged: {
        if (slider.value !== value)
            slider.value = value;
    }

    onSettingKeyChanged: loadValue()
    onDefaultValueChanged: loadValue()
    Component.onCompleted: Qt.callLater(loadValue)

    Item {
        width: parent.width
        height: Math.max(Theme.iconButtonSize, labelText.implicitHeight)

        StyledText {
            id: labelText
            anchors.left: parent.left
            anchors.right: resetBtn.visible ? resetBtn.left : parent.right
            anchors.rightMargin: resetBtn.visible ? Theme.spacingS : 0
            anchors.verticalCenter: parent.verticalCenter
            text: root.label
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Theme.fontWeightMedium
            color: Theme.surfaceText
            elide: Text.ElideRight
        }

        DActionButton {
            id: resetBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            buttonSize: Theme.iconButtonSize
            iconName: "restart_alt"
            iconSize: Theme.iconSizeMedium
            iconColor: Theme.surfaceVariantText
            tooltipText: I18n.tr("Reset to default")
            Accessible.name: I18n.tr("Reset to default")
            visible: root.modified
            enabled: root.enabled && root.modified
            onClicked: root.resetToDefault()
        }
    }

    Row {
        width: parent.width
        spacing: Theme.spacingS

        DActionButton {
            buttonSize: Theme.iconButtonSize
            iconName: "remove"
            iconSize: Theme.iconSizeMedium
            iconColor: Theme.surfaceVariantText
            Accessible.name: I18n.tr("Decrease")
            enabled: root.enabled && slider.value > slider.minimum
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.nudge(-1)
        }

        DSlider {
            id: slider
            size: "s"
            width: Math.max(0, parent.width - (Theme.iconButtonSize + parent.spacing) * 2)
            anchors.verticalCenter: parent.verticalCenter
            minimum: root.minimum
            maximum: root.maximum
            step: root.step
            unit: root.unit
            enabled: root.enabled
            wheelEnabled: false
            upDownKeysStep: false
            Accessible.name: root.label
            Component.onCompleted: value = root.value
            onSliderValueChanged: newValue => root.commitValue(newValue)
        }

        DActionButton {
            buttonSize: Theme.iconButtonSize
            iconName: "add"
            iconSize: Theme.iconSizeMedium
            iconColor: Theme.surfaceVariantText
            Accessible.name: I18n.tr("Increase")
            enabled: root.enabled && slider.value < slider.maximum
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.nudge(1)
        }
    }
}
