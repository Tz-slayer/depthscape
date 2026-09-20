import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets

// The reference Depthscape widget: a clock.
//
// It exists to prove the framework end to end, and to be the thing the subject
// visibly stands in front of — that occlusion is the entire point of the effect,
// so the demo has to make it obvious.
//
// A widget is a plain Item. The host positions it and the depth ordering does
// the rest; nothing here knows about layers, surfaces or the compositor.
Item {
    id: root

    // Injected by DepthWidgetHost from the widget's entry in widgets.json.
    // Not `abstract`: QML has no such concept, so the host documents the
    // contract and this is the demonstration of it.
    property var settings: ({})
    property bool editMode: false

    implicitWidth: clockText.implicitWidth + Theme.spacingL * 2
    implicitHeight: clockText.implicitHeight + Theme.spacingM * 2

    readonly property int displaySeconds: settings.showSeconds === true ? 1 : 0
    readonly property bool showDate: settings.showDate !== false

    property string timeText: ""

    function tick() {
        const now = new Date();
        const hours = String(now.getHours()).padStart(2, "0");
        const minutes = String(now.getMinutes()).padStart(2, "0");
        const seconds = String(now.getSeconds()).padStart(2, "0");
        timeText = root.displaySeconds === 1
            ? hours + ":" + minutes + ":" + seconds
            : hours + ":" + minutes;
        dateText.text = now.toLocaleDateString(Qt.locale(), Locale.LongFormat);
    }

    Timer {
        interval: root.displaySeconds === 1 ? 1000 : 15000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.tick()
    }

    // No background panel on purpose: this is a wallpaper, and a filled card
    // would read as a desktop widget rather than as something the subject stands
    // in front of. `editMode` is the exception — the host needs to show where the
    // widget is while it is being moved.
    Rectangle {
        anchors.fill: parent
        anchors.margins: -Theme.spacingS
        radius: Theme.cornerRadius
        color: root.editMode ? Theme.primary : "transparent"
        opacity: root.editMode ? 0.25 : 0
        border.color: root.editMode ? Theme.primary : "transparent"
        border.width: root.editMode ? 2 : 0
    }

    Column {
        anchors.centerIn: parent
        spacing: 0

        StyledText {
            id: clockText

            anchors.horizontalCenter: parent.horizontalCenter
            text: root.timeText
            color: "#f4f4f8"
            font.pixelSize: 72
            font.weight: Font.Light
            // A dark outline so the clock stays legible over both a bright moon
            // and a dark sky. Text has no stroke, so this is the usual QML
            // approach: draw the same string offset in all directions behind it.
            style: Text.Outline
            styleColor: Qt.rgba(0, 0, 0, 0.55)
        }

        StyledText {
            id: dateText

            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.showDate
            color: "#d8d8e0"
            font.pixelSize: 20
            style: Text.Outline
            styleColor: Qt.rgba(0, 0, 0, 0.55)
        }
    }
}
