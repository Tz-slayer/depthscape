import QtQuick
import Quickshell
import Quickshell.Io
import "DepthScrollMath.js" as ScrollMath

// Turns the compositor's navigation grid into a parallax offset.
//
// ONE CONTROLLER PER OUTPUT. Workspaces belong to an output, so the vertical
// position is per-output by construction; switching focus to another monitor
// must not move this one's wallpaper.
//
// TWO INDEPENDENT AXES, each with its own accumulator:
//
//   * vertical   -- the workspace stack (focus-workspace-up / -down)
//   * horizontal -- the column focus (focus-column-left / -right)
//
// They are separate because they answer to different keys. A workspace switch
// moves the focused window to a different column as a side effect; folding that
// into the horizontal accumulator would make one keypress scroll both ways at
// once, which reads as a bug rather than as depth.
//
// The offsets are a *position*, not an event: navigating back returns the scene
// to exactly where it began.
//
// WHY THIS POLLS `niri msg` INSTEAD OF READING `NiriService`
//
// It would be natural to read `NiriService.allWorkspaces` and hang the updates
// off its change signals -- the reference implementation does exactly that, and
// DMS's own wallpaper reads the same services. In a plugin daemon it does not
// work, and the failure is silent enough to be worth recording:
//
//   * `services()` on the daemon itself reports `isNiri: true`, three
//     workspaces and nine windows.
//   * The identical expressions evaluated *inside a child object of that same
//     daemon* report `isNiri: false` and zero.
//   * And the change signals never arrive at all: counters incremented in
//     `onAllWorkspacesChanged` / `onWindowsChanged` sat at 0 across a workspace
//     switch.
//
// So the plugin's view of the service singletons is not merely reduced, it is
// inconsistent between an object and its own parent. Polling is the mechanism
// already proven in this plugin for the same class of problem -- the overview
// probe does it -- so it is used here too rather than fought with.
//
// The cost is one short-lived process every 400ms. That is a `niri msg` round
// trip on a socket, and it only runs while the plugin is enabled.
Item {
    id: root

    required property string outputName
    required property real viewportWidth
    required property real viewportHeight

    // ------------------------------------------------------------ parameters

    /// The reserve both axes approach but never reach, as a fraction of that
    /// axis. The oversized canvas is built from this, so it is also the ceiling
    /// on how far the scene can ever travel.
    property real maxTravel: 0.12

    /// The FIRST step as a fraction of the same axis. The curve derives its
    /// deceleration from how this compares to `maxTravel`: at 0.06 against 0.12
    /// a step closes half the remaining distance, so running out of travel reads
    /// as the scenery slowing down rather than hitting a wall.
    property real stepY: 0.060
    property real stepX: 0.080

    property bool inverted: false
    property bool enabled: true

    /// Measurement hooks, for tests and for isolating the rendering from the
    /// window changes real navigation causes. `null` means "follow navigation".
    property var debugOffsetX: null
    property var debugOffsetY: null

    // ---------------------------------------------------------------- outputs

    readonly property real reserveX: Math.max(0, viewportWidth * maxTravel)
    readonly property real reserveY: Math.max(0, viewportHeight * maxTravel)

    /// Vertical offset in output logical pixels. Negative: navigating down the
    /// workspace stack moves the scene up, the way scenery slides past a window
    /// as you travel forward.
    readonly property real offsetY: !enabled ? 0
        : debugOffsetY !== null
            ? ScrollMath.clamp(debugOffsetY, -reserveY, reserveY)
            : ScrollMath.offset(_stepsY, viewportHeight, stepY, reserveY, inverted)

    /// Horizontal offset, same convention.
    readonly property real offsetX: !enabled ? 0
        : debugOffsetX !== null
            ? ScrollMath.clamp(debugOffsetX, -reserveX, reserveX)
            : ScrollMath.offset(_stepsX, viewportWidth, stepX, reserveX, inverted)

    /// Largest reserve either axis carries. The surfaces that need spare area
    /// size it from this rather than from a guess, because two guesses is how a
    /// canvas and its content drift apart.
    readonly property real reserve: Math.max(reserveX, reserveY)

    /// True once both axes have been read at least once. Until then offsets are
    /// held at zero so a slow first frame cannot make the scene twitch.
    readonly property bool ready: _sawWorkspace && _sawColumn

    // --------------------------------------------------------------- internal

    property real _stepsY: 0
    property real _stepsX: 0

    /// The raw step counts, exposed for the daemon's state dump. These are the
    /// accumulated navigation deltas the curve is evaluated against.
    readonly property real verticalSteps: _stepsY
    readonly property real horizontalSteps: _stepsX

    /// Whether each axis has been seeded yet. Exposed for the same reason as the
    /// counts above: "nothing moved" has several possible causes and this is
    /// what tells them apart.
    readonly property bool diagnosticSawWorkspace: _sawWorkspace
    readonly property bool diagnosticSawColumn: _sawColumn

    property bool _sawWorkspace: false
    property bool _sawColumn: false

    /// How many polls have returned a readable workspace list and window list.
    /// A tracker that never moves has two very different possible causes -- the
    /// poll is failing, or the readings are not advancing -- and these tell them
    /// apart without guessing.
    property int diagnosticPolls: 0
    property int diagnosticFailures: 0

    // ---------------------------------------------------------------- polling

    property string _workspaceJson: ""
    property string _windowJson: ""

    Process {
        id: workspaceProbe

        running: root.enabled
        command: ["niri", "msg", "--json", "workspaces"]
        stdout: StdioCollector {
            onStreamFinished: {
                root._workspaceJson = text;
                root._consume();
            }
        }
        onExited: exitCode => {
            if (exitCode !== 0)
                root.diagnosticFailures += 1;
        }
    }

    Process {
        id: windowProbe

        running: root.enabled
        command: ["niri", "msg", "--json", "windows"]
        stdout: StdioCollector {
            onStreamFinished: {
                root._windowJson = text;
                root._consume();
            }
        }
    }

    Timer {
        interval: 400
        running: root.enabled
        repeat: true
        onTriggered: {
            if (!workspaceProbe.running)
                workspaceProbe.running = true;
            if (!windowProbe.running)
                windowProbe.running = true;
        }
    }

    // ---------------------------------------------------------------- parsing

    property var _workspaces: []
    property var _windows: []

    /// Parse both payloads and advance the accumulators.
    ///
    /// The two probes are independent processes and either can land first, so
    /// this is called from both and simply does nothing until both have
    /// something to say. That also means one poll produces at most one step,
    /// which keeps the accumulators from being applied twice per tick.
    function _consume() {
        if (_workspaceJson === "" || _windowJson === "")
            return;
        let workspaces = null;
        let windows = null;
        try {
            workspaces = JSON.parse(_workspaceJson);
            windows = JSON.parse(_windowJson);
        } catch (error) {
            diagnosticFailures += 1;
            return;
        }
        if (!Array.isArray(workspaces) || !Array.isArray(windows))
            return;

        diagnosticPolls += 1;
        _workspaces = workspaces;
        _windows = windows;
        sync();
    }

    // ------------------------------------------------------------------ resets

    function reset() {
        _stepsY = 0;
        _stepsX = 0;
        _sawWorkspace = false;
        _sawColumn = false;
    }

    /// Clear the debug override and follow navigation again.
    function clearDebugOffset() {
        debugOffsetX = null;
        debugOffsetY = null;
    }

    function sync() {
        _syncWorkspace();
        _syncColumn();
    }

    // ------------------------------------------------------------- vertical

    function _syncWorkspace() {
        const next = ScrollMath.update(
            _sawWorkspace ? { id: _lastId, index: _lastWorkspaceIndex, steps: _stepsY } : null,
            _workspaces, outputName);

        // No active workspace on this output (a monitor that has just been
        // enabled, or a workspace list that has not caught up). Hold.
        if (next === null)
            return;

        // The first reading establishes the origin and must not move anything:
        // the helper returns steps 0 for it.
        _stepsY = _sawWorkspace ? next.steps : 0;
        _lastId = next.id;
        _lastWorkspaceIndex = next.index;
        _sawWorkspace = true;
    }

    /// The workspace the accumulator last counted from, as a string. niri's
    /// workspace ids are numbers on the wire but every comparison here is
    /// textual; keeping both sides strings is what makes the comparison work.
    property string _lastId: ""
    property int _lastWorkspaceIndex: -1

    // ----------------------------------------------------------- horizontal

    function _syncColumn() {
        const ids = [];
        for (const workspace of _workspaces) {
            if ((workspace.output || "") === outputName)
                ids.push(String(workspace.id));
        }
        if (ids.length === 0)
            return;

        const current = ScrollMath.activeColumn(_windows, ids);
        if (current === null) {
            // Empty workspace, or focus is on another output. Hold the last
            // position rather than snapping anywhere.
            return;
        }

        if (!_sawColumn) {
            _lastColumn = current.column;
            _lastColumnWorkspace = current.workspaceId;
            _sawColumn = true;
            return;
        }

        // A workspace switch moves focus to a window in a different workspace as
        // a side effect. Re-seed the reference for that case instead of
        // accumulating: the two axes are supposed to answer to two different
        // keys, and one keypress scrolling both ways reads as a bug.
        if (_lastColumnWorkspace !== current.workspaceId) {
            _lastColumnWorkspace = current.workspaceId;
            _lastColumn = current.column;
            return;
        }

        if (current.column === _lastColumn)
            return;

        _stepsX += current.column - _lastColumn;
        _lastColumn = current.column;
    }

    property int _lastColumn: -1

    /// Which workspace the last observed column belonged to. Used to tell a real
    /// column navigation apart from the focus change a workspace switch causes.
    property string _lastColumnWorkspace: ""

    // ------------------------------------------------------------- lifecycle

    // A reconfiguration changes the viewport, and therefore the pixel size of a
    // step. Re-seed rather than integrating a delta measured against the old
    // scale.
    Connections {
        target: Quickshell
        function onScreensChanged() { root.reset(); }
    }

    onOutputNameChanged: {
        root.reset();
        // The probes are re-run rather than waited for: a poll may be in flight
        // against the old output and would otherwise seed this one from it.
        if (workspaceProbe.running)
            workspaceProbe.running = false;
        if (windowProbe.running)
            windowProbe.running = false;
        Qt.callLater(root._restartProbes);
    }

    function _restartProbes() {
        if (!enabled)
            return;
        workspaceProbe.running = true;
        windowProbe.running = true;
    }

    Component.onCompleted: {
        // Nothing to seed yet: the first poll both establishes the origin and
        // reports whether the compositor is even reachable.
    }
}
