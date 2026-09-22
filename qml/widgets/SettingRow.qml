import QtQuick
import qs.Common
import qs.Widgets

// Shared chrome for one settings row, matching the `*SettingPlus` widgets the
// rest of this settings page is built from:
//
//   * a hover highlight behind the row (the sibling rows use -12/-6 margins)
//   * a label with an info tooltip carrying the description, never inline text
//   * a reset affordance that only appears once the value differs from its
//     default
//   * a full-width control area below the label, plus a trailing slot in the
//     label row itself for a switch
//
// The `*SettingPlus` files in this directory are vendored copies of DMS's own
// widgets and are kept close to upstream, so they cannot share this file.
// Everything this plugin writes itself goes through here.
Item {
    id: root

    property string label: ""
    property string description: ""
    property bool isDirty: false
    property bool showReset: true
    // Rows that toggle a value make the whole row a click target, like
    // ToggleSettingPlus does.
    property bool clickable: false
    // Controls that belong in the label row, right-aligned (a switch).
    property alias trailingData: trailingRow.data
    // Controls that belong below the label row, full width (a dropdown, a
    // status line, a button).
    default property alias contentData: contentColumn.data

    signal resetRequested()
    signal clicked()

    width: parent.width
    implicitHeight: layout.implicitHeight
    opacity: enabled ? 1 : 0.5
    Behavior on opacity { NumberAnimation { duration: Theme.shortDuration } }

    HoverHandler { id: hoverHandler }

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: -12
        anchors.rightMargin: -12
        anchors.topMargin: -6
        anchors.bottomMargin: -6
        radius: Theme.cornerRadius
        color: hoverHandler.hovered ? Theme.withAlpha(Theme.primary, 0.08) : "transparent"
        Behavior on color { ColorAnimation { duration: 150 } }
    }

    MouseArea {
        anchors.fill: parent
        anchors.leftMargin: -12
        anchors.rightMargin: -12
        anchors.topMargin: -6
        anchors.bottomMargin: -6
        enabled: root.clickable && root.enabled
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }

    component ResetAffordance: Item {
        id: reset
        width: 28
        height: 28
        signal clicked()

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
            onClicked: reset.clicked()
        }
    }

    Column {
        id: layout
        anchors.fill: parent
        spacing: Theme.spacingXS

        Item {
            width: parent.width
            height: 32

            Row {
                anchors.left: parent.left
                anchors.right: resetButton.visible ? resetButton.left : (trailingRow.width > 0 ? trailingRow.left : parent.right)
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
                        onEntered: tooltip.show(root.description, infoIcon)
                        onExited: tooltip.hide()
                    }
                }
            }

            Row {
                id: trailingRow
                anchors.right: resetButton.visible ? resetButton.left : parent.right
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingS
            }

            ResetAffordance {
                id: resetButton
                visible: root.showReset && root.isDirty
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.resetRequested()
            }

            DankTooltipV2 { id: tooltip }
        }

        Column {
            id: contentColumn
            width: parent.width
            spacing: Theme.spacingXS
        }
    }
}
