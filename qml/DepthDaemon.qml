import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Modules.Plugins

// The compositor-config check's parsing, as a pure module: the daemon only
// walks the files.
import "DepthCompositorRules.js" as CompositorRules

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
    //
    // Four knobs, and only two of them are real choices. `threshold` and
    // `feather` are what a person actually tunes; the rest are on/off switches.
    // That is the whole settings surface the reference implementation exposes,
    // and it is worth keeping this small — every extra knob is a combination
    // somebody has to test.

    readonly property bool effectEnabled: pluginData.effectEnabled ?? true
    readonly property bool drawWallpaper: pluginData.drawWallpaper ?? false
    readonly property bool autoGenerate: pluginData.autoGenerate ?? true
    readonly property bool widgetsEnabled: pluginData.widgetsEnabled ?? true
    readonly property int thresholdPercent: pluginData.threshold ?? 30
    readonly property int featherPercent: pluginData.feather ?? 8
    readonly property string modelType: pluginData.modelType ?? "small"

    // Canvas-follows-workspace (parallax). Percentages in settings, fractions
    // here. Defaults: 5% vertical step, 6% horizontal step, 25% travel. The
    // ratio step/travel sets what fraction of the remaining travel each
    // switch consumes — 5/25 ~ 0.20 means k ~ 0.80, so a hop still visibly
    // moves the canvas for roughly sixteen workspaces before it fades out.
    // The previous 8%/15% pair (k = 0.50) halved the motion each hop and
    // looked dead after four. 350 ms ease is unchanged from the reference.
    // Workspace-translation parallax is retired from the product: the settings
    // page no longer exposes a switch, and the default is off. The code path
    // stays (it is woven through the canvas math) but nothing turns it on.
    readonly property bool parallaxEnabled: pluginData.parallaxEnabled ?? false
    readonly property bool spatialEnabled: pluginData.spatialEnabled ?? false
    readonly property string spatialModel: pluginData.spatialModel ?? "isnet-anime"
    // Runtime-only: advanced controls are exposed only after an explicit CLI
    // command and reset to production defaults after the shell restarts.
    property bool debugMode: false
    readonly property int parallaxStepPercent: pluginData.parallaxStep ?? 5
    readonly property int parallaxStepHorizontalPercent: pluginData.parallaxStepHorizontal ?? 6
    readonly property int parallaxMaxTravelPercent: pluginData.parallaxMaxTravel ?? 25
    readonly property bool parallaxInverted: pluginData.parallaxInverted ?? false
    readonly property int parallaxDuration: Math.max(0, Math.min(1500, pluginData.parallaxDuration ?? 350))
    readonly property int spatialPipelineVersion: 5
    readonly property int defaultSpatialTravelPercent: 3
    readonly property int spatialTravelPercent: pluginData.spatialTravel ?? defaultSpatialTravelPercent

    // How much faster the widgets drift than the wallpaper, as a percentage of
    // the wallpaper offset. 0% pins the widgets to the canvas (the old rigid
    // body); the 50% default moves them at 1.5x wallpaper speed; 100% is
    // window speed. The mask rides with the wallpaper regardless, so higher
    // values make the widgets dive deeper behind the subject.
    readonly property int parallaxWidgetStrength: Math.max(0, Math.min(200, pluginData.parallaxWidgetStrength ?? 50))

    readonly property real threshold: thresholdPercent / 100
    readonly property real feather: featherPercent / 100
    readonly property real parallaxStep: parallaxStepPercent / 100
    readonly property real parallaxStepHorizontal: parallaxStepHorizontalPercent / 100
    readonly property real parallaxMaxTravel: parallaxMaxTravelPercent / 100

    // Keep these in lockstep with engine/src/config.rs. Persisted output paths
    // are restored before the engine is invoked, so the QML key must invalidate
    // whenever a depth, mask, or spatial pipeline changes.
    readonly property int depthPipelineVersion: 2
    readonly property int maskPipelineVersion: 1

    // Per-output configuration. A screen-suffixed key always wins when it
    // exists — the settings page writes one per display — and the unsuffixed
    // key is only the default for screens never configured. This does not
    // depend on DMS's per-monitor-wallpaper switch: masks are generated per
    // wallpaper either way, so the tuning follows the output, not the mode.
    function thresholdFor(screenName) {
        if (screenName && pluginData["threshold_" + screenName] !== undefined)
            return pluginData["threshold_" + screenName];
        return root.thresholdPercent;
    }

    function featherFor(screenName) {
        if (screenName && pluginData["feather_" + screenName] !== undefined)
            return pluginData["feather_" + screenName];
        return root.featherPercent;
    }

    function fgOffsetXFor(screenName) {
        if (!root.debugMode)
            return 0;
        if (screenName && pluginData["fg_offset_x_" + screenName] !== undefined)
            return Number(pluginData["fg_offset_x_" + screenName]);
        return Number(pluginData["fg_offset_x"] ?? 0);
    }

    function fgOffsetYFor(screenName) {
        if (!root.debugMode)
            return 0;
        if (screenName && pluginData["fg_offset_y_" + screenName] !== undefined)
            return Number(pluginData["fg_offset_y_" + screenName]);
        return Number(pluginData["fg_offset_y"] ?? 0);
    }

    function fgScaleFor(screenName) {
        if (!root.debugMode)
            return 1;
        if (screenName && pluginData["fg_scale_" + screenName] !== undefined)
            return Number(pluginData["fg_scale_" + screenName]) / 100;
        return Number(pluginData["fg_scale"] ?? 100) / 100;
    }

    function setDebugMode(enabled) {
        root.debugMode = enabled === true;
        return root.debugMode;
    }

    function effectEnabledFor(screenName) {
        if (screenName && pluginData["effect_enabled_" + screenName] !== undefined)
            return pluginData["effect_enabled_" + screenName] !== false;
        if (screenName && pluginData["effectEnabled_" + screenName] !== undefined)
            return pluginData["effectEnabled_" + screenName] !== false;
        return root.effectEnabled;
    }

    // Per-output settings read the screen-suffixed key first and fall back to
    // the unsuffixed one only as the default for a screen that has never been
    // configured. Writes stay suffixed, so changing one output cannot leak to
    // another.
    function _settingFor(screenName, key, defaultValue) {
        if (screenName && pluginData[key + "_" + screenName] !== undefined)
            return pluginData[key + "_" + screenName];
        return pluginData[key] ?? defaultValue;
    }

    function _boolSettingFor(screenName, key, defaultValue) {
        return root._settingFor(screenName, key, defaultValue) !== false;
    }

    function _intSettingFor(screenName, key, defaultValue) {
        const value = Number(root._settingFor(screenName, key, defaultValue));
        return isFinite(value) ? Math.round(value) : defaultValue;
    }

    function widgetsEnabledFor(screenName) {
        return root._boolSettingFor(screenName, "widgetsEnabled", true);
    }

    function parallaxEnabledFor(screenName) {
        return root._boolSettingFor(screenName, "parallaxEnabled", false)
            && !root._boolSettingFor(screenName, "spatialEnabled", false);
    }

    function spatialEnabledFor(screenName) {
        return root._boolSettingFor(screenName, "spatialEnabled", false);
    }

    function spatialTravelPercentFor(screenName) {
        return Math.max(0, Math.min(10,
            root._intSettingFor(screenName, "spatialTravel", root.spatialTravelPercent)));
    }

    function parallaxMaxTravelPercentFor(screenName) {
        return Math.max(0, Math.min(100,
            root._intSettingFor(screenName, "parallaxMaxTravel", 25)));
    }

    function parallaxStepPercentFor(screenName) {
        return Math.max(0, Math.min(50,
            root._intSettingFor(screenName, "parallaxStep", 5)));
    }

    function parallaxStepHorizontalPercentFor(screenName) {
        return Math.max(0, Math.min(50,
            root._intSettingFor(screenName, "parallaxStepHorizontal", 6)));
    }

    function parallaxWidgetStrengthFor(screenName) {
        return Math.max(0, Math.min(200,
            root._intSettingFor(screenName, "parallaxWidgetStrength", 50)));
    }

    function parallaxInvertedFor(screenName) {
        return root._boolSettingFor(screenName, "parallaxInverted", false);
    }

    function parametersKeyFor(screenName) {
        const t = (thresholdFor(screenName) / 100).toFixed(4);
        const f = (featherFor(screenName) / 100).toFixed(4);
        const sp = spatialEnabledFor(screenName);
        const fgSuffix = (sp && root.spatialModel !== "isnet-anime") ? (":" + root.spatialModel) : "";
        return "d" + depthPipelineVersion + "m" + maskPipelineVersion
            + "s" + spatialPipelineVersion + ":" + modelType + ":" + t + ":" + f
            + ":spatial=" + (sp ? "1" : "0") + fgSuffix;
    }

    // Changing either parameter or the model invalidates the mask, so this key
    // is what decides whether a finished job is still worth applying.
    readonly property string parametersKey: parametersKeyFor("")

    // ------------------------------------------------------------------ engine

    // The directory this plugin is installed in — the parent of this QML file.
    // The layout file lives HERE, next to plugin.json: it is configuration, and
    // configuration belongs beside the thing it configures. It is machine-local
    // state, so it ships gitignored. `dataRoot` (models + caches) is resolved
    // by tools/resolve-data-root.sh: inside this directory for a fresh install
    // so an uninstall removes the models, or the legacy XDG path when it exists.
    readonly property string pluginDir: {
        const url = Qt.resolvedUrl("..").toString();
        return decodeURIComponent(url.replace(/^file:\/\//, "").replace(/\/$/, ""));
    }

    property string enginePath: ""
    property string engineProblem: ""
    property bool downloadingEngine: false
    property bool engineAutoDownloadAttempted: false
    property bool modelReady: false
    property bool modelBusy: false
    property string installingModel: ""
    property var availableModels: []
    property var foregroundModels: []
    property var currentModelInfo: null

    /// Model-lookup helpers exposed as first-class daemon API.
    ///
    /// The settings page and any future plugin-facing surface both need to ask
    /// "is this model installed?" and "how big is it?" from the same array;
    /// putting the walk here keeps the view layer out of domain iteration and
    /// gives us one place to change the shape of `availableModels` later.
    function isModelReady(modelId) {
        for (const list of [availableModels, foregroundModels]) {
            for (let i = 0; i < list.length; i++)
                if (list[i].id === modelId)
                    return list[i].ready === true;
        }
        return false;
    }

    function modelInfo(modelId) {
        for (let i = 0; i < availableModels.length; i++)
            if (availableModels[i].id === modelId)
                return availableModels[i];
        for (let i = 0; i < foregroundModels.length; i++)
            if (foregroundModels[i].id === modelId)
                return foregroundModels[i];
        return null;
    }

    property string dataRoot: ""

    // ----------------------------------------------------------------- outputs

    // screenName -> { wallpaper, state, maskPath, message, elapsedMs, cacheHit }
    // state: empty | pending | processing | ready | error
    property var outputs: ({})
    property var queue: []
    property var active: null
    property string lastStdout: ""
    property string lastStderr: ""

    // One entry per output, holding the two surface windows for that output.
    // The delegates register themselves; see the composition section below.
    property var surfaceGroups: []

    readonly property var nativeWallpaperOutputs: []
    readonly property string nativeWallpaperSignature: ""

    function usesNativeWallpaper(screenName) {
        return false;
    }

    onNativeWallpaperSignatureChanged: Qt.callLater(() => {
        root.queue = root.queue.filter(job => !root.usesNativeWallpaper(job.screenName));
        if (root.active && root.usesNativeWallpaper(root.active.screenName))
            analyzeProcess.running = false;
        if (root.autoGenerate)
            root.enqueueAll();
    })

    // ------------------------------------------------------------------ helpers

    /// The wallpaper DMS is showing on one output, or "" if there is none to
    /// analyse.
    ///
    /// Read from `SessionData`, not from `outputs`: `syncOutputs` builds
    /// `outputs` *from* this, so reading the row here would be circular and would
    /// leave every output empty on the first pass.
    function wallpaperFor(screenName) {
        if (SessionData.getMonitorWallpaperFillMode(screenName) !== "Fill")
            return "";
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

    /// Sets the wallpaper for a specific screen (or globally) using DMS SessionData.
    function setWallpaper(screenName, path) {
        if (!path)
            return false;
        const clean = path.toString().replace(/^file:\/\//, "");
        if (typeof SessionData !== "undefined" && SessionData) {
            if (screenName && SessionData.perMonitorWallpaper) {
                SessionData.setMonitorWallpaper(screenName, clean);
                if (SessionData.setMonitorCyclingFolderPath)
                    SessionData.setMonitorCyclingFolderPath(screenName, "");
            } else {
                SessionData.setWallpaper(clean);
                if (SessionData.wallpaperCyclingFolderPath !== undefined)
                    SessionData.wallpaperCyclingFolderPath = "";
            }
            if (SessionData.saveSettings)
                SessionData.saveSettings();
            return true;
        }
        return false;
    }

    /// The occlusion mask for one output, or "" while there is none.
    ///
    /// One artefact, so one accessor. The foreground/background pair this
    /// replaced needed two, and a pair could be half-present; a single file
    /// cannot.
    function maskFor(screenName) {
        const row = outputs[screenName];
        return row && row.state === "ready" ? (row.maskPath || "") : "";
    }

    function bboxFor(screenName) {
        const row = outputs[screenName];
        return row && row.state === "ready" ? (row.bbox || null) : null;
    }

    function sourceWidthFor(screenName) {
        const row = outputs[screenName];
        return row && row.state === "ready" ? (row.width || 0) : 0;
    }

    function sourceHeightFor(screenName) {
        const row = outputs[screenName];
        return row && row.state === "ready" ? (row.height || 0) : 0;
    }

    /// The wallpaper-derived palette sidecar for one output, or "" when no
    /// generate has landed yet. The host wires this into a File watcher and
    /// hands the parsed object to every widget on that output; widgets in
    /// `colorMode: "auto"` paint from it, everything else ignores it.
    function paletteFor(screenName) {
        const row = outputs[screenName];
        return row && row.state === "ready" ? (row.palettePath || "") : "";
    }

    function spatialBackgroundFor(screenName) {
        if (!spatialEnabledFor(screenName))
            return "";
        const row = outputs[screenName];
        return row && row.state === "ready" ? (row.spatialBackgroundPath || "") : "";
    }

    function spatialForegroundFor(screenName) {
        if (!spatialEnabledFor(screenName))
            return "";
        const row = outputs[screenName];
        return row && row.state === "ready" ? (row.spatialForegroundPath || "") : "";
    }

    function spatialDepthFor(screenName) {
        if (!spatialEnabledFor(screenName))
            return "";
        const row = outputs[screenName];
        return row && row.state === "ready" ? (row.spatialDepthPath || "") : "";
    }

    function spatialMatteFor(screenName) {
        if (!spatialEnabledFor(screenName))
            return "";
        const row = outputs[screenName];
        return row && row.state === "ready" ? (row.spatialMattePath || "") : "";
    }

    function spatialInfluenceFor(screenName) {
        if (!spatialEnabledFor(screenName))
            return "";
        const row = outputs[screenName];
        return row && row.state === "ready" ? (row.spatialInfluencePath || "") : "";
    }

    function spatialPathsPresent(row) {
        return !!row && !!row.spatialBackgroundPath && !!row.spatialForegroundPath
            && !!row.spatialDepthPath && !!row.spatialMattePath && !!row.spatialInfluencePath;
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
                "cacheHit": row.cacheHit === true,
                "effectEnabled": effectEnabledFor(name),
                "widgetsEnabled": widgetsEnabledFor(name)
            });
        }
        rows.sort((left, right) => left.name < right.name ? -1 : 1);
        try {
            pluginService.savePluginState(pluginId, "status", {
                "enginePath": enginePath,
                "engineProblem": engineProblem,
                "modelReady": modelReady,
                "modelBusy": modelBusy,
                "installingModel": installingModel,
                "modelType": modelType,
                "availableModels": availableModels,
                "foregroundModels": foregroundModels,
                "dataRoot": dataRoot,
                "currentModel": currentModelInfo,
                "enabled": rows.some(entry => entry.effectEnabled),
                "threshold": thresholdPercent,
                "feather": featherPercent,
                "outputs": rows
            });
        } catch (e) {
            // Ignore internal state-writer warning
        }
    }

    // ------------------------------------------------------------------- queue

    function enqueue(screenName) {
        const row = outputs[screenName];
        if (usesNativeWallpaper(screenName) || !row || !row.wallpaper || !modelReady || enginePath === ""
                || (!effectEnabledFor(screenName) && !spatialEnabledFor(screenName)))
            return;
        const pKey = parametersKeyFor(screenName);
        const key = screenName + "\n" + row.wallpaper + "\n" + pKey;
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
            "parametersKey": pKey,
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
            const pKey = parametersKeyFor(candidate.screenName);
            if (!usesNativeWallpaper(candidate.screenName) && row && row.wallpaper === candidate.wallpaper && candidate.parametersKey === pKey) {
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
        const currentRow = outputs[job.screenName];
        if (!currentRow || currentRow.state !== "ready") {
            patchRow(job.screenName, { "state": "processing", "message": "" });
        }
        publish();

        lastStdout = "";
        lastStderr = "";
        const t = thresholdFor(job.screenName) / 100;
        const f = featherFor(job.screenName) / 100;
        const command = [
            "analyze",
            "--wallpaper", job.wallpaper,
            "--threshold", "" + t,
            "--feather", "" + f,
            "--model", root.modelType
        ];
        if (spatialEnabledFor(job.screenName))
            command.push("--spatial", "--spatial-model", root.spatialModel);
        analyzeProcess.command = root.engineArgs(command);
        analyzeProcess.running = true;
    }

    function finishJob(exitCode) {
        const job = active;
        active = null;
        if (job === null) {
            pump();
            return;
        }

        if (usesNativeWallpaper(job.screenName)) {
            pump();
            return;
        }

        const currentWallpaper = wallpaperFor(job.screenName);
        const currentPKey = parametersKeyFor(job.screenName);
        const stale = job.parametersKey !== currentPKey || currentWallpaper !== job.wallpaper;
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
                "maskPath": "",
                "spatialBackgroundPath": "",
                "spatialForegroundPath": "",
                "spatialDepthPath": "",
                "spatialMattePath": "",
                "spatialInfluencePath": "",
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
            && typeof parsed.maskPath === "string" && parsed.maskPath !== ""
            && (!spatialEnabledFor(job.screenName)
                || (typeof parsed.spatialError === "string" && parsed.spatialError !== "")
                || (typeof parsed.spatialBackgroundPath === "string" && parsed.spatialBackgroundPath !== ""
                    && typeof parsed.spatialForegroundPath === "string" && parsed.spatialForegroundPath !== ""
                    && typeof parsed.spatialDepthPath === "string" && parsed.spatialDepthPath !== ""
                    && typeof parsed.spatialMattePath === "string" && parsed.spatialMattePath !== ""
                    && typeof parsed.spatialInfluencePath === "string" && parsed.spatialInfluencePath !== ""));
        if (!valid) {
            patchRow(job.screenName, {
                "state": "error",
                "maskPath": "",
                "palettePath": "",
                "spatialBackgroundPath": "",
                "spatialForegroundPath": "",
                "spatialDepthPath": "",
                "spatialMattePath": "",
                "spatialInfluencePath": "",
                "message": I18n.tr("The depth engine returned an unexpected result.")
            });
        } else {
            patchRow(job.screenName, {
                "state": "ready",
                "maskPath": parsed.maskPath,
                "bbox": Array.isArray(parsed.bbox) ? parsed.bbox : null,
                "width": parsed.width || 0,
                "height": parsed.height || 0,
                // Palette is a sidecar: the engine always writes one on a
                // successful run, but a mid-flight error or an older engine
                // binary that predates the palette step is a valid "empty"
                // case. Widgets in auto mode fall back to their manual
                // colours; every other mode ignores the field entirely.
                "palettePath": typeof parsed.palettePath === "string" ? parsed.palettePath : "",
                "spatialBackgroundPath": typeof parsed.spatialBackgroundPath === "string" ? parsed.spatialBackgroundPath : "",
                "spatialForegroundPath": typeof parsed.spatialForegroundPath === "string" ? parsed.spatialForegroundPath : "",
                "spatialDepthPath": typeof parsed.spatialDepthPath === "string" ? parsed.spatialDepthPath : "",
                "spatialMattePath": typeof parsed.spatialMattePath === "string" ? parsed.spatialMattePath : "",
                "spatialInfluencePath": typeof parsed.spatialInfluencePath === "string" ? parsed.spatialInfluencePath : "",
                "message": parsed.spatialError || parsed.spatialWarning || "",
                "elapsedMs": parsed.elapsedMs || 0,
                "cacheHit": parsed.splitCacheHit === true
            });
            if (parsed.spatialError)
                console.warn("Depthscape: spatial wallpaper unavailable: " + parsed.spatialError);
            if (parsed.spatialError || (typeof parsed.spatialWarning === "string"
                    && parsed.spatialWarning.startsWith("IS-Net Anime")
                    && parsed.spatialWarning.indexOf("unavailable") !== -1)) {
                // Re-run after the engine's temporary model fallback has had
                // time to recover. The engine cache also throttles retries,
                // so a shell restart cannot turn this into a download loop.
                spatialRetryTimer.restart();
            }
            const retryableSpatialFallback = typeof parsed.spatialWarning === "string"
                && parsed.spatialWarning.startsWith("IS-Net Anime")
                && parsed.spatialWarning.indexOf("unavailable") !== -1;
            if (!parsed.spatialError && !retryableSpatialFallback)
                root.persistLastOutput(job.screenName, job.wallpaper, job.parametersKey, parsed.maskPath,
                    typeof parsed.palettePath === "string" ? parsed.palettePath : "",
                    typeof parsed.spatialBackgroundPath === "string" ? parsed.spatialBackgroundPath : "",
                    typeof parsed.spatialForegroundPath === "string" ? parsed.spatialForegroundPath : "",
                    typeof parsed.spatialDepthPath === "string" ? parsed.spatialDepthPath : "",
                    typeof parsed.spatialMattePath === "string" ? parsed.spatialMattePath : "",
                    typeof parsed.spatialInfluencePath === "string" ? parsed.spatialInfluencePath : "",
                    typeof parsed.spatialWarning === "string" ? parsed.spatialWarning : "",
                    Array.isArray(parsed.bbox) ? parsed.bbox : null,
                    parsed.width || 0,
                    parsed.height || 0);
            root.evaluateReveal();
        }
        pump();
    }

    // ------------------------------------------------------------------ syncing

    function lookupCachedEntry(map, screenName, wallpaper, pKey) {
        if (!map || typeof map !== "object" || !wallpaper)
            return null;
        const history = (map._history && typeof map._history === "object") ? map._history : null;
        const hKey = wallpaper + "|" + pKey;
        if (history && history[hKey] && history[hKey].maskPath)
            return history[hKey];
        const direct = map[screenName];
        if (direct && direct.wallpaper === wallpaper && direct.parametersKey === pKey && direct.maskPath)
            return direct;
        return null;
    }

    function loadInitialOutputs() {
        let map = pluginData.lastOutputs || null;
        if (typeof map === "string") {
            try {
                map = JSON.parse(map);
            } catch (e) {
                map = null;
            }
        }
        if (!map || typeof map !== "object")
            return;

        const next = {};
        const screens = Quickshell.screens;
        for (let i = 0; i < screens.length; i++) {
            const name = screens[i].name;
            const currentWp = wallpaperFor(name);
            const pKey = parametersKeyFor(name);
            const cached = lookupCachedEntry(map, name, currentWp, pKey);
            if (cached && (!spatialEnabledFor(name) || root.spatialPathsPresent(cached))) {
                next[name] = {
                    "wallpaper": currentWp,
                    "state": "ready",
                    "maskPath": cached.maskPath,
                    "bbox": Array.isArray(cached.bbox) ? cached.bbox : null,
                    "width": cached.width || 0,
                    "height": cached.height || 0,
                    // Older pluginData entries predate the palette field;
                    // an absent path is a valid "no sidecar yet" state that
                    // auto mode falls out of gracefully.
                    "palettePath": cached.palettePath || "",
                    "spatialBackgroundPath": cached.spatialBackgroundPath || "",
                    "spatialForegroundPath": cached.spatialForegroundPath || "",
                    "spatialDepthPath": cached.spatialDepthPath || "",
                    "spatialMattePath": cached.spatialMattePath || "",
                    "spatialInfluencePath": cached.spatialInfluencePath || "",
                    "message": cached.spatialWarning || "",
                    "elapsedMs": 0,
                    "cacheHit": true
                };
            }
        }
        if (Object.keys(next).length > 0) {
            outputs = next;
        }
    }

    function persistLastOutput(screenName, wallpaper, paramsKey, maskPath, palettePath,
            spatialBackgroundPath, spatialForegroundPath, spatialDepthPath, spatialMattePath,
            spatialInfluencePath, spatialWarning, bbox, width, height) {
        if (!pluginService || !pluginService.savePluginData)
            return;
        let map = {};
        const raw = pluginData.lastOutputs;
        if (typeof raw === "object" && raw !== null) {
            for (const k in raw)
                map[k] = raw[k];
        } else if (typeof raw === "string" && raw.length > 0) {
            try {
                const parsed = JSON.parse(raw);
                for (const k in parsed)
                    map[k] = parsed[k];
            } catch (e) {}
        }
        const entry = {
            "wallpaper": wallpaper,
            "parametersKey": paramsKey,
            "maskPath": maskPath,
            "bbox": bbox || null,
            "width": width || 0,
            "height": height || 0,
            "palettePath": palettePath || "",
            "spatialBackgroundPath": spatialBackgroundPath || "",
            "spatialForegroundPath": spatialForegroundPath || "",
            "spatialDepthPath": spatialDepthPath || "",
            "spatialMattePath": spatialMattePath || "",
            "spatialInfluencePath": spatialInfluencePath || "",
            "spatialWarning": spatialWarning || ""
        };
        map[screenName] = entry;
        const history = (map._history && typeof map._history === "object")
            ? Object.assign({}, map._history) : {};
        const hKey = wallpaper + "|" + paramsKey;
        delete history[hKey];
        history[hKey] = entry;
        const keys = Object.keys(history);
        while (keys.length > 60) {
            const oldest = keys.shift();
            delete history[oldest];
        }
        map._history = history;
        pluginService.savePluginData(pluginId, "lastOutputs", map);
    }

    function syncOutputs() {
        const next = {};
        const screens = Quickshell.screens;
        let map = pluginData.lastOutputs || null;
        if (typeof map === "string") {
            try { map = JSON.parse(map); } catch (e) { map = null; }
        }
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
                if (active && active.screenName === name && analyzeProcess.running) {
                    analyzeProcess.running = false;
                }
                const pKey = parametersKeyFor(name);
                const cached = lookupCachedEntry(map, name, wallpaper, pKey);
                if (cached && (!spatialEnabledFor(name) || root.spatialPathsPresent(cached))) {
                    row.maskPath = cached.maskPath;
                    row.bbox = Array.isArray(cached.bbox) ? cached.bbox : null;
                    row.width = cached.width || 0;
                    row.height = cached.height || 0;
                    row.palettePath = cached.palettePath || "";
                    row.spatialBackgroundPath = cached.spatialBackgroundPath || "";
                    row.spatialForegroundPath = cached.spatialForegroundPath || "";
                    row.spatialDepthPath = cached.spatialDepthPath || "";
                    row.spatialMattePath = cached.spatialMattePath || "";
                    row.spatialInfluencePath = cached.spatialInfluencePath || "";
                    row.state = "ready";
                    row.cacheHit = true;
                    row.message = cached.spatialWarning || "";
                } else {
                    row.maskPath = "";
                    row.bbox = null;
                    row.width = 0;
                    row.height = 0;
                    row.palettePath = "";
                    row.spatialBackgroundPath = "";
                    row.spatialForegroundPath = "";
                    row.spatialDepthPath = "";
                    row.spatialMattePath = "";
                    row.spatialInfluencePath = "";
                    row.message = "";
                    row.elapsedMs = 0;
                    row.cacheHit = false;
                    row.state = wallpaper === "" ? "empty" : "pending";
                }
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

    Timer {
        id: paramDebounceTimer

        interval: 150
        repeat: false
        onTriggered: {
            if (root.autoGenerate)
                root.enqueueAll();
        }
    }

    Timer {
        id: spatialRetryTimer
        interval: 15 * 60 * 1000
        repeat: false
        onTriggered: {
            if (root.autoGenerate)
                root.enqueueAll();
        }
    }

    function syncParameters() {
        // A parameter change updates the split; DO NOT clear current paths.
        // Keeping the current surfaces visible prevents flickering while
        // the engine computes the new split asynchronously.
        let map = pluginData.lastOutputs || null;
        if (typeof map === "string") {
            try { map = JSON.parse(map); } catch (e) { map = null; }
        }
        const next = {};
        for (const name in outputs) {
            const row = {};
            for (const key in outputs[name])
                row[key] = outputs[name][key];
            if (row.wallpaper) {
                const pKey = parametersKeyFor(name);
                const cached = lookupCachedEntry(map, name, row.wallpaper, pKey);
                if (cached && (!spatialEnabledFor(name) || root.spatialPathsPresent(cached))) {
                    row.maskPath = cached.maskPath;
                    row.bbox = Array.isArray(cached.bbox) ? cached.bbox : null;
                    row.width = cached.width || 0;
                    row.height = cached.height || 0;
                    row.palettePath = cached.palettePath || "";
                    row.spatialBackgroundPath = cached.spatialBackgroundPath || "";
                    row.spatialForegroundPath = cached.spatialForegroundPath || "";
                    row.spatialDepthPath = cached.spatialDepthPath || "";
                    row.spatialMattePath = cached.spatialMattePath || "";
                    row.spatialInfluencePath = cached.spatialInfluencePath || "";
                    row.state = "ready";
                    row.cacheHit = true;
                    row.message = cached.spatialWarning || "";
                } else {
                    row.state = row.maskPath ? "ready" : "pending";
                }
            }
            next[name] = row;
        }
        outputs = next;
        queue = [];
        if (autoGenerate)
            paramDebounceTimer.restart();
        publish();
    }

    // ------------------------------------------------------------------ processes

    Process {
        id: resolveEngine

        // Started by resolveDataRoot: every engine command below carries
        // --data-dir, so the data root has to be known before the first status
        // query (which would otherwise silently use the engine's own default).
        running: false
        command: [
            "sh", "-c",
            'if [ -n "$DEPTHSCAPE_ENGINE" ] && [ -x "$DEPTHSCAPE_ENGINE" ]; then echo "$DEPTHSCAPE_ENGINE"; ' +
            'elif [ -x "$1/bin/depthscape-engine" ]; then echo "$1/bin/depthscape-engine"; ' +
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
                } else if (!root.engineAutoDownloadAttempted) {
                    root.engineAutoDownloadAttempted = true;
                    root.downloadPrebuiltEngine();
                } else {
                    root.engineProblem = I18n.tr("Depth engine binary not found. Download or build it in settings.");
                    root.publish();
                }
            }
        }
    }

    Process {
        id: downloadEngineProcess

        command: ["sh", root.pluginDir + "/tools/download-engine.sh", root.pluginDir]
        onExited: exitCode => {
            root.downloadingEngine = false;
            if (exitCode === 0) {
                if (typeof ToastService !== "undefined" && ToastService.showInfo) {
                    ToastService.showInfo(I18n.tr("Depthscape"), I18n.tr("Depth engine downloaded successfully."), "", "depthscape-engine-ready");
                }
                root.rescanEngine();
            } else {
                root.engineProblem = I18n.tr("Failed to auto-download engine. Build or retry in settings.");
                if (typeof ToastService !== "undefined" && ToastService.showWarning) {
                    ToastService.showWarning(
                        I18n.tr("Depthscape: engine setup required"),
                        I18n.tr("Could not download prebuilt engine. Open plugin settings to retry or build from source."),
                        "", "depthscape-engine-missing");
                }
                root.publish();
            }
        }
    }

    function downloadPrebuiltEngine() {
        if (downloadingEngine)
            return;
        downloadingEngine = true;
        if (typeof ToastService !== "undefined" && ToastService.showInfo) {
            ToastService.showInfo(I18n.tr("Depthscape"), I18n.tr("Downloading prebuilt depth engine..."), "", "depthscape-engine-downloading");
        }
        downloadEngineProcess.running = true;
    }

    // Where models and caches live. tools/resolve-data-root.sh keeps a fresh
    // install's data inside the plugin directory (so DMS's uninstall removes
    // the models along with the plugin) while leaving an existing XDG install
    // exactly where it is. It is the first process to run; on completion it
    // starts the engine lookup. A missing/failed script must not strand the
    // daemon, hence the synchronous QML fallback.
    Process {
        id: resolveDataRoot

        running: true
        command: ["sh", root.pluginDir + "/tools/resolve-data-root.sh", root.pluginDir]
        stdout: StdioCollector {
            onStreamFinished: {
                const found = text.trim();
                root.dataRoot = found.length > 0 ? found : root.fallbackDataRoot();
                resolveEngine.running = true;
            }
        }
    }

    function fallbackDataRoot() {
        const explicitDir = Quickshell.env("DEPTHSCAPE_DATA_DIR");
        if (explicitDir)
            return explicitDir;
        const xdg = Quickshell.env("XDG_DATA_HOME");
        if (xdg)
            return xdg + "/depthscape";
        const home = Quickshell.env("HOME");
        return (home || "/tmp") + "/.local/share/depthscape";
    }

    /// Every engine invocation must use the same data root, otherwise a model
    /// downloaded through the settings page would be invisible to `analyze`.
    function engineArgs(args) {
        const prefix = root.dataRoot !== "" ? ["--data-dir", root.dataRoot] : [];
        return [enginePath].concat(prefix, args);
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
                root.availableModels = parsed && parsed.availableModels ? parsed.availableModels : [];
                root.foregroundModels = parsed && parsed.foregroundModels ? parsed.foregroundModels : [];
                root.currentModelInfo = parsed && parsed.model ? parsed.model : null;
                if (parsed && parsed.dataDir)
                    root.dataRoot = parsed.dataDir;
                // Models are provisioned on demand. A cold install must never
                // pull hundreds of megabytes just because the shell started;
                // the settings page offers an explicit download action instead.
                if (!root.modelReady) {
                    root.engineProblem = I18n.tr("Model not downloaded. Use Download Model in the settings page.");
                } else {
                    root.engineProblem = "";
                    root.modelBusy = false;
                }
                root.publish();
                root.syncOutputs();
            }
        }
    }

    Process {
        id: setupProcess

        command: []
        onExited: exitCode => {
            root.modelBusy = false;
            root.installingModel = "";
            if (exitCode !== 0) {
                root.engineProblem = root.shortError();
                if (typeof ToastService !== "undefined" && ToastService.showError) {
                    ToastService.showError(I18n.tr("Depthscape: model download failed"), root.engineProblem, "", "depthscape-setup-fail");
                }
                root.publish();
                return;
            }
            if (typeof ToastService !== "undefined" && ToastService.showInfo) {
                ToastService.showInfo(I18n.tr("Depthscape: model downloaded and verified"), "", "", "depthscape-setup-success");
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

    // Explicit data purge: `depthscape-engine uninstall` removes every model
    // and every generated artefact. Kept separate from clearCache so that
    // clearing a stale mask never costs the user a multi-gigabyte re-download.
    Process {
        id: uninstallProcess

        command: []
        onExited: exitCode => {
            root.modelBusy = false;
            if (exitCode !== 0) {
                root.engineProblem = root.shortError();
                if (typeof ToastService !== "undefined" && ToastService.showError)
                    ToastService.showError(I18n.tr("Depthscape: could not remove model data"), root.engineProblem, "", "depthscape-uninstall-fail");
                root.publish();
                root.checkModel();
                return;
            }
            for (const name in outputs)
                patchRow(name, { "state": "pending", "maskPath": "", "palettePath": "", "spatialBackgroundPath": "", "spatialForegroundPath": "", "spatialDepthPath": "", "spatialMattePath": "", "spatialInfluencePath": "", "message": "" });
            root.modelReady = false;
            root.queue = [];
            if (typeof ToastService !== "undefined" && ToastService.showInfo)
                ToastService.showInfo(I18n.tr("Depthscape: models and cached data removed"), "", "", "depthscape-uninstall-success");
            root.checkModel();
        }
        stderr: StdioCollector {
            onStreamFinished: root.lastStderr = text
        }
    }

    // ------------------------------------------------------------------ lifecycle

    function checkModel() {
        if (enginePath === "")
            return;
        statusProcess.command = root.engineArgs(["status", "--model", root.modelType]);
        statusProcess.running = true;
    }

    /// The only place a download starts. `force` re-downloads a model that is
    /// already present (repair / checksum failure).
    function installModel(targetModel, force) {
        if (enginePath === "" || modelBusy)
            return;
        const toInstall = targetModel || root.modelType;
        modelBusy = true;
        installingModel = toInstall;
        engineProblem = "";
        publish();
        lastStderr = "";
        const args = ["setup", "--model", toInstall];
        if (force === true)
            args.push("--force");
        setupProcess.command = root.engineArgs(args);
        setupProcess.running = true;
    }

    /// Remove downloaded models and all generated data. Fresh installs keep
    /// them inside the plugin directory, which DMS's uninstaller deletes; this
    /// is the explicit purge for legacy XDG installs and for symlinked
    /// checkouts, where the uninstaller only removes the link.
    function uninstallData() {
        if (enginePath === "" || modelBusy)
            return;
        // Stop the queue *before* killing the worker: Process.onExited calls
        // finishJob, which would otherwise pump the next wallpaper straight
        // back into an engine whose data directory is being deleted.
        root.modelReady = false;
        if (analyzeProcess.running)
            analyzeProcess.running = false;
        active = null;
        queue = [];
        modelBusy = true;
        engineProblem = "";
        publish();
        lastStderr = "";
        uninstallProcess.command = root.engineArgs(["uninstall"]);
        uninstallProcess.running = true;
    }

    /// Re-run the engine lookup after the user has built/installed it.
    function rescanEngine() {
        enginePath = "";
        modelReady = false;
        resolveEngine.running = false;
        resolveEngine.running = true;
    }

    function clearCache() {
        if (enginePath === "")
            return;
        for (const name in outputs)
            patchRow(name, { "state": "pending", "maskPath": "", "spatialBackgroundPath": "", "spatialForegroundPath": "", "spatialDepthPath": "", "spatialMattePath": "", "spatialInfluencePath": "", "message": "" });
        queue = [];
        cacheProcess.command = root.engineArgs(["clear-cache"]);
        cacheProcess.running = true;
    }



    // ---------------------------------------------- compositor rule self-check
    //
    // Check whether all Depthscape surfaces are assigned to Niri's shared
    // backdrop. Follow includes because the rule may be in a DMS local file.
    //
    // "unknown" is a first-class verdict and the default. An unreadable include
    // or an include with a glob means the rule *might* be there; reporting
    // "missing" then would be a lie that costs the user a coding detour.
    property var layerRuleCheck: ({
        state: "unknown",
        covered: [],
        detail: "not checked yet"
    })

    readonly property string niriConfigPath: {
        const home = Quickshell.env("HOME") || "";
        const conf = Quickshell.env("XDG_CONFIG_HOME")
            || (home !== "" ? home + "/.config" : "");
        return conf === "" ? "" : conf + "/niri/config.kdl";
    }

    // Depth 8 matches niri's own include nesting limit; 24 files is a runaway
    // include loop guard. Both are far above any real tree.
    readonly property int ruleWalkMaxDepth: 8
    readonly property int ruleWalkMaxFiles: 24

    property var ruleWalk: []       // pending [{ path, depth }]
    property var ruleFiles: ({})    // visited path -> text, or null if unreadable
    property var ruleCurrent: null  // the file ruleFileReader is loading now
    property bool ruleWalkRunning: false

    FileView {
        id: ruleFileReader

        path: ""
        blockLoading: false
        printErrors: false

        onLoaded: root.onRuleFileRead(ruleFileReader.path, ruleFileReader.text())
        onLoadFailed: root.onRuleFileRead(ruleFileReader.path, null)
    }

    function checkCompositorLayerRule() {
        if (!CompositorService.isNiri) {
            root.layerRuleCheck = {
                state: "unknown",
                covered: [],
                detail: "compositor is not niri"
            };
            return;
        }
        root.ruleWalk = [{ path: root.niriConfigPath, depth: 0 }];
        root.ruleFiles = ({});
        root.ruleCurrent = null;
        root.ruleWalkRunning = true;
        // Not immediately: assigning `path` on a FileView that is still being
        // constructed has its operation dropped (Quickshell logs "got operation
        // finished from dropped operation" and neither `loaded` nor
        // `loadFailed` ever fires), which would leave the walk stuck forever on
        // the first file. One event-loop tick is enough.
        Qt.callLater(root.readNextRuleFile);
    }

    function readNextRuleFile() {
        if (!root.ruleWalkRunning)
            return;
        let next = root.ruleWalk.shift();
        while (next && root.ruleFiles[next.path] !== undefined)
            next = root.ruleWalk.shift();
        if (!next) {
            root.finishRuleWalk();
            return;
        }
        root.ruleCurrent = next;
        ruleFileReader.path = next.path;
    }

    function onRuleFileRead(path, text) {
        const item = root.ruleCurrent;
        const depth = item ? item.depth : 0;
        root.ruleFiles[path] = text;
        if (text !== null && depth < root.ruleWalkMaxDepth
            && Object.keys(root.ruleFiles).length < root.ruleWalkMaxFiles) {
            for (const inc of CompositorRules.findIncludes(text))
                root.ruleWalk.push({ path: CompositorRules.resolveInclude(path, inc), depth: depth + 1 });
        }
        // Not `root.readNextRuleFile()` directly: assigning a new `path` while
        // still inside the previous load's signal handler makes Quickshell drop
        // that new operation and re-emit the old file instead ("got operation
        // finished from dropped operation"), which stalls the walk on file one.
        // Reproduced in a standalone probe: the walk completes, eleven files,
        // no warning, once this is deferred.
        Qt.callLater(root.readNextRuleFile);
    }

    function finishRuleWalk() {
        root.ruleWalkRunning = false;
        const result = CompositorRules.evaluate(root.ruleFiles);
        root.layerRuleCheck = result;
        if (result.state === "ok") {
            console.info("Depthscape: niri layer-rule places all surfaces in the backdrop ("
                + result.filesRead + " config file(s) checked)");
        } else if (result.state === "partial" || result.state === "missing") {
            console.warn("Depthscape: niri shared-backdrop rule does not cover all surfaces; "
                + "add a rule matching ^depthscape: with place-within-backdrop true");
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
        else if (action.startsWith("installForce:"))
            installModel(action.substring(13), true);
        else if (action.startsWith("install:"))
            installModel(action.substring(8));
        else if (action === "uninstall")
            uninstallData();
        else if (action === "rescanEngine")
            rescanEngine();
        else if (action === "downloadEngine")
            downloadPrebuiltEngine();
        else if (action === "generate")
            enqueueAll();
        else if (action === "clearCache")
            clearCache();
        else if (action === "resetDefaults")
            resetAllDefaults();
        return true;
    }

    function resetAllDefaults() {
        _lastParametersSignature = "";
        syncParameters();
    }

    // The `dms ipc call depthscape` surface lives in its own file so the RPC
    // contract is auditable in one place; this wiring hands it the daemon root
    // it needs to reach state, and it stays a plain sibling type resolved
    // through the same-directory lookup.
    DepthIpcCommands {
        daemon: root
    }

    Timer {
        id: wallpaperSettle
        interval: 400
        onTriggered: root.restackForeground()
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
            root.syncFillMode();
        }

        function onMonitorWallpaperFillModesChanged() {
            root.syncFillMode();
        }
    }

    // Re-stack only DepthForeground (without destroying surfaces or unloading
    // GPU textures) when desktop widgets finish editing or rebuild their layer order.
    property bool foregroundRestacking: false
    property bool _bouncingWidgets: false

    function restackForeground() {
        if (!root.surfacesMapped)
            return;
        root.foregroundRestacking = true;
        foregroundRestackTimer.restart();
    }

    Timer {
        id: foregroundRestackTimer
        interval: 32
        repeat: false
        onTriggered: root.foregroundRestacking = false
    }

    function hasBackgroundDesktopWidgets() {
        const instances = SettingsData.desktopWidgetInstances || [];
        for (const inst of instances) {
            if (!inst || !inst.enabled)
                continue;
            const rawLayer = (inst.config && inst.config.layer) ? inst.config.layer : "";
            if (rawLayer === "background" || rawLayer === "wallpaper")
                return true;
        }
        return false;
    }

    function scheduleDesktopWidgetRestack() {
        if (!CompositorService.isNiri || !root.hasBackgroundDesktopWidgets())
            return;
        desktopWidgetRestackDebounce.restart();
    }

    Timer {
        id: desktopWidgetRestackDebounce
        interval: 48
        repeat: false
        onTriggered: root._bounceDesktopWidgets()
    }

    property var _widgetRestoreTarget: null

    Timer {
        id: desktopWidgetRestoreTimer
        interval: 16
        repeat: false
        onTriggered: {
            const orig = root._widgetRestoreTarget;
            root._widgetRestoreTarget = null;
            if (orig !== null && Array.isArray(SettingsData.desktopWidgetInstances)) {
                const filtered = SettingsData.desktopWidgetInstances.filter(
                    inst => inst && inst.id !== "__depthscape_restack__");
                SettingsData.desktopWidgetInstances = filtered.length === orig.length ? orig : filtered;
            }
            root._bouncingWidgets = false;
        }
    }

    function _bounceDesktopWidgets() {
        if (root._bouncingWidgets || !root.hasBackgroundDesktopWidgets())
            return;
        const original = SettingsData.desktopWidgetInstances;
        if (!Array.isArray(original))
            return;
        root._bouncingWidgets = true;
        root._widgetRestoreTarget = original;
        const temp = original.slice();
        temp.push({
            "id": "__depthscape_restack__",
            "widgetType": "desktopClock",
            "enabled": false,
            "config": { "layer": "background", "displayPreferences": ["none"] }
        });
        SettingsData.desktopWidgetInstances = temp;
        desktopWidgetRestoreTimer.restart();
    }

    // Matches DesktopWidgetLayer.qml's orderSignature + pluginReadyKey (both of
    // which trigger DesktopWidgetLayer's 150ms + 32ms widget surface rebuild).
    readonly property string widgetOrderSignature: {
        const instances = SettingsData.desktopWidgetInstances || [];
        const comps = (typeof PluginService !== "undefined" && PluginService.pluginDesktopComponents)
            ? PluginService.pluginDesktopComponents : {};
        let sig = "";
        for (const inst of instances) {
            const cfg = (inst && inst.config) ? inst.config : {};
            const prefs = cfg.displayPreferences ? cfg.displayPreferences : ["all"];
            const prefsKey = Array.isArray(prefs) ? prefs.join(",") : "all";
            const layer = cfg.layer ? cfg.layer : (cfg.showOnOverlay ? "overlay" : "bottom");
            sig += inst.id + ":" + (inst.enabled ? "1" : "0") + ":" + layer + ":" + prefsKey + "|";
            if (inst.enabled && inst.widgetType !== "desktopClock" && inst.widgetType !== "systemMonitor")
                sig += "p:" + inst.widgetType + (comps[inst.widgetType] ? ":1" : ":0") + "|";
        }
        return sig;
    }

    readonly property bool restackPending: desktopWidgetRestackDebounce.running
        || desktopWidgetRestoreTimer.running
        || widgetOrderTimer.running
        || root.foregroundRestacking

    onWidgetOrderSignatureChanged: {
        widgetOrderTimer.restart();
    }

    Timer {
        id: widgetOrderTimer
        interval: 450
        repeat: false
        onTriggered: root.restackForeground()
    }

    Connections {
        target: SettingsData
        function onWallpaperFillModeChanged() {
            root.syncFillMode();
        }
    }

    Connections {
        target: (typeof DesktopWidgetRegistry !== "undefined") ? DesktopWidgetRegistry : null
        function onEditingChanged() {
            if (typeof DesktopWidgetRegistry !== "undefined" && !DesktopWidgetRegistry.editing) {
                root.restackForeground();
            }
        }
    }

    function syncFillMode() {
        if (active && SessionData.getMonitorWallpaperFillMode(active.screenName) !== "Fill")
            analyzeProcess.running = false;
        syncOutputs();
        wallpaperSettle.restart();
    }

    function allParametersSignature() {
        let sig = root.modelType + ":" + root.spatialModel;
        const screens = Quickshell.screens ?? [];
        for (let i = 0; i < screens.length; i++)
            sig += "|" + screens[i].name + ":" + parametersKeyFor(screens[i].name);
        return sig;
    }

    property string _lastParametersSignature: allParametersSignature()
    property string _lastModelType: modelType

    Connections {
        target: pluginService

        function onPluginDataChanged(changedId) {
            if (changedId !== root.pluginId)
                return;

            // A pending action is not a settings change: dispatching one must
            // not also invalidate every cached pair.
            if (root.consumeAction())
                return;

            if (root.modelType !== root._lastModelType) {
                root._lastModelType = root.modelType;
                root._lastParametersSignature = root.allParametersSignature();
                if (setupProcess.running)
                    setupProcess.running = false;
                root.checkModel();
                return;
            }

            // Only re-run the engine when the parameters that actually change the
            // mask moved. A toggle that does not feed the mask must not make the
            // surfaces flash.
            const currentSig = root.allParametersSignature();
            if (currentSig !== root._lastParametersSignature) {
                root._lastParametersSignature = currentSig;
                root.syncParameters();
            }
        }
    }

    Connections {
        target: Quickshell

        function onScreensChanged() {
            root.syncOutputs();
        }
    }

    Connections {
        target: DMSService
        ignoreUnknownSignals: true

        function onDepthscapeStateUpdate(data) {
            if (root.modelReady || root.modelBusy || statusProcess.running)
                return;
            const states = (data && data.outputs) ? data.outputs : {};
            if (root.nativeWallpaperOutputs.some(name => states[name] && states[name].status === "ready"))
                root.checkModel();
        }
    }

    // ------------------------------------------------------- surface composition
    //
    // Let the native DMS image map first. Native remains a fallback underneath;
    // all visible plugin images share the backdrop, not the workspace cards.
    property bool surfacesMapped: false

    // --------------------------------------------------------------- reveal curtain
    //
    // The plugin maps its surfaces long before they are worth looking at:
    // the backdrop Image is still decoding and the depth mask is still being
    // computed by the engine, which on a cold first run (model resolve + CPU
    // inference) takes seconds. Showing anything in that window exposes a flat
    // colour wash, then un-masked widgets, then a hard "pop" when the mask
    // finally cuts them. So all visible surfaces stay transparent until the whole
    // composite is genuinely ready, then rise together in one fade.
    //
    // `revealedOnce` is a LATCH: it only ever goes false -> true, so a later
    // wallpaper, threshold or `remap()` never re-drops the curtain (that would
    // make the plugin visibly blink on every edit). Only the FIRST presentation
    // is staged; after that the surfaces track live state directly.
    readonly property int revealTimeoutMs: 6000
    property bool revealedOnce: false
    property int revealStartedAt: 0
    // outputName -> true once that output's wallpaper Image reported Ready. A
    // ready mask is not by itself enough: the wallpaper behind it still has to
    // have decoded, or the fade reveals a flat colour rectangle.
    property var backdropReadySet: ({})

    function markBackdropReady(screenName) {
        const set = root.backdropReadySet;
        if (set[screenName] === true)
            return;
        set[screenName] = true;
        root.backdropReadySet = set;
        root.evaluateReveal();
    }

    // Every output that has a wallpaper must have BOTH its backdrop decoded
    // and its mask generated before we reveal. Outputs with no wallpaper (solid
    // colour, or none set) have nothing to wait for and are skipped.
    function allOutputsRevealReady() {
        const names = Object.keys(root.outputs);
        if (names.length === 0)
            return false;
        let sawWallpaper = false;
        for (const name of names) {
            const row = root.outputs[name];
            if (root.usesNativeWallpaper(name) || !row || !row.wallpaper)
                continue;
            sawWallpaper = true;
            if (root.effectEnabledFor(name) && root.maskFor(name) === "")
                return false;
            if (root.backdropReadySet[name] !== true)
                return false;
        }
        return sawWallpaper;
    }

    function evaluateReveal() {
        if (root.revealedOnce || !root.surfacesMapped)
            return;
        if (root.revealStartedAt === 0)
            root.revealStartedAt = Date.now();
        if (root.allOutputsRevealReady()) {
            root.revealedOnce = true;
            return;
        }
        // Safety net: never leave the desktop showing nothing because the
        // engine stalled or the model is missing. Reveal what we have anyway.
        if (Date.now() - root.revealStartedAt > root.revealTimeoutMs)
            root.revealedOnce = true;
    }

    onSurfacesMappedChanged: if (surfacesMapped) root.evaluateReveal();

    // Poll while the curtain is still down. The mask-ready and backdrop-ready
    // events both also call evaluateReveal directly, so this only needs to
    // catch the timeout and any state change that missed a signal.
    Timer {
        id: revealWatchdog

        running: root.surfacesMapped && !root.revealedOnce && CompositorService.isNiri
        interval: 200
        repeat: true
        triggeredOnStart: true
        onTriggered: root.evaluateReveal()
    }

    Timer {
        id: startupMapTimer
        interval: NiriService.hasInitialConnection ? 100 : 1400
        running: true
        onTriggered: root.surfacesMapped = true
    }

    Connections {
        target: NiriService
        function onHasInitialConnectionChanged() {
            if (NiriService.hasInitialConnection && !root.surfacesMapped) {
                startupMapTimer.interval = 1200;
                startupMapTimer.restart();
            }
        }
    }

    function remap() {
        surfacesMapped = false;
        remapTimer.restart();
    }

    Timer {
        id: remapTimer
        interval: 32
        repeat: false
        onTriggered: {
            root.surfaceGroups = [];
            root.surfacesMapped = true;
            stageTimer.restart();
        }
    }

    Loader {
        id: surfaceLoader

        active: root.surfacesMapped && CompositorService.isNiri
        sourceComponent: Component {
            Variants {
                model: (Quickshell.screens || []).filter(screen => !root.usesNativeWallpaper(screen.name))

                delegate: Item {
                    id: surfaces

                    required property var modelData

                    readonly property string screenName: surfaces.modelData.name
                    readonly property bool screenEffectEnabled: root.effectEnabledFor(screenName)
                    readonly property bool screenParallax: root.parallaxEnabledFor(screenName)
                    readonly property bool screenSpatial: root.spatialEnabledFor(screenName)
                    readonly property int screenMaxTravelPercent: root.parallaxMaxTravelPercentFor(screenName)
                    readonly property int screenStepPercent: root.parallaxStepPercentFor(screenName)
                    readonly property int screenStepHPercent: root.parallaxStepHorizontalPercentFor(screenName)
                    readonly property int screenWidgetStrength: root.parallaxWidgetStrengthFor(screenName)
                    readonly property bool screenInverted: root.parallaxInvertedFor(screenName)
                    readonly property real screenMaxTravel: screenMaxTravelPercent / 100
                    readonly property real screenSpatialTravel: screenSpatial
                        ? root.spatialTravelPercentFor(screenName) / 100 : 0
                    readonly property real screenCanvasTravel: screenParallax ? screenMaxTravel : 0
                    readonly property bool screenSpatialAssetsExist: screenSpatial
                        && root.spatialBackgroundFor(screenName) !== ""
                        && root.spatialForegroundFor(screenName) !== ""
                        && root.spatialDepthFor(screenName) !== ""
                        && root.spatialMatteFor(screenName) !== ""
                        && root.spatialInfluenceFor(screenName) !== ""
                    readonly property bool bothSpatialScenesReady: screenSpatialAssetsExist
                        && wallpaperSurface.spatialSceneReady
                        && foregroundSurface.spatialSceneReady
                    property bool spatialDisplayActive: false

                    Timer {
                        id: spatialWarmupTimer
                        interval: 48
                        repeat: false
                        onTriggered: {
                            if (surfaces.bothSpatialScenesReady && !root.restackPending)
                                surfaces.spatialDisplayActive = true;
                        }
                    }

                    Connections {
                        target: root
                        function onRestackPendingChanged() {
                            if (!root.restackPending && surfaces.bothSpatialScenesReady && !surfaces.spatialDisplayActive)
                                spatialWarmupTimer.restart();
                        }
                    }

                    onBothSpatialScenesReadyChanged: {
                        if (!bothSpatialScenesReady) {
                            spatialWarmupTimer.stop();
                            spatialDisplayActive = false;
                        } else if (!root.restackPending) {
                            spatialWarmupTimer.restart();
                        }
                    }

                    onScreenEffectEnabledChanged: {
                        if (!surfaces.showWallpaper)
                            return;
                        if (screenEffectEnabled)
                            root.restackForeground();
                        else
                            root.scheduleDesktopWidgetRestack();
                    }

                    readonly property real screenStep: screenStepPercent / 100
                    readonly property real screenStepH: screenStepHPercent / 100

                    // The workspace tracker for this output. Event-driven: it
                    // reacts to NiriService's change signals (one coalesced
                    // sync per event-loop turn) and never polls. The offset
                    // bindings below are the only thing the surfaces see.
                    DepthWorkspaceTracker {
                        id: tracker

                        outputName: surfaces.modelData.name
                        viewportWidth: surfaces.modelData.width
                        viewportHeight: surfaces.modelData.height
                        stepY: surfaces.screenStep
                        stepX: surfaces.screenStepH
                        maxTravel: surfaces.screenMaxTravel
                        inverted: surfaces.screenInverted
                    }

                    // The offset the surfaces slide by. Zero while parallax is
                    // off — which also collapses both canvases back to the
                    // plain screen size, so a disabled feature costs no
                    // texture memory.
                    readonly property real canvasOffsetX: surfaces.screenParallax ? tracker.offsetX : 0
                    readonly property real canvasOffsetY: surfaces.screenParallax ? tracker.offsetY : 0

                    // The widgets' EXTRA drift on top of the canvas offset —
                    // the parallax proper. The mask stays canvas-pinned, so
                    // this is what makes the widgets overtake the wallpaper
                    // and slip behind the subject. Zero while parallax is off.
                    readonly property real widgetOffsetX: surfaces.screenParallax
                        ? tracker.offsetX * surfaces.screenWidgetStrength / 100 : 0
                    readonly property real widgetOffsetY: surfaces.screenParallax
                        ? tracker.offsetY * surfaces.screenWidgetStrength / 100 : 0

                    // TWO SURFACES, mapped in dependency order.
                    //
                    //   1. the wallpaper, drawn on the sliding canvas
                    //   2. the desktop widgets, erased by the occlusion mask
                    //
                    // There is no third surface. The subject is not drawn as its
                    // own layer: where the mask is set the widget is erased, and
                    // the wallpaper underneath — which already shows the subject
                    // — comes through. That is the same arrangement the reference
                    // implementation uses, and it is why nothing has to be
                    // inpainted: no layer has to invent what the subject was
                    // covering, so no blurred fill can leak into an edge.
                    //
                    // The canvas offset the wallpaper and the mask ride with.
                    // The mask was cut from the wallpaper, so wallpaper and
                    // mask translate as one rigid body — that alignment is
                    // what keeps the erase region pinned to the subject. The
                    // widgets are the exception: they get an EXTRA drift on
                    // top (`widgetOffset*` above), moving faster than the
                    // wallpaper the way anything nearer the camera does, and
                    // diving behind the subject wherever the mask erases them.
                    //
                    // The order still matters, and it is still established by map
                    // order: the three surfaces are on the `background` layer,
                    // so the one mapped last draws on top. Handing the compositor
                    // one window per tick is what makes that order deterministic.
                    onWantWallpaperChanged: {
                        if (wantWallpaper && stage > 0) {
                            stage = 0;
                            stageTimer.restart();
                        }
                    }

                    onShowWallpaperChanged: {
                        if (showWallpaper)
                            root.scheduleDesktopWidgetRestack();
                    }

                    onWantedChanged: {
                        if (wanted === 0) {
                            stage = 0;
                            return;
                        }
                        if (stage > wanted)
                            stage = wanted;
                        if (stage < wanted) {
                            stageTimer.restart();
                        }
                    }

                    // Which surfaces of this output are mapped so far. 0 = none.
                    // Advanced by `stageTimer`, one step at a time.
                    property int stage: 0

                    readonly property bool wantWallpaper: (root.drawWallpaper || screenSpatial || screenParallax)
                        && root.wallpaperFor(modelData.name) !== ""
                    readonly property bool wantForeground: (screenEffectEnabled || screenSpatial)
                        && root.wallpaperFor(modelData.name) !== ""
                    readonly property int wanted: (wantWallpaper ? 1 : 0) + (wantForeground ? 1 : 0)

                    // One surface per tick, in dependency order.
                    readonly property bool showWallpaper: stage >= 1 && wantWallpaper
                    readonly property bool showForeground: stage >= (wantWallpaper ? 2 : 1) && wantForeground

                    // The delegates have no stable id to address them by, and
                    // `Variants` is a C++ type whose internals are not part of its
                    // contract, so the group registers itself instead of being
                    // searched for.
                    readonly property alias trackerRef: tracker
                    readonly property alias wallpaperRef: wallpaperSurface
                    readonly property alias foregroundRef: foregroundSurface
                    readonly property alias spatialInputRef: spatialInput
                    Component.onCompleted: {
                        root.surfaceGroups.push(surfaces);
                        if (!surfaces.screenEffectEnabled && !surfaces.screenSpatial)
                            root.markBackdropReady(surfaces.screenName);
                        if (surfaces.stage < surfaces.wanted)
                            stageTimer.restart();
                    }
                    Component.onDestruction: {
                        const at = root.surfaceGroups.indexOf(surfaces);
                        if (at >= 0)
                            root.surfaceGroups.splice(at, 1);
                    }

                    DepthSpatialInput {
                        id: spatialInput
                        targetScreen: surfaces.modelData
                        trackingEnabled: surfaces.screenSpatial && surfaces.showWallpaper && !NiriService.inOverview
                    }

                    // 1. Bottom: The wallpaper, on the sliding canvas in the shared backdrop.
                    DepthWallpaper {
                        id: wallpaperSurface
                        targetScreen: surfaces.modelData
                        wallpaperPath: surfaces.showWallpaper
                            ? root.wallpaperFor(surfaces.modelData.name)
                            : ""
                        imageWidth: root.sourceWidthFor(surfaces.screenName)
                        imageHeight: root.sourceHeightFor(surfaces.screenName)
                        visible: surfaces.showWallpaper
                        revealed: root.revealedOnce
                        onBackdropReady: root.markBackdropReady(surfaces.modelData.name)
                        parallaxEnabled: surfaces.screenParallax
                        maxTravel: surfaces.screenMaxTravel
                        spatialEnabled: surfaces.screenSpatial
                        spatialAssetsReady: surfaces.screenSpatialAssetsExist
                        spatialDisplayActive: surfaces.spatialDisplayActive
                        spatialBackgroundPath: root.spatialBackgroundFor(surfaces.screenName)
                        spatialForegroundPath: root.spatialForegroundFor(surfaces.screenName)
                        spatialDepthPath: root.spatialDepthFor(surfaces.screenName)
                        spatialMattePath: root.spatialMatteFor(surfaces.screenName)
                        spatialInfluencePath: root.spatialInfluenceFor(surfaces.screenName)
                        spatialPointerX: spatialInput.pointerX
                        spatialPointerY: spatialInput.pointerY
                        spatialTravel: surfaces.screenSpatialTravel
                        motionDuration: root.parallaxDuration
                        offsetX: surfaces.canvasOffsetX
                        offsetY: surfaces.canvasOffsetY
                    }

                    // 2. Top: The foreground layer (depth-masked subject or 3D mesh).
                    // Mapped on top of WlrLayer.Background, so native desktop widgets
                    // set to layer: "background" render underneath it when occlusion is enabled.
                    DepthForeground {
                        id: foregroundSurface
                        targetScreen: surfaces.modelData
                        wallpaperPath: root.wallpaperFor(surfaces.screenName)
                        maskPath: surfaces.screenEffectEnabled
                            ? root.maskFor(surfaces.screenName)
                            : ""
                        bbox: root.bboxFor(surfaces.screenName)
                        imageWidth: root.sourceWidthFor(surfaces.screenName)
                        imageHeight: root.sourceHeightFor(surfaces.screenName)
                        foregroundPath: root.spatialForegroundFor(surfaces.screenName)
                        backgroundPath: root.spatialBackgroundFor(surfaces.screenName)
                        depthPath: root.spatialDepthFor(surfaces.screenName)
                        mattePath: root.spatialMatteFor(surfaces.screenName)
                        influencePath: root.spatialInfluenceFor(surfaces.screenName)
                        spatialEnabled: surfaces.screenSpatial
                        spatialAssetsReady: surfaces.screenSpatialAssetsExist
                        spatialDisplayActive: surfaces.spatialDisplayActive
                        pointerX: spatialInput.pointerX
                        pointerY: spatialInput.pointerY
                        spatialTravel: surfaces.screenSpatialTravel
                        outputAspect: surfaces.modelData.width / Math.max(1, surfaces.modelData.height)
                        effectEnabled: surfaces.screenEffectEnabled
                        visible: surfaces.showForeground
                            && (!root.foregroundRestacking || !surfaces.screenEffectEnabled)
                            && (surfaces.screenEffectEnabled || surfaces.screenSpatial)
                            && (foregroundPath !== "" || wallpaperPath !== "")
                        revealed: root.revealedOnce
                        maxTravel: surfaces.screenCanvasTravel
                        offsetX: surfaces.canvasOffsetX
                        offsetY: surfaces.canvasOffsetY
                        onForegroundReady: {
                            root.markBackdropReady(surfaces.screenName);
                        }
                    }
                }
            }
        }
    }

    // Walks every output's group from stage 0 to wanted, one surface per tick.
    Timer {
        id: stageTimer

        interval: 32
        repeat: true
        onTriggered: {
            let advanced = false;
            for (const group of root.surfaceGroups) {
                if (group.stage < group.wanted) {
                    group.stage += 1;
                    advanced = true;
                }
            }
            if (!advanced)
                stageTimer.stop();
        }
    }

    Component.onCompleted: {
        if (pluginService && pluginService.pluginInstances && !pluginService.pluginInstances[pluginId]) {
            const newInstances = Object.assign({}, pluginService.pluginInstances);
            newInstances[pluginId] = root;
            pluginService.pluginInstances = newInstances;
        }
        root.loadInitialOutputs();
        root.checkCompositorLayerRule();
        // A button pressed while the settings page was waiting for the daemon
        // leaves an `action` in plugin data. Replay it once at startup instead
        // of leaving it stranded until the next unrelated settings change.
        Qt.callLater(root.consumeAction);
        console.info("Depthscape: daemon started");
    }

    Component.onDestruction: {
        if (pluginService && pluginService.pluginInstances && pluginService.pluginInstances[pluginId] === root) {
            const newInstances = Object.assign({}, pluginService.pluginInstances);
            delete newInstances[pluginId];
            pluginService.pluginInstances = newInstances;
        }
        console.info("Depthscape: daemon stopped");
    }
}
