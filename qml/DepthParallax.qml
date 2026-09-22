import QtQuick
import qs.Services
import "DepthScrollMath.js" as ScrollMath

// Turns the compositor's navigation grid into a parallax offset.
//
// ONE CONTROLLER PER OUTPUT. Workspaces belong to an output, so the vertical
// position is per-output by construction; switching focus to another monitor
// must not move this one's wallpaper.
//
// TWO INDEPENDENT AXES, each with its own accumulator:
//   * vertical   -- the workspace stack (focus-workspace-up / -down)
//   * horizontal -- the column focus (focus-column-left / -right)
//
// Follows the proven wallpaper-parallax architecture:
// Directly reads NiriService in-process signals (0ms IPC latency),
// computes the raw target offset via ScrollMath, and passes it to the
// render-thread animators on the PanelWindows.
Item {
    id: root

    required property string outputName
    property real viewportWidth: 1920
    property real viewportHeight: 1080

    property real maxTravel: 0.12
    property real stepY: 0.060
    property real stepX: 0.035
    property int motionDuration: 240
    property bool inverted: false
    property bool enabled: true

    property var position: null
    property var column: null

    // Measurement hooks. `null` means "follow navigation".
    property var debugOffsetX: null
    property var debugOffsetY: null

    readonly property bool ready: position !== null
    readonly property real reserveX: Math.max(0, viewportWidth * maxTravel)
    readonly property real reserveY: Math.max(0, viewportHeight * maxTravel)
    readonly property real reserve: Math.max(reserveX, reserveY)

    readonly property real offsetX: debugOffsetX !== null
        ? ScrollMath.clamp(debugOffsetX, -reserveX, reserveX)
        : ScrollMath.offset(column ? column.steps : 0, viewportWidth, stepX, reserveX, inverted)

    readonly property real offsetY: debugOffsetY !== null
        ? ScrollMath.clamp(debugOffsetY, -reserveY, reserveY)
        : ScrollMath.offset(position ? position.steps : 0, viewportHeight, stepY, reserveY, inverted)

    readonly property real verticalSteps: position ? position.steps : 0
    readonly property real horizontalSteps: column ? column.steps : 0

    readonly property bool diagnosticSawWorkspace: ready
    readonly property bool diagnosticSawColumn: column !== null
    property int diagnosticPolls: 1
    property int diagnosticFailures: 0

    function sync() {
        if (!CompositorService.isNiri || !enabled)
            return;
        diagnosticPolls += 1;
        const all = NiriService.allWorkspaces;
        position = ScrollMath.update(position, all, outputName);
        const ids = [];
        for (const workspace of all) {
            if ((workspace.output || "") === outputName)
                ids.push(String(workspace.id));
        }
        column = ScrollMath.updateColumn(column,
            ScrollMath.activeColumn(NiriService.windows, ids));
    }

    function reset() {
        debugOffsetX = null;
        debugOffsetY = null;
        position = null;
        column = null;
        sync();
    }

    function clearDebugOffset() {
        debugOffsetX = null;
        debugOffsetY = null;
    }

    function syncSoon() {
        Qt.callLater(root.sync);
    }

    Connections {
        target: NiriService
        function onAllWorkspacesChanged() { root.syncSoon(); }
        function onWindowsChanged() { root.syncSoon(); }
    }

    Connections {
        target: CompositorService
        function onIsNiriChanged() { root.sync(); }
    }

    onOutputNameChanged: reset()
    Component.onCompleted: sync()
}
