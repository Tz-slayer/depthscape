import QtQuick
import qs.Services
import "DepthScrollMath.js" as ScrollMath

// One controller per OUTPUT, never per workspace. Switching monitor focus
// does not move or reset any other output's canvas.
//
// EVENT-DRIVEN, NOT POLLED.
//
// The whole input is DMS's NiriService, which keeps a live niri IPC event
// stream (`"EventStream"` over the compositor socket) and exposes the decoded
// state as plain QML properties. This tracker only reacts to those properties'
// change signals — there is no timer anywhere in the parallax path. One
// switch makes niri emit several events (workspace list, window list, focus),
// so `sync` is coalesced with Qt.callLater into at most one run per event-loop
// turn: the array building happens once, not once per event.
//
// Two independent axes, each with its own accumulator:
//
//   * vertical   — the workspace stack (focus-workspace-up / -down)
//   * horizontal — the column focus (focus-column-left / -right)
//
// They are separate because they answer to different keys. A workspace switch
// moves the focused window to a different column as a side effect; folding
// that into the horizontal accumulator would make one keypress scroll both
// ways at once, which reads as a bug rather than as depth.
Item {
    id: root

    required property string outputName
    property real viewportWidth: 1920
    property real viewportHeight: 1080
    // Separate per axis. The vertical one is the gentle, decelerating drift;
    // the horizontal one is deliberately larger, because a column change
    // sweeps a full screen width while a workspace change sweeps a full screen
    // height, and the wider axis reads as under-moving at the same ratio.
    //
    // The ratio step/maxTravel = k's complement, i.e. the fraction of the
    // remaining travel each step consumes. The 0.05/0.25 and 0.06/0.25 pairs
    // below sit that fraction at ~0.20 (k ~= 0.80), so step 8 still visibly
    // moves the canvas and step 16 is still perceptible. The old 0.075/0.15
    // pair (fraction 0.50) halved the travel every step and looked dead after
    // four workspace hops — see DepthScrollMath.offset.
    property real stepY: 0.05
    property real stepX: 0.06
    property real maxTravel: 0.25
    property bool inverted: false

    property var position: null
    property var column: null

    // Measurement hooks. `null` means "follow the workspace/column again".
    property var debugOffsetX: null
    property var debugOffsetY: null

    readonly property bool ready: position !== null
    readonly property real reserveX: Math.max(0, viewportWidth * maxTravel)
    readonly property real reserveY: Math.max(0, viewportHeight * maxTravel)

    readonly property real offsetX: debugOffsetX !== null
        ? ScrollMath.clamp(debugOffsetX, -reserveX, reserveX)
        : ScrollMath.offset(column ? column.steps : 0, viewportWidth, stepX, reserveX, inverted)
    readonly property real offsetY: debugOffsetY !== null
        ? ScrollMath.clamp(debugOffsetY, -reserveY, reserveY)
        : ScrollMath.offset(position ? position.steps : 0, viewportHeight, stepY, reserveY, inverted)

    function sync() {
        if (!NiriService.hasInitialConnection)
            return;
        const all = NiriService.allWorkspaces;
        position = ScrollMath.update(position, all, outputName);
        // The column is only meaningful if focus is on one of this output's
        // workspaces, so the id set has to be rebuilt from the same list.
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

    function syncSoon() {
        Qt.callLater(root.sync);
    }

    Connections {
        target: NiriService
        function onAllWorkspacesChanged() { root.syncSoon(); }
        // Column changes arrive as window-focus changes; see DepthScrollMath.
        function onWindowsChanged() { root.syncSoon(); }
        // The daemon starts before the socket connects; the first state dump
        // arrives through this signal, not through the two above.
        function onHasInitialConnectionChanged() { root.syncSoon(); }
    }
    onOutputNameChanged: reset()
    Component.onCompleted: sync()
}
