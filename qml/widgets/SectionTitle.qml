import QtQuick
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets

Item {
    id: root

    property string text: ""
    property string icon: ""

    width: parent ? parent.width : 0
    implicitHeight: titleRow.implicitHeight
    height: implicitHeight

    Row {
        id: titleRow
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Theme.spacingS

        DIcon {
            name: root.icon
            size: Theme.iconSizeMedium
            color: Theme.primary
            anchors.verticalCenter: parent.verticalCenter
            visible: root.icon !== ""
        }

        StyledText {
            text: root.text
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.DemiBold
            color: Theme.surfaceText
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
