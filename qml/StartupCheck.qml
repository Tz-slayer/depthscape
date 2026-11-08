import QtQuick
import qs.Common
import qs.Services

// First-run gate for the plugin.
//
// The Rust engine is built separately from the QML that the plugin store
// installs, so a fresh install almost never has the binary yet. Blocking
// activation here used to make the plugin impossible to enable: the user saw a
// build error, but the settings page (the only place that can explain what to
// do next, and now the only place that can trigger a model download) belongs
// to a disabled daemon and never appeared.
//
// So the check is advisory: activation always succeeds, and the daemon stays
// idle until `enginePath` resolves. A warning toast points at the exact build
// command, and the settings page shows the same state as a first-run step.
//
// The old Qt5Compat.GraphicalEffects check was removed: no QML file imports
// that module any more (the mask is applied with MultiEffect / shaders), so it
// only ever produced a false "dependency missing" block.
QtObject {
    id: root

    readonly property string pluginDir: Qt.resolvedUrl("..").toString().replace(/^file:\/\//, "")

    function check(done) {
        Proc.runCommand("depthscape.startupCheck", [
            "sh", "-c",
            'if [ -n "$DEPTHSCAPE_ENGINE" ] && [ -x "$DEPTHSCAPE_ENGINE" ]; then ' +
            '  echo ok; ' +
            'elif [ -x "$1/engine/target/release/depthscape-engine" ]; then ' +
            '  echo ok; ' +
            'elif [ -x "$1/engine/target/debug/depthscape-engine" ]; then ' +
            '  echo ok; ' +
            'elif command -v depthscape-engine > /dev/null; then ' +
            '  echo ok; ' +
            'else ' +
            '  echo missing; ' +
            'fi',
            "sh", root.pluginDir
        ], (stdout, exitCode) => {
            // Never block activation: a missing engine is a first-run setup
            // step, not a reason to hide the plugin's own setup UI.
            done(null);
            if (stdout.trim() !== "ok") {
                const command = "cd " + root.pluginDir.replace(/\/$/, "") + "/engine && cargo build --release";
                console.warn("Depthscape: engine binary missing. Build it with: " + command);
                if (typeof ToastService !== "undefined" && ToastService.showWarning) {
                    ToastService.showWarning(
                        I18n.tr("Depthscape: engine not built yet"),
                        I18n.tr("Build it once, then press Re-check Engine in the plugin settings."),
                        command, "depthscape-engine-missing");
                }
            }
        });
    }
}
