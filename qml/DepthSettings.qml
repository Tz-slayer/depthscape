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
        text: "Parallax"
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        topPadding: Theme.spacingL
    }

    StyledText {
        width: parent.width
        text: "Moving between workspaces slides the scene: the subject and the background move in opposite directions, which reads as depth. It is a cumulative offset, not a per-key animation — stepping away and stepping back returns the scene to exactly where it started. Widgets never move; they are the thing the subject stands in front of, so they are the reference frame the depth is measured against."
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.WordWrap
        topPadding: Theme.spacingS
    }

    ToggleSetting {
        settingKey: "parallaxEnabled"
        label: "Navigation parallax"
        description: "Slide the foreground and background as you move between workspaces and columns"
        defaultValue: true
    }

    SliderSetting {
        settingKey: "parallaxStepVertical"
        label: "First vertical step"
        description: "How far the scene moves on the first workspace step, as a percentage of the screen height"
        defaultValue: 60
        minimum: 0
        maximum: 200
        unit: "‰"
    }

    SliderSetting {
        settingKey: "parallaxStepHorizontal"
        label: "First horizontal step"
        description: "How far the scene moves on the first column step, as a percentage of the screen width"
        defaultValue: 80
        minimum: 0
        maximum: 200
        unit: "‰"
    }

    SliderSetting {
        settingKey: "parallaxTravel"
        label: "Total travel"
        description: "The distance the scene asymptotically approaches, as a percentage of the longer screen edge. Each step moves less than the one before, so this is a limit rather than a distance actually reached"
        defaultValue: 12
        minimum: 0
        maximum: 30
        unit: "%"
    }

    SliderSetting {
        settingKey: "parallaxBackgroundRatio"
        label: "Background travel"
        description: "Background movement as a fraction of the foreground's. Smaller values deepen the effect; zero pins the background and makes the subject look pasted on"
        defaultValue: 35
        minimum: 0
        maximum: 100
        unit: "%"
    }

    ToggleSetting {
        settingKey: "parallaxInverted"
        label: "Invert direction"
        description: "Step down in the workspace stack and the scene moves down instead of up"
        defaultValue: false
    }

    SliderSetting {
        settingKey: "parallaxDuration"
        label: "Motion smoothing"
        description: "Time constant of the smoothing applied to the offset. Higher is calmer and more floaty, lower follows the keyboard more tightly"
        defaultValue: 350
        minimum: 0
        maximum: 1000
        unit: "ms"
    }

    StyledText {
        width: parent.width
        text: "Overview"
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        topPadding: Theme.spacingL
    }

    StyledText {
        width: parent.width
        text: "In the overview all three layers stay mapped and fade together. Unmapping the subject instead would leave the overview cleaner, but it pops: the compositor has to rebuild the backdrop in one frame."
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.WordWrap
        topPadding: Theme.spacingS
    }

    ToggleSetting {
        settingKey: "fadeInOverview"
        label: "Fade in the overview"
        description: "Dim the subject and widgets while the overview is open"
        defaultValue: true
    }

    SliderSetting {
        settingKey: "overviewOpacity"
        label: "Overview opacity"
        description: "How much of the layers is left while the overview is open"
        defaultValue: 120
        minimum: 0
        maximum: 1000
        unit: "‰"
    }

    SliderSetting {
        settingKey: "overviewFadeDuration"
        label: "Fade duration"
        description: "Cross-fade time when the overview opens or closes"
        defaultValue: 240
        minimum: 0
        maximum: 1000
        unit: "ms"
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
