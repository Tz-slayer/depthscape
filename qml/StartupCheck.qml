import QtQuick
import qs.Common
import qs.Services

// First-run dependency check for the plugin.
//
// Depthscape uses `curl` to automatically download its prebuilt depth engine
// and on-demand depth models. If `curl` is missing, activation is blocked with
// a clear dependency error.
//
// Prebuilt engine binaries are automatically provisioned by `DepthDaemon` on
// first startup, so manual compilation or scary missing-binary toasts are avoided.
QtObject {
    id: root

    function check(done) {
        Proc.runCommand("depthscape.startupCheck", [
            "sh", "-c",
            'if command -v curl >/dev/null; then echo ok; else echo missing; fi'
        ], (stdout, exitCode) => {
            if (stdout.trim() !== "ok") {
                done({
                    "title": I18n.trFor("depthscape", "curl is required"),
                    "details": I18n.trFor("depthscape", "Depthscape requires curl to automatically download depth models and engine binaries.")
                });
                return;
            }
            done(null);
        });
    }
}
