import QtQuick
import qs.Common

// Gates plugin activation on the one thing that would otherwise make the plugin
// fail silently at the first wallpaper change: the Rust engine binary, which is
// built separately rather than shipped.
//
// This used to also check for the Qt5Compat.GraphicalEffects QML module, which
// the old foreground layer imported for OpacityMask. The engine now emits a
// straight-alpha RGBA image, so compositing it needs nothing beyond a plain
// Image — and the check, the dependency and the module are all gone.
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
            if (stdout.trim() === "ok") {
                done(null);
                return;
            }
            done({
                "title": I18n.tr("Depthscape engine not found"),
                "details": I18n.tr("Build it with `cargo build --release` inside the engine/ directory, or set DEPTHSCAPE_ENGINE to an existing binary.")
            });
        });
    }
}
