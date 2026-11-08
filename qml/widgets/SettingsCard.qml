import QtQuick
import qs.Common
import qs.Widgets

StyledRect {
    id: root

    width: parent ? parent.width : 500
    implicitWidth: width
    implicitHeight: visible ? (contentColumn.implicitHeight + (Theme.spacingL * 2)) : 0
    height: implicitHeight
    radius: Theme.cornerRadius
    color: Theme.surfaceContainerHigh
    border.color: Theme.outlineVariant
    border.width: 1

    default property alias content: contentColumn.data
    property alias spacing: contentColumn.spacing

    function loadValue() {
        for (let i = 0; i < contentColumn.children.length; i++) {
            const child = contentColumn.children[i];
            if (child.loadValue)
                child.loadValue();
        }
    }

    Column {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Theme.spacingL
        spacing: Theme.spacingM
    }
}
