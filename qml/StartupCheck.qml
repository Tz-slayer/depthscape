import QtQuick
import qs.Common

// Gates plugin activation on the two things that would otherwise make the
// plugin fail silently at the first wallpaper change:
//
//   1. the Rust engine binary, which is built separately rather than shipped;
//   2. the Qt5Compat.GraphicalEffects QML module, which qml/DepthForeground.qml
//      imports for OpacityMask. DMS itself does not use that module, so it can
//      legitimately be missing on a machine that runs DMS fine.
QtObject {
    id: root

    readonly property string pluginDir: Qt.resolvedUrl("..").toString().replace(/^file:\/\//, "")

    function check(done) {
        Proc.runCommand("depthscape.startupCheck", [
            "sh", "-c",
            // --- engine ---
            'if [ -n "$DEPTHSCAPE_ENGINE" ] && [ -x "$DEPTHSCAPE_ENGINE" ]; then ' +
            '  engine=ok; ' +
            'elif [ -x "$1/engine/target/release/depthscape-engine" ]; then ' +
            '  engine=ok; ' +
            'elif [ -x "$1/engine/target/debug/depthscape-engine" ]; then ' +
            '  engine=ok; ' +
            'elif command -v depthscape-engine > /dev/null; then ' +
            '  engine=ok; ' +
            'else ' +
            '  engine=missing; ' +
            'fi; ' +
            // --- Qt5Compat.GraphicalEffects ---
            // Prefer the toolkit's own answer, then fall back to the usual roots.
            'qmlroot=""; ' +
            'if command -v qtpaths6 > /dev/null; then ' +
            '  qmlroot=$(qtpaths6 --query QT_INSTALL_QML 2>/dev/null); ' +
            'fi; ' +
            'compat=missing; ' +
            'for base in "$qmlroot" "$QML2_IMPORT_PATH" ' +
            '  /usr/lib/qt6/qml /usr/lib64/qt6/qml /usr/lib/x86_64-linux-gnu/qt6/qml ' +
            '  /usr/lib/aarch64-linux-gnu/qt6/qml /usr/local/lib/qt6/qml; do ' +
            '  [ -n "$base" ] || continue; ' +
            '  if [ -f "$base/Qt5Compat/GraphicalEffects/OpacityMask.qml" ]; then ' +
            '    compat=ok; break; ' +
            '  fi; ' +
            'done; ' +
            'echo "$engine $compat"',
            "sh", root.pluginDir
        ], (stdout, exitCode) => {
            const parts = stdout.trim().split(/\s+/);
            const engine = parts[0] || "missing";
            const compat = parts[1] || "missing";

            if (engine === "missing") {
                done({
                    "title": I18n.tr("Depthscape engine not found"),
                    "details": I18n.tr("Build it with `cargo build --release` inside the engine/ directory, or set DEPTHSCAPE_ENGINE to an existing binary.")
                });
                return;
            }

            if (compat === "missing") {
                done({
                    "title": I18n.tr("Qt5Compat.GraphicalEffects is missing"),
                    "details": I18n.tr("The foreground layer needs the Qt5Compat.GraphicalEffects QML module. Install qt6-5compat (Debian/Ubuntu: qml6-module-qt5compat-graphicaleffects), then restart the shell.")
                });
                return;
            }

            done(null);
        });
    }
}
