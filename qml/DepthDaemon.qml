import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

// Watches the wallpaper on every output, drives the Rust engine, and exposes
// the resulting masks to the rest of the plugin.
//
// The engine is a one-shot process: one invocation analyses one wallpaper and
// prints one JSON object. Jobs are serialised here rather than in the engine,
// because the shell is the only place that knows whether a queued job is still
// relevant by the time it would run.
PluginComponent {
    id: root

    // ---------------------------------------------------------------- settings

    readonly property bool effectEnabled: pluginData.effectEnabled ?? true
    readonly property bool autoGenerate: pluginData.autoGenerate ?? true
    readonly property int thresholdPercent: pluginData.threshold ?? 30
    readonly property int featherPercent: pluginData.feather ?? 8

    readonly property real threshold: thresholdPercent / 100
    readonly property real feather: featherPercent / 100

    // Changing either parameter invalidates the mask but not the depth map, so
    // this key is what decides whether a finished job is still worth applying.
    readonly property string parametersKey: threshold.toFixed(4) + ":" + feather.toFixed(4)

    // ------------------------------------------------------------------ engine

    readonly property string pluginDir: Qt.resolvedUrl("..").toString().replace(/^file:\/\//, "")

    property string enginePath: ""
    property string engineProblem: ""
    property bool modelReady: false
    property bool modelBusy: false

    // ----------------------------------------------------------------- outputs

    // screenName -> { wallpaper, state, maskPath, message, elapsedMs }
    // state: empty | pending | processing | ready | error
    property var outputs: ({})
    property var queue: []
    property var active: null
    property string lastStdout: ""
    property string lastStderr: ""

    // ------------------------------------------------------------------ helpers

    function wallpaperFor(screenName) {
        const path = SessionData.getMonitorWallpaper(screenName);
        if (!path || path.length === 0)
            return "";
        // DMS stores solid-colour wallpapers as "#rrggbb" in the same field.
        if (path.charAt(0) !== "/")
            return "";
        return path;
    }

    function maskPathFor(screenName) {
        const row = outputs[screenName];
        return row && row.state === "ready" ? row.maskPath : "";
    }

    function patchRow(screenName, patch) {
        const next = {};
        for (const key in outputs)
            next[key] = outputs[key];
        const merged = {};
        const existing = next[screenName] || {};
        for (const key in existing)
            merged[key] = existing[key];
        for (const key in patch)
            merged[key] = patch[key];
        next[screenName] = merged;
        outputs = next;
    }

    function shortError() {
        let message = (lastStderr || "").trim();
        if (message.length === 0)
            message = I18n.tr("The depth engine failed without reporting a reason.");
        if (message.length > 300)
            message = message.substring(0, 297) + "...";
        return message;
    }

    function publish() {
        if (!pluginService)
            return;
        const rows = [];
        for (const name in outputs) {
            const row = outputs[name];
            rows.push({
                "name": name,
                "state": row.state,
                "message": row.message || "",
                "elapsedMs": row.elapsedMs || 0,
                "cacheHit": row.cacheHit === true
            });
        }
        rows.sort((left, right) => left.name < right.name ? -1 : 1);
        pluginService.savePluginState(pluginId, "status", {
            "enginePath": enginePath,
            "engineProblem": engineProblem,
            "modelReady": modelReady,
            "modelBusy": modelBusy,
            "enabled": effectEnabled,
            "threshold": thresholdPercent,
            "feather": featherPercent,
            "outputs": rows
        });
    }

    // ------------------------------------------------------------------- queue

    function enqueue(screenName) {
        const row = outputs[screenName];
        if (!row || !row.wallpaper || !modelReady || enginePath === "" || !effectEnabled)
            return;
        const key = screenName + "\n" + row.wallpaper + "\n" + parametersKey;
        if (active && active.key === key)
            return;
        for (let index = 0; index < queue.length; index++) {
            if (queue[index].key === key)
                return;
        }
        const next = queue.slice();
        next.push({
            "screenName": screenName,
            "wallpaper": row.wallpaper,
            "parametersKey": parametersKey,
            "key": key
        });
        queue = next;
        pump();
    }

    function enqueueAll() {
        for (const name in outputs)
            enqueue(name);
    }

    function pump() {
        if (active !== null || !modelReady || enginePath === "")
            return;
        let job = null;
        const remaining = queue.slice();
        while (remaining.length > 0) {
            const candidate = remaining.shift();
            // Skip anything the user has already moved on from.
            const row = outputs[candidate.screenName];
            if (row && row.wallpaper === candidate.wallpaper && candidate.parametersKey === parametersKey) {
                job = candidate;
                break;
            }
        }
        queue = remaining;
        if (job === null) {
            publish();
            return;
        }

        active = job;
        patchRow(job.screenName, { "state": "processing", "message": "" });
        publish();

        lastStdout = "";
        lastStderr = "";
        analyzeProcess.command = [
            enginePath,
            "analyze",
            "--wallpaper", job.wallpaper,
            "--threshold", "" + threshold,
            "--feather", "" + feather
        ];
        analyzeProcess.running = true;
    }

    function finishJob(exitCode) {
        const job = active;
        active = null;
        if (job === null) {
            pump();
            return;
        }

        const currentWallpaper = wallpaperFor(job.screenName);
        const stale = job.parametersKey !== parametersKey || currentWallpaper !== job.wallpaper;
        if (stale) {
            // The result describes a wallpaper or a parameter set that no longer
            // applies. Drop it rather than flashing a stale mask on screen.
            if (currentWallpaper)
                enqueue(job.screenName);
            pump();
            return;
        }

        if (exitCode !== 0) {
            patchRow(job.screenName, { "state": "error", "maskPath": "", "message": shortError() });
            pump();
            return;
        }

        let parsed = null;
        try {
            parsed = JSON.parse(lastStdout.trim());
        } catch (error) {
            parsed = null;
        }
        if (!parsed || typeof parsed.maskPath !== "string" || parsed.maskPath === "") {
            patchRow(job.screenName, {
                "state": "error",
                "maskPath": "",
                "message": I18n.tr("The depth engine returned an unexpected result.")
            });
        } else {
            patchRow(job.screenName, {
                "state": "ready",
                "maskPath": parsed.maskPath,
                "message": "",
                "elapsedMs": parsed.elapsedMs || 0,
                "cacheHit": parsed.maskCacheHit === true
            });
        }
        pump();
    }

    // ------------------------------------------------------------------ syncing

    function syncOutputs() {
        const next = {};
        const screens = Quickshell.screens;
        for (let index = 0; index < screens.length; index++) {
            const name = screens[index].name;
            const wallpaper = wallpaperFor(name);
            const previous = outputs[name];
            const row = {};
            if (previous) {
                for (const key in previous)
                    row[key] = previous[key];
            }
            if (row.wallpaper !== wallpaper) {
                row.wallpaper = wallpaper;
                row.maskPath = "";
                row.message = "";
                row.elapsedMs = 0;
                row.cacheHit = false;
                row.state = wallpaper === "" ? "empty" : "pending";
            } else if (row.state === undefined) {
                row.state = wallpaper === "" ? "empty" : "pending";
            }
            next[name] = row;
        }
        outputs = next;
        if (autoGenerate)
            enqueueAll();
        publish();
    }

    function syncParameters() {
        // A parameter change invalidates every mask; drop them and rebuild.
        const next = {};
        for (const name in outputs) {
            const row = {};
            for (const key in outputs[name])
                row[key] = outputs[name][key];
            if (row.wallpaper) {
                row.state = "pending";
                row.maskPath = "";
            }
            next[name] = row;
        }
        outputs = next;
        queue = [];
        if (autoGenerate)
            enqueueAll();
        publish();
    }

    // ------------------------------------------------------------------ processes

    Process {
        id: resolveEngine

        running: true
        command: [
            "sh", "-c",
            'if [ -n "$DEPTHSCAPE_ENGINE" ] && [ -x "$DEPTHSCAPE_ENGINE" ]; then echo "$DEPTHSCAPE_ENGINE"; ' +
            'elif [ -x "$1/engine/target/release/depthscape-engine" ]; then echo "$1/engine/target/release/depthscape-engine"; ' +
            'elif [ -x "$1/engine/target/debug/depthscape-engine" ]; then echo "$1/engine/target/debug/depthscape-engine"; ' +
            'else command -v depthscape-engine; fi',
            "sh", root.pluginDir
        ]
        stdout: StdioCollector {
            onStreamFinished: {
                const found = text.trim();
                if (found.length > 0) {
                    root.enginePath = found;
                    root.engineProblem = "";
                    root.checkModel();
                } else {
                    root.engineProblem = I18n.tr("Build the engine with `cargo build --release` in the engine/ directory.");
                    root.publish();
                }
            }
        }
    }

    Process {
        id: statusProcess

        command: []
        stdout: StdioCollector {
            onStreamFinished: {
                let parsed = null;
                try {
                    parsed = JSON.parse(text.trim());
                } catch (error) {
                    parsed = null;
                }
                root.modelReady = parsed !== null && parsed.ready === true;
                root.modelBusy = false;
                if (!root.modelReady)
                    root.engineProblem = I18n.tr("Install the depth model from the plugin settings.");
                root.syncOutputs();
            }
        }
    }

    Process {
        id: setupProcess

        command: []
        onExited: exitCode => {
            root.modelBusy = false;
            if (exitCode !== 0) {
                root.engineProblem = root.shortError();
                root.publish();
                return;
            }
            root.checkModel();
        }
        stderr: StdioCollector {
            onStreamFinished: root.lastStderr = text
        }
    }

    Process {
        id: analyzeProcess

        command: []
        onExited: exitCode => root.finishJob(exitCode)
        stdout: StdioCollector {
            onStreamFinished: root.lastStdout = text
        }
        stderr: StdioCollector {
            onStreamFinished: root.lastStderr = text
        }
    }

    // ------------------------------------------------------------------ lifecycle

    function checkModel() {
        if (enginePath === "")
            return;
        statusProcess.command = [enginePath, "status"];
        statusProcess.running = true;
    }

    function installModel() {
        if (enginePath === "" || modelBusy)
            return;
        modelBusy = true;
        engineProblem = "";
        publish();
        lastStderr = "";
        setupProcess.command = [enginePath, "setup"];
        setupProcess.running = true;
    }

    function clearCache() {
        if (enginePath === "")
            return;
        for (const name in outputs)
            patchRow(name, { "state": "pending", "maskPath": "", "message": "" });
        queue = [];
        cacheProcess.command = [enginePath, "clear-cache"];
        cacheProcess.running = true;
    }

    // The settings page and the desktop widget cannot call into this daemon
    // directly, so actions travel through plugin data. Consume the key and
    // clear it so it is never replayed on the next shell start.
    function consumeAction() {
        if (!pluginService)
            return false;
        const action = pluginService.loadPluginData(pluginId, "action", "");
        if (!action || action === "")
            return false;
        pluginService.savePluginData(pluginId, "action", "");
        if (action === "install")
            installModel();
        else if (action === "generate")
            enqueueAll();
        else if (action === "clearCache")
            clearCache();
        return true;
    }

    Process {
        id: cacheProcess

        command: []
        onExited: exitCode => {
            if (exitCode !== 0) {
                root.engineProblem = root.shortError();
                root.publish();
                return;
            }
            root.syncOutputs();
        }
        stderr: StdioCollector {
            onStreamFinished: root.lastStderr = text
        }
    }

    IpcHandler {
        target: "depthscape"

        function install(): string {
            root.installModel();
            return "installing depth model";
        }

        function generate(): string {
            root.enqueueAll();
            return "queued " + root.queue.length + " job(s)";
        }

        function clearCache(): string {
            root.clearCache();
            return "clearing cache";
        }

        function raise(): string {
            root.raiseForeground();
            return "foreground re-mapped";
        }
    }

    Connections {
        target: SessionData

        function onWallpaperPathChanged() {
            root.syncOutputs();
        }

        function onMonitorWallpapersChanged() {
            root.syncOutputs();
        }

        function onPerMonitorWallpaperChanged() {
            root.syncOutputs();
        }
    }

    Connections {
        target: pluginService

        function onPluginDataChanged(changedId) {
            if (changedId !== root.pluginId)
                return;
            // A pending action is not a settings change: dispatching one must
            // not also invalidate every cached mask.
            if (root.consumeAction())
                return;
            root.syncParameters();
        }
    }

    Connections {
        target: Quickshell

        function onScreensChanged() {
            root.syncOutputs();
        }
    }

    // One foreground surface per output. Placed here rather than in a desktop
    // surface because the framework wraps desktop widgets in its own container;
    // the layer we need is a full-screen, click-through overlay, which only a
    // self-created PanelWindow can provide.
    //
    // The Loader exists so the surfaces can be destroyed and re-created, which
    // is the only way to change their position within the `bottom` layer: layer
    // surfaces stack by map order, and there is no "raise" request in
    // wlr-layer-shell. See raiseForeground().
    Loader {
        id: foregroundLoader

        active: true
        sourceComponent: Component {
            Variants {
                model: Quickshell.screens

                delegate: DepthForeground {
                    required property var modelData

                    targetScreen: modelData
                    wallpaperPath: root.effectEnabled ? root.wallpaperFor(modelData.name) : ""
                    maskPath: root.effectEnabled ? root.maskPathFor(modelData.name) : ""
                }
            }
        }
    }

    // Re-mapping is not instantaneous: the compositor has to process the unmap
    // before the new surface can claim the top of the layer. DMS waits 32ms in
    // its own equivalent (DesktopWidgetLayer.qml `rebuildApply`); match that.
    Timer {
        id: remapTimer

        interval: 32
        repeat: false
        onTriggered: foregroundLoader.active = true
    }

    function raiseForeground() {
        foregroundLoader.active = false;
        remapTimer.restart();
    }

    // DMS rebuilds every desktop widget surface when the instance list changes,
    // which leaves those surfaces mapped after ours and therefore in front.
    // Wait out DMS's own debounce (150ms) plus its 32ms remap before answering,
    // so our surfaces are the last ones mapped.
    Timer {
        id: widgetRebuildTimer

        interval: 400
        repeat: false
        onTriggered: root.raiseForeground()
    }

    Connections {
        target: SettingsData

        function onDesktopWidgetInstancesChanged() {
            widgetRebuildTimer.restart();
        }
    }

    // The instance list is not the only thing that makes DMS rebuild its
    // desktop widget surfaces. `DesktopWidgetLayer` also rebuilds once a
    // plugin's desktop component finishes loading (`pluginReadyKey`, which is
    // derived from `PluginService.pluginDesktopComponents`). At shell startup
    // that happens *after* we map the foreground, so the widgets end up in
    // front of us until something else triggers a raise. Observe the same
    // property DMS does.
    Connections {
        target: PluginService

        function onPluginDesktopComponentsChanged() {
            widgetRebuildTimer.restart();
        }
    }

    // Startup safety net. The signal above can fire before this daemon is
    // constructed, and a cold engine means the first mask can land after it
    // too. One delayed re-assert covers both orderings: if the foreground is
    // not mapped yet the call is a no-op, and the surface maps last (therefore
    // on top) whenever the mask does arrive.
    Timer {
        interval: 3000
        running: true
        repeat: false
        onTriggered: root.raiseForeground()
    }

    Component.onCompleted: {
        console.info("Depthscape: daemon started");
    }

    Component.onDestruction: {
        console.info("Depthscape: daemon stopped");
    }
}
