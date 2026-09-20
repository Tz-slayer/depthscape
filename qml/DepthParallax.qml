import QtQuick
import Quickshell
import qs.Services

// Tracks where the user is in the compositor's navigation grid and turns that
// into a parallax offset.
//
// The offset is a *position*, not an event. Switching to workspace 3 and back
// to workspace 1 returns the scene to where it started, exactly as a scroll
// position would. That is why this item derives the offset from the navigation
// index rather than animating on every keypress: nothing here needs to know
// that a key was pressed at all.
//
// Both axes are driven by navigation the user performs:
//
//   * vertical   — workspace changes (`focus-workspace-up` / `-down`)
//   * horizontal — column changes (`focus-column-left` / `-right`)
//
// DMS's NiriService already tracks both, so this reads from it rather than
// spawning `niri msg` processes of its own.
//
// WHY `NiriService` AND NOT A NIRI-SPECIFIC SHORTCUT
//
// NiriService exposes `allWorkspaces` (sorted by `idx`) and a focused index,
// which is the vertical input. For the horizontal input it exposes `windows`
// with `layout.pos_in_scrolling_layout`, whose first element is the column
// number. Both are already maintained by the shell; duplicating them here would
// mean a second event stream and a second source of truth.
//
// CompositorService gates the whole thing so the plugin degrades to "no
// parallax" rather than a broken binding on a compositor with no such concept.
Item {
    id: root

    // ------------------------------------------------------------- parameters

    // Vertical travel per workspace step, as a fraction of the output height.
    // At the defaults a jump of eight workspaces moves the scene by about a
    // sixth of the screen, which is large enough to read as depth and small
    // enough that the wallpaper never looks like it is being dragged away.
    property real verticalStep: 0.020
    property real horizontalStep: 0.015

    // How far the background travels relative to the foreground. Below 1 the
    // background lags, which is what produces the depth cue: the foreground is
    // nearer the viewer, so it sweeps further for the same navigation. Set to 0
    // to pin the background and move only the foreground.
    property real backgroundRatio: 0.35

    property bool enabled: true

    // Ceiling on how far the scene may travel from its resting position, as a
    // fraction of the output's larger dimension.
    //
    // The offset accumulates, so without a limit a user who changes workspace
    // twenty times ends up with the wallpaper dragged far off-centre and the
    // foreground covering a region it was never cut from. Clamping keeps the
    // effect legible no matter how much navigating happens, and it also bounds
    // the oversized box the background layer needs.
    property real maxTravel: 0.06

    // ----------------------------------------------------------------- output

    // Offsets in output logical pixels. The foreground and the background move
    // in opposite directions; see the LAYERING note in DepthForeground.qml.
    readonly property real foregroundX: enabled ? _dx : 0
    readonly property real foregroundY: enabled ? _dy : 0
    readonly property real backgroundX: enabled ? -_dx * backgroundRatio : 0
    readonly property real backgroundY: enabled ? -_dy * backgroundRatio : 0

    // How far an offset may drift from the origin, in output pixels. The larger
    // of the two dimensions is used so the limit reads the same in either
    // orientation. Also what the background layer sizes its spare area from.
    readonly property real travelLimit: {
        const screen = _resolveScreen();
        if (!screen)
            return 0;
        return Math.max(screen.width, screen.height) * maxTravel;
    }

    // The largest offset either layer will actually reach, in output pixels.
    // Exposed because the foreground layer has to reserve at least this much
    // spare area, and guessing it in two places is how the two drift apart.
    readonly property real maxOffsetX: Math.max(Math.abs(foregroundX), Math.abs(backgroundX))
    readonly property real maxOffsetY: Math.max(Math.abs(foregroundY), Math.abs(backgroundY))

    // True once the compositor has given us both axes at least once. Until then
    // the offsets are held at zero, so a slow first frame cannot make the scene
    // twitch.
    readonly property bool ready: _sawWorkspace && _sawColumn

    // The output this tracker is following, or null until a workspace has told
    // us which one that is. Deliberately not defaulting to `screens[0]`: on a
    // multi-output desktop that would pick a screen the user is not navigating,
    // and the scene would move on the wrong monitor.
    readonly property var trackedScreen: _resolveScreen()

    readonly property string outputName: _outputName

    // ---------------------------------------------------------------- internal

    // The offset is accumulated from *deltas* rather than computed from an
    // absolute index. An absolute mapping would need a reference origin, and
    // any choice of origin is wrong for someone whose desktop does not start at
    // workspace 1 column 1 -- it would yank the wallpaper sideways on the first
    // navigation. Integrating deltas instead makes the current position the
    // implicit origin, so the scene sits still until the user actually moves.
    property real _dx: 0
    property real _dy: 0

    property bool _sawWorkspace: false
    property bool _sawColumn: false

    property int _lastWorkspaceIndex: -1
    property int _lastColumn: -1

    // Which workspace the last observed column belonged to. Used to tell a real
    // column navigation apart from the focus change a workspace switch causes.
    property string _lastColumnWorkspace: ""

    // The output being tracked. Workspaces belong to an output, so the vertical
    // position is per-output by construction. The column index is not -- niri
    // has one focus -- so the horizontal offset is shared, which matches how the
    // user experiences it: one navigation action, one screen, one movement.
    property string _outputName: ""

    readonly property bool _isNiri: CompositorService.isNiri

    // A single workspace step measured in output pixels. Derived from the
    // tracked output's height so the same setting reads identically on a 1440p
    // and a 4K display.
    readonly property real _stepY: {
        const screen = _resolveScreen();
        return screen ? screen.height * verticalStep : 0;
    }

    readonly property real _stepX: {
        const screen = _resolveScreen();
        return screen ? screen.width * horizontalStep : 0;
    }

    function _resolveScreen() {
        if (_outputName === "")
            return null;
        const screens = Quickshell.screens;
        if (!screens || screens.length === 0)
            return null;
        for (let index = 0; index < screens.length; index++) {
            if (screens[index].name === _outputName)
                return screens[index];
        }
        return null;
    }

    function reset() {
        _dx = 0;
        _dy = 0;
        _sawWorkspace = false;
        _sawColumn = false;
        _lastColumn = -1;
        _lastColumnWorkspace = "";
    }

    // Forces an offset without any navigation behind it.
    //
    // Exists so the rendering can be measured on its own: driving a screenshot
    // test through real `focus-workspace` actions changes the windows on screen
    // at the same time, and the two effects cannot be told apart afterwards.
    // This lets a test move the layers and compare pixels while everything else
    // holds still, then return to zero.
    function debugSetOffset(x, y) {
        _dx = x;
        _dy = y;
    }

    // Applies a delta and holds the result inside the travel budget. Clamping
    // the accumulated value rather than the delta is deliberate: it means the
    // scene pins at the limit and then peels off again as soon as the user
    // navigates back, which is what a real scroll boundary does. Clamping each
    // delta would instead let the position silently disagree with the
    // navigation, so returning to a workspace would not return the wallpaper.
    function _accumulate(dx, dy) {
        if (dx !== 0) {
            const limitX = travelLimit;
            _dx = limitX > 0 ? Math.max(-limitX, Math.min(limitX, _dx + dx)) : _dx + dx;
        }
        if (dy !== 0) {
            const limitY = travelLimit;
            _dy = limitY > 0 ? Math.max(-limitY, Math.min(limitY, _dy + dy)) : _dy + dy;
        }
    }

    // ------------------------------------------------------------- vertical

    function _syncWorkspace() {
        if (!_isNiri) {
            _sawWorkspace = false;
            return;
        }

        const focused = NiriService.focusedWorkspaceId;
        if (focused === "" || focused === undefined || focused === null)
            return;

        // Loose comparison on purpose. `focusedWorkspaceId` is declared as a
        // string on NiriService while each workspace's `id` arrives from
        // `niri msg --json` as a number, so a strict `===` never matches and
        // the vertical axis silently stays dead. Normalising both to strings
        // keeps the intent obvious.
        const wanted = String(focused);

        let focusedWorkspace = null;
        const all = NiriService.allWorkspaces;
        for (let index = 0; index < all.length; index++) {
            if (all[index] && all[index].id !== undefined && String(all[index].id) === wanted) {
                focusedWorkspace = all[index];
                break;
            }
        }
        if (focusedWorkspace === null)
            return;

        // `allWorkspaces` spans every output, so a raw index into it is not a
        // position: moving focus from DP-1 to DP-3 jumps the index by an
        // arbitrary amount that has nothing to do with the user navigating.
        // Only workspaces belonging to the tracked output form a sequence that
        // "up" and "down" mean anything about, so the list is narrowed to those
        // before the position is taken.
        const output = focusedWorkspace.output || "";
        const vertical = [];
        for (let index = 0; index < all.length; index++) {
            const workspace = all[index];
            if (workspace && (workspace.output || "") === output && workspace.idx !== undefined)
                vertical.push(workspace);
        }
        if (vertical.length === 0)
            return;

        vertical.sort((left, right) => left.idx - right.idx);

        let position = -1;
        for (let index = 0; index < vertical.length; index++) {
            if (String(vertical[index].id) === wanted) {
                position = index;
                break;
            }
        }
        if (position < 0)
            return;

        // Switching outputs is not navigation; it is a redefinition of what the
        // tracked sequence even is. Re-seed instead of integrating a delta
        // between two unrelated lists, and drop the column reference for the
        // same reason -- the focused window belongs to the old output.
        if (output !== _outputName) {
            _outputName = output;
            _lastWorkspaceIndex = position;
            _sawWorkspace = true;
            _lastColumn = -1;
            _lastColumnWorkspace = "";
            return;
        }

        if (!_sawWorkspace) {
            // First reading establishes the origin; it must not move anything.
            _lastWorkspaceIndex = position;
            _sawWorkspace = true;
            return;
        }
        if (position === _lastWorkspaceIndex)
            return;

        // Reversed: navigating *down* the workspace list should move the scene
        // *up*, the way scenery slides past a window as you travel forward.
        _accumulate(0, -(position - _lastWorkspaceIndex) * _stepY);
        _lastWorkspaceIndex = position;
    }

    // ----------------------------------------------------------- horizontal

    function _syncColumn() {
        if (!_isNiri) {
            _sawColumn = false;
            return;
        }

        // niri reports no event for "the focused column changed" -- only for
        // "the focused window changed". The column number therefore has to be
        // read back from the newly focused window's layout. That is why this
        // runs on every `windows` change rather than on a dedicated signal.
        const windows = NiriService.windows;
        let focused = null;
        for (let index = 0; index < windows.length; index++) {
            if (windows[index] && windows[index].is_focused === true) {
                focused = windows[index];
                break;
            }
        }
        if (!focused)
            return;

        // Changing workspace changes the focused window as a side effect, and
        // the new workspace's window sits at whatever column it sat at before.
        // Integrating that as horizontal travel would mean a `focus-workspace`
        // keypress also slides the scene sideways, which reads as a bug rather
        // than as parallax -- the two axes are supposed to answer to two
        // different keys. So a column observed in a different workspace only
        // re-seeds the reference; it never accumulates.
        const workspaceId = focused.workspace_id;
        if (workspaceId !== undefined && workspaceId !== null) {
            const workspaceKey = String(workspaceId);
            const workspaceChanged = _lastColumnWorkspace !== "" && _lastColumnWorkspace !== workspaceKey;
            if (_lastColumnWorkspace !== workspaceKey)
                _lastColumnWorkspace = workspaceKey;
            if (workspaceChanged && _sawColumn) {
                _lastColumn = -1;
                return;
            }
        }

        const layout = focused.layout;
        const position = layout ? layout.pos_in_scrolling_layout : null;
        if (!position || position.length < 1)
            return;

        const column = position[0];
        if (typeof column !== "number" || isNaN(column))
            return;

        if (!_sawColumn || _lastColumn < 0) {
            _lastColumn = column;
            _sawColumn = true;
            return;
        }
        if (column === _lastColumn)
            return;

        // Reversed for the same reason as the vertical axis: navigating right
        // moves the scene left.
        _accumulate(-(column - _lastColumn) * _stepX, 0);
        _lastColumn = column;
    }

    Connections {
        target: NiriService

        function onAllWorkspacesChanged() {
            root._syncWorkspace();
        }

        function onFocusedWorkspaceIdChanged() {
            root._syncWorkspace();
        }

        function onWindowsChanged() {
            root._syncColumn();
        }
    }

    // The per-step size depends on the output's dimensions, which are not known
    // until the screen list is populated. Re-seed on change so the first real
    // navigation after a reconfiguration uses the right scale.
    Connections {
        target: Quickshell

        function onScreensChanged() {
            root.reset();
            root._syncWorkspace();
            root._syncColumn();
        }
    }

    Component.onCompleted: {
        // The first reading establishes the origin and the tracked output, so
        // it has to happen as soon as the service has anything to report. If
        // the service is still empty the change signals will land later and
        // seed it then.
        _syncWorkspace();
        _syncColumn();
    }
}
