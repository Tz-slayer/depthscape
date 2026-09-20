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
        description: "Draw the wallpaper foreground above desktop widgets"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "autoGenerate"
        label: "Generate automatically"
        description: "Rebuild the mask whenever the wallpaper or a parameter changes"
        defaultValue: true
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
        text: "Parallax"
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        topPadding: Theme.spacingL
    }

    ToggleSetting {
        settingKey: "parallaxEnabled"
        label: "Navigation parallax"
        description: "Shift the scene as you change workspace or column, so the foreground moves further than the background"
        defaultValue: true
    }

    SliderSetting {
        settingKey: "parallaxVerticalStep"
        label: "Vertical step"
        description: "Travel per workspace change, as a fraction of the screen height"
        defaultValue: 20
        minimum: 0
        maximum: 100
        unit: "‰"
    }

    SliderSetting {
        settingKey: "parallaxHorizontalStep"
        label: "Horizontal step"
        description: "Travel per column change, as a fraction of the screen width"
        defaultValue: 15
        minimum: 0
        maximum: 100
        unit: "‰"
    }

    SliderSetting {
        settingKey: "parallaxBackgroundRatio"
        label: "Background lag"
        description: "How far the background moves relative to the foreground. Lower values exaggerate the depth"
        defaultValue: 35
        minimum: 0
        maximum: 100
        unit: "%"
    }

    StyledText {
        width: parent.width
        text: "Parallax needs a compositor that reports navigation position. On niri the plugin reads it from the shell's own service, so no extra process is started."
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.WordWrap
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
