import QtQuick
import qs.Common
import qs.Widgets

StyledRect {
    id: root
    width: parent ? parent.width : 500
    implicitWidth: width
    implicitHeight: contentColumn.implicitHeight + (Theme.spacingL * 2)
    height: implicitHeight
    radius: Theme.cornerRadius
    color: Theme.surfaceContainer

    default property alias content: contentColumn.data
    property alias spacing: contentColumn.spacing

    // Called by PluginSettings.onPluginServiceChanged to reload nested settings
    function loadValue() {
        for (let i = 0; i < contentColumn.children.length; i++) {
            const child = contentColumn.children[i];
            if (child.loadValue) {
                child.loadValue();
            }
        }
    }

    Column {
        id: contentColumn
        width: parent ? (parent.width - (Theme.spacingL * 2)) : 460
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: Theme.spacingL
        spacing: Theme.spacingM
    }
}
