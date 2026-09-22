import QtQuick
import qs.Common
import qs.Widgets

// A compact inline status pill: a state icon, a short label and optional
// detail text on one rounded surface. Used by the settings page for facts that
// are read-only (model installed?, daemon busy?) where a full settings row
// would overstate their importance.
StyledRect {
    id: root

    property string icon: "info"
    property color iconColor: Theme.primary
    property string text: ""
    property string detail: ""
    // Draws the icon in a tight circular well when the state is worth noticing
    // (busy / missing), and leaves it bare for neutral states.
    property bool emphasized: false

    width: parent ? parent.width : 400
    implicitWidth: width
    implicitHeight: contentRow.implicitHeight + (Theme.spacingS * 2)
    height: implicitHeight
    radius: Theme.cornerRadius
    color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.6)

    Row {
        id: contentRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.spacingS
        anchors.rightMargin: Theme.spacingS
        spacing: Theme.spacingS

        Item {
            id: iconWell
            width: 20
            height: 20
            anchors.verticalCenter: parent.verticalCenter

            Rectangle {
                anchors.fill: parent
                radius: height / 2
                visible: root.emphasized
                color: Theme.withAlpha(root.iconColor, 0.16)
            }

            DankIcon {
                name: root.icon
                size: 16
                color: root.iconColor
                anchors.centerIn: parent
            }
        }

        StyledText {
            id: labelText
            text: root.text
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: Theme.surfaceText
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            // Lets the detail text win the space fight when the row is narrow.
            width: Math.min(implicitWidth, parent.width - iconWell.width - (detailText.visible ? detailText.width + parent.spacing * 2 : 0))
        }

        StyledText {
            id: detailText
            text: root.detail
            visible: text !== ""
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignRight
            width: parent.width - iconWell.width - parent.spacing * 3 - labelText.width
        }
    }
}
