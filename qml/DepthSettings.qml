import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root

    pluginId: "depthscape"

    // Actions are handed to the daemon through plugin data, which is the one
    // channel every surface already shares. The daemon consumes the key and
    // clears it immediately, so nothing transient is left on disk.
    function requestAction(action) {
        if (!pluginService)
            return;
        pluginService.savePluginData(pluginId, "action", action);
    }

    ToggleSetting {
        settingKey: "effectEnabled"
        label: "Depth effect"
        description: "Split the wallpaper and draw the subject in front of desktop widgets"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "widgetsEnabled"
        label: "Show Depthscape widgets"
        description: "Draw Depthscape's own widgets between the background and the subject, so the subject passes in front of them"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "autoGenerate"
        label: "Generate automatically"
        description: "Rebuild the images whenever the wallpaper or a parameter changes"
        defaultValue: true
    }

    StyledText {
        width: parent.width
        text: "Depthscape needs a niri layer rule to share the overview backdrop, otherwise every workspace card gets its own copy of the wallpaper. See the README. DMS's own wallpaper may be left on as a fallback while Depthscape's images decode."
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.WordWrap
        topPadding: Theme.spacingS
    }

    StyledText {
        width: parent.width
        text: "Occlusion"
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        topPadding: Theme.spacingL
    }

    SliderSetting {
        settingKey: "threshold"
        label: "Foreground threshold"
        description: "Lower values bring more of the scene in front of desktop widgets"
        defaultValue: 30
        minimum: 0
        maximum: 100
        unit: "%"
    }

    SliderSetting {
        settingKey: "feather"
        label: "Edge feather"
        description: "Width of the soft transition around the threshold"
        defaultValue: 8
        minimum: 0
        maximum: 50
        unit: "%"
    }

    StyledText {
        width: parent.width
        text: "Widgets"
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        topPadding: Theme.spacingL
    }

    StyledText {
        width: parent.width
        text: "Depthscape's widgets are placed from a layout file at "
            + "$XDG_DATA_HOME/depthscape/widgets.json. Each entry has a type, a "
            + "position in pixels from the top-left of the output, and a settings "
            + "object — for the clock, \u007b \"type\": \"clock\", \"x\": 1100, "
            + "\"y\": 900, \"settings\": \u007b \"showSeconds\": false \u007d \u007d. "
            + "Entries with no \"screen\" key appear on every output."
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.WordWrap
    }

    Row {
        width: parent.width
        spacing: Theme.spacingS

        DankButton {
            text: "Write example layout"
            iconName: "edit"
            onClicked: root.requestAction("exampleLayout")
        }
    }

    StyledText {
        width: parent.width
        text: "Model"
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        topPadding: Theme.spacingL
    }

    StyledText {
        width: parent.width
        text: "Depth Anything V2 Small runs locally. The 99 MB model is downloaded once from Hugging Face and verified against a pinned checksum."
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.WordWrap
    }

    Row {
        width: parent.width
        spacing: Theme.spacingS

        DankButton {
            text: "Install model"
            iconName: "download"
            onClicked: root.requestAction("install")
        }

        DankButton {
            text: "Regenerate"
            iconName: "refresh"
            onClicked: root.requestAction("generate")
        }

        DankButton {
            text: "Clear cache"
            iconName: "delete"
            onClicked: root.requestAction("clearCache")
        }
    }
}
