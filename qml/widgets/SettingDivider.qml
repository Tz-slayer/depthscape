import QtQuick
import qs.Common
import qs.Widgets

// A labelled sub-heading that introduces a group of dependent rows inside a
// SettingsCard. Rows under a divider are visually subordinate: the label is
// smaller and non-interactive, and the divider itself carries the short
// explanation of *why* the group only applies when the parent toggle is on.
Item {
    id: root

    property string text: ""
    property string description: ""
    // Reserved for callers that want to hide the whole group (divider included)
    // together with its rows.
    property bool groupActive: true

    width: parent ? parent.width : 400
    implicitWidth: width
    implicitHeight: dividerColumn.implicitHeight
    height: implicitHeight

    Column {
        id: dividerColumn
        width: parent.width
        spacing: Theme.spacingXS

        // Hairline above the caption separates the dependent group from the
        // row that governs it.
        Rectangle {
            width: parent.width
            height: 1
            color: Theme.withAlpha(Theme.surfaceVariantText, 0.18)
        }

        Row {
            width: parent.width
            spacing: Theme.spacingXS
            topPadding: Theme.spacingXS

            StyledText {
                text: root.text
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.DemiBold
                color: root.groupActive ? Theme.surfaceVariantText : Theme.withAlpha(Theme.surfaceVariantText, 0.5)
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                maximumLineCount: 1
                width: Math.min(implicitWidth, parent.width - (infoIcon.visible ? 20 : 0))
            }

            DankIcon {
                id: infoIcon
                name: "info"
                size: 14
                color: Theme.primary
                visible: root.description !== ""
                anchors.verticalCenter: parent.verticalCenter
                opacity: root.groupActive ? 0.5 : 0.25

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: tooltip.show(root.description, infoIcon)
                    onExited: tooltip.hide()
                }
            }

            DankTooltipV2 { id: tooltip }
        }
    }
}
