import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Modules.Plugins

// Watches the wallpaper on every output, drives the Rust engine, and exposes
// the resulting images to the rest of the plugin.
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
    readonly property bool widgetsEnabled: pluginData.widgetsEnabled ?? true
    readonly property int thresholdPercent: pluginData.threshold ?? 30
    readonly property int featherPercent: pluginData.feather ?? 8

    readonly property real threshold: thresholdPercent / 100
    readonly property real feather: featherPercent / 100

    // DMS's own overview-blur preference. Our background is the shared backdrop,
    // so it has to follow the same setting DMS applies to its wallpaper or the
    // overview would look different with the plugin on than off. Read
    // defensively: a plugin's view of DMS's singletons is not always complete
    // (see the note on `inOverview`), and a missing property should mean "no
    // blur" rather than a binding error on every frame.
    readonly property bool blurInOverview: SettingsData.blurWallpaperOnOverview ?? true

    // Changing either parameter invalidates the image pair but not the depth
    // map, so this key is what decides whether a finished job is still worth
    // applying.
    readonly property string parametersKey: threshold.toFixed(4) + ":" + feather.toFixed(4)

    // ------------------------------------------------------------------ engine

    readonly property string pluginDir: Qt.resolvedUrl("..").toString().replace(/^file:\/\//, "")

    property string enginePath: ""
    property string engineProblem: ""
    property bool modelReady: false
    property bool modelBusy: false

    // ------------------------------------------------------------------ layout

    /// Where the widget host reads its layout from.
    ///
    /// A separate file from DMS's plugin data on purpose — see DepthWidgetHost.
    /// The root is whatever `$DEPTHSCAPE_DATA_DIR` / `$XDG_DATA_HOME` resolve to,
    /// which the engine also uses, so the two stay in step without either having
    /// to tell the other where it is.
    property string dataRoot: ""
    readonly property string layoutPath: dataRoot === "" ? "" : dataRoot + "/widgets.json"

    // ----------------------------------------------------------------- outputs

    // screenName -> { wallpaper, state, foregroundPath, backgroundPath,
    //                 message, elapsedMs, cacheHit }
    // state: empty | pending | processing | ready | error
    property var outputs: ({})
    property var queue: []
    property var active: null
    property string lastStdout: ""
    property string lastStderr: ""

    // One entry per output, holding the three surface windows for that output.
    // The delegates register themselves; see the composition section below.
    property var surfaceGroups: []

    // ------------------------------------------------------------------ helpers

    function wallpaperFor(screenName) {
        const path = SessionData.getMonitorWallpaper(screenName);
        if (!path || path.length === 0)
            return "";
        // DMS stores solid-colour wallpapers as "#rrggbb" in the same field.
        // There is nothing to analyse, and the user is presumably relying on
        // that flat colour as their background.
        if (path.charAt(0) !== "/")
            return "";
        return path;
    }

    function foregroundFor(screenName) {
        const row = outputs[screenName];
        return row && row.state === "ready" ? row.foregroundPath : "";
    }

    function backgroundFor(screenName) {
        const row = outputs[screenName];
        return row && row.state === "ready" ? row.backgroundPath : "";
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
            // applies. Drop it rather than flashing a stale pair on screen.
            if (currentWallpaper)
                enqueue(job.screenName);
            pump();
            return;
        }

        if (exitCode !== 0) {
            patchRow(job.screenName, {
                "state": "error",
                "foregroundPath": "",
                "backgroundPath": "",
                "message": shortError()
            });
            pump();
            return;
        }

        let parsed = null;
        try {
            parsed = JSON.parse(lastStdout.trim());
        } catch (error) {
            parsed = null;
        }
        const valid = parsed
            && typeof parsed.foregroundPath === "string" && parsed.foregroundPath !== ""
            && typeof parsed.backgroundPath === "string" && parsed.backgroundPath !== "";
        if (!valid) {
            patchRow(job.screenName, {
                "state": "error",
                "foregroundPath": "",
                "backgroundPath": "",
                "message": I18n.tr("The depth engine returned an unexpected result.")
            });
        } else {
            patchRow(job.screenName, {
                "state": "ready",
                "foregroundPath": parsed.foregroundPath,
                "backgroundPath": parsed.backgroundPath,
                "message": "",
                "elapsedMs": parsed.elapsedMs || 0,
                "cacheHit": parsed.splitCacheHit === true
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
                row.foregroundPath = "";
                row.backgroundPath = "";
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
        // A parameter change invalidates every pair; drop them and rebuild.
        const next = {};
        for (const name in outputs) {
            const row = {};
            for (const key in outputs[name])
                row[key] = outputs[name][key];
            if (row.wallpaper) {
                row.state = "pending";
                row.foregroundPath = "";
                row.backgroundPath = "";
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

    // The engine reports its own data directory, which is where widgets.json
    // lives. Asking the engine rather than duplicating the `$DEPTHSCAPE_DATA_DIR`
    // / `$XDG_DATA_HOME` resolution here keeps one definition of "our data
    // directory" instead of two that can disagree.
    Process {
        id: resolveDataRoot

        running: true
        command: ["sh", "-c", 'if [ -n "$DEPTHSCAPE_DATA_DIR" ]; then echo "$DEPTHSCAPE_DATA_DIR"; ' +
            'elif [ -n "$XDG_DATA_HOME" ]; then echo "$XDG_DATA_HOME/depthscape"; ' +
            'else echo "$HOME/.local/share/depthscape"; fi']
        stdout: StdioCollector {
            onStreamFinished: {
                const found = text.trim();
                if (found.length > 0)
                    root.dataRoot = found;
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

    // ------------------------------------------------------------------ overview

    // Overview state comes from the compositor rather than from `NiriService`.
    //
    // `NiriService.inOverview` is the natural source — DMS's own wallpaper uses
    // it — but a plugin's daemon does not get a usable NiriService: the service
    // tree a plugin sees is reduced, and the property reads as a constant false
    // rather than failing loudly. Polling `niri msg` is cheap by comparison: one
    // short-lived process every few hundred milliseconds, and none at all once
    // the state stops changing in a way anyone can see.
    //
    // WHAT THE OVERVIEW SHOWS
    //
    // Our background surface **stays mapped** and *is* the shared backdrop: one
    // image spanning every workspace card and the gaps between them, exactly
    // like DMS's own wallpaper. Getting there needs the `place-within-backdrop`
    // rule, not just the `background` layer — see DepthBackground.qml, which is
    // where that distinction is written up.
    //
    // The widgets and the foreground hide. They carry the same rule, so if they
    // stayed mapped they would join that same shared backdrop and put a clock
    // and a cut-out subject behind every workspace card. A wallpaper is one
    // image per screen and should read as one; the subject has no business
    // floating in the overview. Hiding them also makes the overview match a
    // session without this plugin, once the background is blurred to match.
    property bool inOverview: false

    Process {
        id: overviewProbe

        running: true
        command: ["niri", "msg", "overview-state"]
        stdout: StdioCollector {
            onStreamFinished: {
                const value = text.indexOf("open") !== -1 && text.indexOf("closed") === -1;
                if (value !== root.inOverview)
                    root.inOverview = value;
                // Nothing else to do here. Flipping `inOverview` changes which
                // surfaces are wanted, and each output's `onWantedChanged`
                // rewinds its own stage in response — one place, not two.
            }
        }
    }

    Timer {
        interval: 350
        running: true
        repeat: true
        onTriggered: if (!overviewProbe.running) overviewProbe.running = true
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
            patchRow(name, { "state": "pending", "foregroundPath": "", "backgroundPath": "", "message": "" });
        queue = [];
        cacheProcess.command = [enginePath, "clear-cache"];
        cacheProcess.running = true;
    }

    /// Write a starter widgets.json if there is not one already.
    ///
    /// Electron-free and dependency-free on purpose: this is one small write, and
    /// pulling in a process for it would be more code than the thing it does. The
    /// position is centred horizontally and placed a third of the way down, which
    /// is where a clock reads best against a landscape wallpaper.
    function writeExampleLayout() {
        if (dataRoot === "") {
            engineProblem = I18n.tr("The plugin data directory could not be resolved.");
            publish();
            return;
        }
        const directory = dataRoot;
        const example = {
            "widgets": [
                {
                    "id": "clock",
                    "type": "clock",
                    "x": 1100,
                    "y": 850,
                    "settings": {
                        "showSeconds": false,
                        "showDate": true
                    }
                }
            ]
        };
        layoutWriter.command = [
            "sh", "-c",
            'mkdir -p "$1" && [ -f "$1/widgets.json" ] || ' +
            'printf %s "$2" > "$1/widgets.json"',
            "sh", directory, JSON.stringify(example, null, 2)
        ];
        layoutWriter.running = true;
    }

    Process {
        id: layoutWriter

        command: []
        onExited: exitCode => {
            if (exitCode !== 0) {
                root.engineProblem = I18n.tr("Could not write the example layout.");
                root.publish();
                return;
            }
            // The host watches the file, so nothing else has to be told.
            console.info("Depthscape: wrote " + root.layoutPath);
        }
        stderr: StdioCollector {
            onStreamFinished: root.lastStderr = text
        }
    }

    // The settings page and the status widget cannot call into this daemon
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
        else if (action === "exampleLayout")
            writeExampleLayout();
        return true;
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

        function debug(): string {
            const screens = {};
            for (const screen of Quickshell.screens) {
                screens[screen.name] = {
                    "wallpaper": root.wallpaperFor(screen.name),
                    "foreground": root.foregroundFor(screen.name),
                    "background": root.backgroundFor(screen.name)
                };
            }
            return JSON.stringify({
                "effectEnabled": root.effectEnabled,
                "widgetsEnabled": root.widgetsEnabled,
                "modelReady": root.modelReady,
                "enginePath": root.enginePath,
                "dataRoot": root.dataRoot,
                "layoutPath": root.layoutPath,
                "inOverview": root.inOverview,
                "screens": screens
            });
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
            // not also invalidate every cached pair.
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

    // ------------------------------------------------------- surface composition
    //
    // Three full-screen surfaces on the `background` layer. Within a layer,
    // surfaces stack by map order — the last one mapped is drawn on top — and
    // wlr-layer-shell has no raise request, so map order is the only control.
    //
    // DECLARATION ORDER IS NOT MAP ORDER
    //
    // Measured: creating all three together in one component tree does not
    // produce a reliable stack. QML realises each `PanelWindow` asynchronously as
    // its Wayland object is created, so the compositor sees three maps in
    // whatever order they happen to become ready — and with two screens the
    // delegates interleave with each other as well. The symptom is the
    // foreground rendering correctly but sitting *under* the background, so the
    // subject is invisible and the screen shows only the filled background.
    //
    // The fix is to map them in sequence rather than at once: each surface is
    // gated on a stage counter that advances one step per `stageTimer` tick, so
    // the compositor is handed exactly one new window at a time and the stack
    // follows the stage order deterministically. The 32ms tick is the same
    // budget DMS uses for its own equivalent (DesktopWidgetLayer.qml
    // `rebuildApply`).
    //
    // The `Loader` wrapping lets the whole group be destroyed and rebuilt, which
    // is needed because DMS maps its own wallpaper asynchronously and can settle
    // on top of a group that mapped earlier.
    Loader {
        id: surfaceLoader

        active: true
        sourceComponent: Component {
            Variants {
                model: Quickshell.screens

                delegate: Item {
                    id: surfaces

                    required property var modelData

                    // Start the sequence the moment this output first wants a
                    // surface, and re-run it on any transition that changes which
                    // surfaces are mapped. Both cases matter:
                    //
                    //   * The images arrive after `Component.onCompleted`, so by
                    //     the time `wanted` first becomes non-zero the timer has
                    //     usually already walked the stage to 3 and stopped.
                    //     Restarting without rewinding would find nothing left to
                    //     advance and map all three in one turn.
                    //   * Closing the overview brings the widgets and the
                    //     foreground back, and those two must not map together
                    //     either — measured as the background landing on top of
                    //     the subject.
                    //
                    // Rewinding to 1 rather than 0 when the background is already
                    // mapped is what keeps an overview toggle from flashing: the
                    // background is wanted continuously, so unmapping it would
                    // briefly expose the wallpaper DMS draws underneath.
                    onWantedChanged: {
                        if (wanted === 0)
                            return;
                        stage = (wantBackground && stage >= 1) ? 1 : 0;
                        stageTimer.restart();
                    }

                    // Which surfaces of this output are mapped so far. 0 = none.
                    // Advanced by `stageTimer`, one step at a time.
                    property int stage: 0

                    // How many surfaces this output wants mapped right now. Only
                    // used to decide whether the sequence is worth running at all:
                    // the stage walk itself always goes to 3, so that a disabled
                    // widget cannot stall the foreground behind it.
                    readonly property int wanted: (wantBackground ? 1 : 0)
                        + (wantWidgets ? 1 : 0) + (wantForeground ? 1 : 0)

                    // The delegates have no stable id to address them by, and
                    // `Variants` is a C++ type whose internals are not part of
                    // its contract, so the group registers itself instead of
                    // being searched for. Clearing the group first keeps a
                    // rebuild from leaving stale entries behind.
                    //
                    // No need to start the stage timer here: at construction the
                    // images have not been generated yet, so `wanted` is 0 and
                    // any sequence would run to completion against nothing.
                    // `onWantedChanged` starts it when there is something to map.
                    Component.onCompleted: root.surfaceGroups.push(surfaces)
                    Component.onDestruction: {
                        const at = root.surfaceGroups.indexOf(surfaces);
                        if (at >= 0)
                            root.surfaceGroups.splice(at, 1);
                    }

                    // Never show anything whose image is not ready yet: a
                    // visible-but-empty window still costs a compositor surface,
                    // and in the overview it would be an empty hole in the
                    // shared backdrop.
                    readonly property bool wantForeground: root.effectEnabled
                        && !root.inOverview
                        && root.foregroundFor(modelData.name) !== ""
                    // Deliberately NOT gated on `inOverview`. This surface *is*
                    // the shared backdrop, so it has to stay mapped for the
                    // overview to have anything behind its workspace cards. It is
                    // the only one of the three that survives the overview.
                    readonly property bool wantBackground: root.effectEnabled
                        && root.backgroundFor(modelData.name) !== ""
                    readonly property bool wantWidgets: root.effectEnabled
                        && root.widgetsEnabled
                        && !root.inOverview

                    // Each surface is mapped on its own step, in dependency order,
                    // so the compositor is handed one window at a time and the
                    // stack follows this order deterministically. A surface whose
                    // predecessor is absent simply maps on the next tick — the
                    // order between the three is what matters, not the tick count.
                    readonly property bool showBackground: stage >= 1 && wantBackground
                    readonly property bool showWidgets: stage >= 2 && wantWidgets
                    readonly property bool showForeground: stage >= 3 && wantForeground

                    // 1. Background — the scene with the subject cut out.
                    //
                    // Stays mapped in the overview and blurs itself there, so the
                    // shared backdrop matches what DMS does with its own
                    // wallpaper. DMS's setting is the one that decides: if the
                    // user has overview blur off, ours stays crisp too.
                    DepthBackground {
                        targetScreen: surfaces.modelData
                        backgroundPath: surfaces.showBackground
                            ? root.backgroundFor(surfaces.modelData.name)
                            : ""
                        blurred: root.inOverview && root.blurInOverview
                        visible: surfaces.showBackground
                    }

                    // 2. Widgets — the clock the subject stands in front of.
                    //
                    // Created between the other two on purpose: the subject has
                    // to occlude the clock, and the clock has to occlude the
                    // background.
                    DepthWidgetHost {
                        targetScreen: surfaces.modelData
                        layoutPath: root.layoutPath
                        widgetsEnabled: surfaces.showWidgets
                        visible: surfaces.showWidgets
                    }

                    // 3. Foreground — the subject, mapped last means on top.
                    DepthForeground {
                        targetScreen: surfaces.modelData
                        foregroundPath: surfaces.showForeground
                            ? root.foregroundFor(surfaces.modelData.name)
                            : ""
                        visible: surfaces.showForeground
                    }
                }
            }
        }
    }

    // Walks every output's group from stage 0 to 3, one surface per tick.
    //
    // This is what establishes the stacking order inside the shared backdrop:
    // surfaces stack by map order, so handing the compositor one window per tick
    // is the only way to make "background under widgets under subject" hold. Each
    // delegate's `onWantedChanged` rewinds its own stage to re-run this.
    Timer {
        id: stageTimer

        interval: 32
        repeat: true
        onTriggered: {
            // Walk every group to stage 3 unconditionally. Gating the advance on
            // which surfaces are actually wanted would stall: a disabled widget
            // would leave the foreground waiting for a step that never comes.
            // The surfaces themselves decide whether their stage means anything.
            let advanced = false;
            for (const group of root.surfaceGroups) {
                if (group.stage < 3) {
                    group.stage += 1;
                    advanced = true;
                }
            }
            if (!advanced)
                stageTimer.stop();
        }
    }

    // Re-mapping is not instantaneous: the compositor has to process the unmap
    // before the new surfaces can claim the top of the layer. DMS waits 32ms in
    // its own equivalent (DesktopWidgetLayer.qml `rebuildApply`); match that.
    Timer {
        id: remapTimer

        interval: 32
        repeat: false
        onTriggered: {
            surfaceLoader.active = true;
            stageTimer.restart();
        }
    }

    /// Tear down and rebuild every Depthscape surface.
    ///
    /// The only way to re-assert stacking within a layer: there is no raise
    /// request in wlr-layer-shell, so a surface that has been mapped over has to
    /// be unmapped and mapped again. Rebuilding resets every delegate to stage 0,
    /// which re-runs the staged mapping described above.
    function raiseSurfaces() {
        surfaceLoader.active = false;
        // The delegates remove themselves on destruction, but clearing here as
        // well means a rebuild can never advance a stage on a half-dead group.
        root.surfaceGroups = [];
        remapTimer.restart();
    }

    // DMS maps its wallpaper asynchronously, so on a cold start it can settle on
    // top of a group that mapped earlier. Re-creating our surfaces after it has
    // had time to land puts us above it again.
    //
    // WHY THE BACKDROP MAKES THIS A RACE
    //
    // DMS's wallpaper lives in the same shared backdrop as our three surfaces:
    // its generated `dms:blurwallpaper` rule and the user's `^quickshell$` rule
    // both set `place-within-backdrop`, and so does our `^depthscape:` rule.
    // niri renders that backdrop in *map* order — `layers_in_render_order` in
    // niri.rs walks `layer_map.layers_on(Layer::Background).rev()`, so whichever
    // surface was mapped last draws on top. "Who wins the backdrop" is therefore
    // a question of *when*, not of layer: all four surfaces are on the same
    // layer, and the last one mapped is the one visible.
    //
    // DMS rebuilds its wallpaper when `pluginReadyKey` changes, which follows the
    // plugin list finishing its load — after this daemon has already mapped its
    // own surfaces. There is no event to wait on from here: a plugin's view of
    // DMS's services is reduced (see the note on `inOverview`), and the wallpaper
    // is not owned by anything this daemon can observe. So the stack is
    // re-asserted a few times across the window in which DMS settles. The cost of
    // a late raise is one frame of discontinuity; the cost of missing it is our
    // composite being covered by DMS's wallpaper while every one of our surfaces
    // still reports itself healthy — invisible failure, and much worse to
    // diagnose. Measured: with a single raise at 3s the composite loses that race
    // and only the widgets remain visible; re-raising holds it.
    //
    // 3000ms is a bound, not a synchronisation: DMS's own sequence is an image
    // load followed by a few settle frames, and a 5K wallpaper has been measured
    // at ~900ms end to end on this machine.
    Timer {
        id: startupRaise

        interval: 3000
        running: true
        repeat: true
        property int fired: 0
        // Four attempts span 3s..12s. Enough to cover DMS's settle and its
        // plugin-driven rebuild; short enough that a user never notices.
        onTriggered: {
            root.raiseSurfaces();
            fired += 1;
            if (fired >= 4)
                startupRaise.stop();
        }
    }

    Component.onCompleted: {
        console.info("Depthscape: daemon started");
    }

    Component.onDestruction: {
        console.info("Depthscape: daemon stopped");
    }
}
