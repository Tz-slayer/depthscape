import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

// The `dms ipc call depthscape <cmd>` surface.
//
// Commands:
//   install <name>     Download a model explicitly (nothing downloads on its own).
//   installForce <id>  Re-download a model even when it is already verified.
//   uninstall          Delete every downloaded model and all generated data.
//   rescan             Re-run the engine binary lookup after building it.
//   generate           Requeue every output for analysis.
//   clearCache         Drop every cached depth / refined / mask artefact.
//   remap              Re-attach both surfaces on every output.
//   settings           Instructions for opening plugin settings.
//   settingsProbe      Instantiate the settings page off-screen and report it.
//   debug              Return a stable JSON snapshot of every tunable +
//                      per-output parallax/mask/wallpaper state.
Item {
    id: root

    // The DepthDaemon root, injected by the daemon itself. Untyped to avoid a
    // circular import; the handlers guard on `daemon` being non-null.
    property var daemon: null

    IpcHandler {
        target: "depthscape"

        function install(modelName: string): string {
            if (!root.daemon)
                return "daemon not ready";
            root.daemon.installModel(modelName);
            return "installing model: " + (modelName || root.daemon.modelType);
        }

        function installForce(modelName: string): string {
            if (!root.daemon)
                return "daemon not ready";
            const id = modelName || root.daemon.modelType;
            root.daemon.installModel(id, true);
            return "re-downloading model: " + id;
        }

        function removeModel(modelName: string): string {
            if (!root.daemon)
                return "daemon not ready";
            const id = modelName || root.daemon.modelType;
            root.daemon.removeModel(id);
            return "removing model: " + id;
        }

        function uninstall(): string {
            if (!root.daemon)
                return "daemon not ready";
            root.daemon.uninstallData();
            return "removing Depthscape models and cached data";
        }

        function rescan(): string {
            if (!root.daemon)
                return "daemon not ready";
            root.daemon.rescanEngine();
            return "re-checking for the depthscape-engine binary";
        }

        function downloadEngine(): string {
            if (!root.daemon)
                return "daemon not ready";
            root.daemon.downloadPrebuiltEngine();
            return "downloading prebuilt depth engine";
        }

        function generate(): string {
            if (!root.daemon)
                return "daemon not ready";
            root.daemon.enqueueAll();
            return "queued " + root.daemon.queue.length + " job(s)";
        }

        function clearCache(): string {
            if (!root.daemon)
                return "daemon not ready";
            root.daemon.clearCache();
            return "clearing cache";
        }

        function remap(): string {
            if (!root.daemon)
                return "daemon not ready";
            root.daemon.remap();
            return "remapped";
        }

        function settings(): string {
            return "Depthscape settings are configured in DMS Settings -> Plugins -> Depthscape";
        }

        /// Instantiate the settings page off-screen inside the real shell and
        /// report what actually loaded. qmllint checks syntax, not whether DMS's
        /// components resolve at runtime; an isolated `qs -p` probe cannot bring
        /// up the full DMS service graph. This gives a focus-free live check:
        ///   dms ipc call depthscape settingsProbe
        function settingsProbe(): string {
            const component = Qt.createComponent(Qt.resolvedUrl("DepthSettings.qml?t=" + Date.now()));
            // Component.Ready = 1, Component.Error = 3. Numeric comparison
            // avoids relying on the Component enum being in JS scope here.
            if (component.status === 3) {
                const error = component.errorString();
                component.destroy();
                return JSON.stringify({ "ok": false, "stage": "compile", "error": error });
            }
            if (component.status !== 1) {
                const status = component.status;
                component.destroy();
                return JSON.stringify({ "ok": false, "stage": "compile", "status": status });
            }
            let page = null;
            try {
                // Hand the page the real settings service so its controls load
                // persisted values instead of just their defaults.
                page = component.createObject(null, { "pluginService": PluginService });
                if (!page)
                    return JSON.stringify({ "ok": false, "stage": "create", "error": "createObject returned null" });
                // Controls may be nested (group cards), so walk the whole item
                // tree rather than only the top-level content list.
                const controls = [];
                const walk = node => {
                    if (!node)
                        return;
                    // SectionTitle carries an empty settingKey for its own
                    // collapse persistence — that is not a settings control.
                    if (node.settingKey !== undefined && node.settingKey !== "")
                        controls.push({
                            "key": node.settingKey,
                            "visible": node.visible,
                            "options": node.options ? node.options.length : null,
                            "value": node.value !== undefined ? node.value : (node.currentValue !== undefined ? node.currentValue : null)
                        });
                    const kids = node.children || [];
                    for (let i = 0; i < kids.length; i++)
                        walk(kids[i]);
                };
                walk(page);
                return JSON.stringify({
                    "ok": true,
                    // An off-screen instance never gets a layout pass, so its
                    // implicitHeight is meaningless. Say so rather than report 0.
                    "offscreen": true,
                    "controls": controls,
                    "currentModelType": page.currentModelType,
                    "modelIcons": page.modelIcons,
                    "statusText": page.statusText,
                    "engineCommand": page.engineCommand,
                    "buildCommand": page.buildCommand
                });
            } catch (error) {
                return JSON.stringify({ "ok": false, "stage": "runtime", "error": String(error) });
            } finally {
                if (page)
                    page.destroy();
                component.destroy();
            }
        }

        function renderProbe(screenName: string, outDir: string): string {
            if (!root.daemon || !outDir)
                return JSON.stringify({ "ok": false, "error": "missing daemon or outDir" });
            for (const group of root.daemon.surfaceGroups) {
                if (!group || !group.modelData || group.modelData.name !== screenName)
                    continue;
                const wp = group.wallpaperRef;
                const fg = group.foregroundRef;
                if (wp && wp.canvasItem) {
                    wp.canvasItem.grabToImage(res => {
                        res.saveToFile(outDir + "/live_wp_" + screenName + ".png");
                    }, Qt.size(640, 360));
                }
                if (fg && fg.foregroundItem) {
                    fg.foregroundItem.grabToImage(res => {
                        res.saveToFile(outDir + "/live_fg_" + screenName + ".png");
                    }, Qt.size(640, 360));
                }
                return JSON.stringify({
                    "ok": true,
                    "screen": screenName,
                    "wpVisible": wp ? wp.visible : false,
                    "fgVisible": fg ? fg.visible : false
                });
            }
            return JSON.stringify({ "ok": false, "error": "screen not found" });
        }

        /// Per-screen geometry as the QML side sees it, plus the cap derived
        /// from it. `--max-dimension` and mask sizes are otherwise unexplainable
        /// from the outside.
        function screenDimensions(): string {
            const out = {};
            for (const screen of Quickshell.screens) {
                const dpr = (screen.devicePixelRatio && screen.devicePixelRatio > 0)
                    ? screen.devicePixelRatio : 1;
                out[screen.name] = {
                    "width": screen.width,
                    "height": screen.height,
                    "dpr": dpr,
                    "compositorScale": (CompositorService.getScreenScale ? CompositorService.getScreenScale(screen) : dpr),
                    "scaledLongEdge": root.daemon ? root.daemon.screenScaledLongEdge(screen) : 0
                };
            }
            return JSON.stringify({
                "screens": out,
                "maxDeviceDimension": root.daemon ? root.daemon.maxDeviceDimension() : 0
            });
        }

        function debug(): string {
            if (!root.daemon)
                return JSON.stringify({ "error": "daemon not ready" });
            const screensOut = {};
            for (const screen of Quickshell.screens) {
                screensOut[screen.name] = {
                    "wallpaper": root.daemon.wallpaperFor(screen.name),
                    "mask": root.daemon.maskFor(screen.name),
                    "palette": root.daemon.paletteFor(screen.name),
                    "effectEnabled": root.daemon.effectEnabledFor(screen.name),
                    "displayLayer": root.daemon.displayLayerFor(screen.name),
                    "parallax": {
                        "enabled": root.daemon.parallaxEnabledFor(screen.name),
                        "maxTravelPercent": root.daemon.parallaxMaxTravelPercentFor(screen.name),
                        "stepPercent": root.daemon.parallaxStepPercentFor(screen.name),
                        "stepHPercent": root.daemon.parallaxStepHorizontalPercentFor(screen.name),
                        "inverted": root.daemon.parallaxInvertedFor(screen.name)
                    }
                };
            }
            const parallax = {};
            for (const group of root.daemon.surfaceGroups) {
                if (!group || !group.modelData)
                    continue;
                const tracker = group.trackerRef;
                const wpRef = group.wallpaperRef;
                const fgRef = group.foregroundRef;
                parallax[group.modelData.name] = {
                    "screenName": group.modelData.name,
                    "targetIndex": tracker ? tracker.targetIndex : 0,
                    "targetIndexH": tracker ? tracker.targetIndexH : 0,
                    "stepY": tracker ? tracker.stepY : 0,
                    "stepX": tracker ? tracker.stepX : 0,
                    "offsetX": tracker ? tracker.offsetX : 0,
                    "offsetY": tracker ? tracker.offsetY : 0,
                    "clampedX": tracker ? tracker.clampedX : 0,
                    "clampedY": tracker ? tracker.clampedY : 0,
                    "stage": group.stage,
                    "wanted": group.wanted,
                    "showWallpaper": group.showWallpaper,
                    "showForeground": group.showForeground,
                    "wallpaperVisible": wpRef ? wpRef.visible : false,
                    "foregroundVisible": fgRef ? fgRef.visible : false,
                    "restackPending": root.daemon.restackPending === true,
                    // Which wallpaper/mask pair the foreground layer is actually
                    // painting. The daemon row is replaced atomically and always
                    // pairs correctly, so a visible misalignment can only come
                    // from this internal pair lagging behind it.
                    "fgCurrentWp": fgRef ? fgRef.currentWp : "",
                    "fgCurrentMask": fgRef ? fgRef.currentMask : "",
                    "fgIncomingWp": fgRef ? fgRef.incomingWp : "",
                    "fgIncomingMask": fgRef ? fgRef.incomingMask : "",
                    "fgTransitioning": fgRef ? fgRef.isTransitioning === true : false,
                    "fgProgress": fgRef ? fgRef.transitionProgress : 0,
                    "fgWantedWp": fgRef ? fgRef.wallpaperPath : "",
                    "fgWantedMask": fgRef ? fgRef.maskPath : "",
                    "fgStatus": fgRef ? {
                        "incomingWp": fgRef.incomingWpStatus,
                        "incomingMask": fgRef.incomingMaskStatus,
                        "currentWp": fgRef.currentWpStatus,
                        "currentMask": fgRef.currentMaskStatus
                    } : null,
                };
            }
            return JSON.stringify({
                "ready": root.daemon.modelReady,
                "modelType": root.daemon.modelType,
                "modelBusy": root.daemon.modelBusy,
                "availableModels": root.daemon.availableModels,
                "enginePath": root.daemon.enginePath,
                "dataRoot": root.daemon.dataRoot,
                "niriLayerRule": root.daemon.layerRuleCheck,
                "screens": screensOut,
                "parallax": parallax
            });
        }
    }
}
