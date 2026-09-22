// Motion curve shared by the parallax tracker and its regression tests.
//
// Ported from the wallpaper-parallax reference implementation, which had it
// backed by 27 pure-function tests and per-pixel alignment measurements. Two of
// its conclusions correct earlier choices made here and are load-bearing:
//
//   * The offset is DECELERATING, not linear. Every step closes the same
//     fraction of the distance still left to the limit, so running out of
//     travel reads as the scenery slowing down rather than as the canvas
//     hitting a wall. A linear ramp with a hard clamp stops dead, and the stop
//     is the most visible part of the motion.
//
//   * The step COUNT is never clamped; the clamp lives on the offset the curve
//     produces. Clamping the accumulator throws away everything past the limit
//     and strands the scene off-centre with no way back, because the curve is
//     only invertible while the step count is intact.
function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
}

// ---------------------------------------------------------------- vertical
// Driven by the workspaces stack: focus-workspace-up / -down.
//
// `steps` accumulates workspace-index *deltas* rather than being an index. An
// absolute mapping would need a reference origin, and any choice of origin is
// wrong for a desktop that does not start at workspace 1 -- it would yank the
// wallpaper sideways on the first navigation. Integrating deltas makes the
// current position the implicit origin.
function update(previous, workspaces, output) {
    const list = workspaces.filter(w => w.output === output);
    const active = list.find(w => w.is_active);
    if (!active)
        return previous;
    const id = String(active.id);
    const index = Number(active.idx);
    if (!previous)
        return { id: id, index: index, steps: 0 };
    // Renumbering an unchanged workspace is not navigation.
    if (previous.id === id)
        return { id: id, index: index, steps: previous.steps };
    const old = list.find(w => String(w.id) === previous.id);
    const from = old ? Number(old.idx) : previous.index;
    return { id: id, index: index, steps: previous.steps + index - from };
}

// -------------------------------------------------------------- horizontal
// Driven by the column focus: focus-column-left / -right.
//
// niri emits no "focused column changed" event, only "focused window changed",
// so the column number is read back from the focused window's scroll-layout
// position. That also means an empty workspace yields no column at all, which
// is why `null` is a valid result meaning "hold the last position".
function activeColumn(windows, outputWorkspaceIds) {
    if (!windows)
        return null;
    for (const window of windows) {
        if (!window || window.is_focused !== true)
            continue;
        const workspaceId = String(window.workspace_id);
        // The focused window may belong to another output entirely.
        if (outputWorkspaceIds.indexOf(workspaceId) < 0)
            return null;
        const layout = window.layout;
        const position = layout ? layout.pos_in_scrolling_layout : null;
        if (!position || position.length < 1)
            return null;
        const column = Number(position[0]);
        return isFinite(column) ? { column: column, workspaceId: workspaceId } : null;
    }
    return null;
}

function updateColumn(previous, current) {
    // No column to read (empty workspace, or focus is elsewhere): hold.
    if (!current)
        return previous;
    // Changing workspace moves focus to a window in a different column as a
    // side effect. Accumulating that would make a vertical keypress also slide
    // sideways, which reads as a bug. Re-seed instead.
    if (!previous || previous.workspaceId !== current.workspaceId)
        return {
            column: current.column,
            workspaceId: current.workspaceId,
            steps: previous ? previous.steps : 0
        };
    if (previous.column === current.column)
        return previous;
    return {
        column: current.column,
        workspaceId: current.workspaceId,
        steps: previous.steps + current.column - previous.column
    };
}

// ------------------------------------------------------------------ shared

// Negative on purpose: moving right through the columns slides the scene left,
// the way scenery moves against the direction you are travelling.
//
//     offset(n) = -reserve * (1 - (1 - f)^|n|) * sign(n),  f = step*size/reserve
//
// `f` is the fraction of the remaining distance one step consumes. The first
// step therefore moves exactly the configured distance and every later step
// moves that same fraction of what is still left, so the offset eases towards
// the limit and never quite arrives.
//
// The inverse of this is what keeps the return path exact: the offset is
// strictly monotonic in the step count, so navigating back returns the scene to
// exactly where it started.
function offset(steps, size, step, reserve, inverted) {
    if (!(reserve > 0) || !steps)
        return 0;
    // Capped below 1 so the curve keeps a direction even when the configured
    // step is larger than the whole travel budget.
    const fraction = Math.min(Math.max(step * size / reserve, 0), 0.999);
    const remaining = Math.pow(1 - fraction, Math.abs(steps));
    const sign = steps < 0 ? -1 : 1;
    return clamp(-reserve * (1 - remaining) * sign * (inverted ? -1 : 1),
                 -reserve, reserve);
}

// Slack for the oversized canvas, as a fraction of the axis -- NOT a fixed
// number of pixels.
//
// Both axes have to grow by the identical factor or PreserveAspectCrop silently
// reframes the image: adding a constant to both would tilt the canvas away from
// the source aspect ratio and the crop would stop being nil. Expressed
// proportionally, the crop stays exactly nil.
//
// The 0.001 is so the canvas edge never quite reaches the viewport edge at full
// deflection.
//
// Deliberately depends on nothing but the axis size and the travel budget, never
// on the offset: a margin that moved with the offset would be recomputed on
// every frame of the animation for a value that cannot change.
function margin(size, maxTravel) {
    const pad = 0.001;
    return Math.max(0, size) * (Math.max(0, maxTravel) + pad);
}

// --------------------------------------------------------- overview fading
// Overview is where the parallax story has to stop being told.
//
// Normal navigation moves a camera across a plane, and the wallpaper is the far
// part of that same plane, so a slow drift reads as depth. Overview breaks the
// premise: the cards scale backwards out of the plane, and blurring the
// wallpaper says outright that it is no longer scenery but a backdrop -- one
// that happens to still be sliding.
//
// Fading is the only option that removes the contradiction instead of
// negotiating with it. Freezing leaves a compensation jump for whenever the
// offset moved while the overview was open, and re-centring invents motion at
// the exact moment the blur starts. Opacity has neither failure mode: the scene
// simply stops taking part, which is what the blurred backdrop already says.
//
// The resting opacity is deliberately not zero -- see DepthDaemon for the value
// measured on this arrangement.
function overviewOpacity(active, resting) {
    const floor = clamp(resting, 0, 1);
    return active ? floor : 1;
}

// Fade-out is quicker than fade-in: entering the overview is a decisive,
// near-instant act, while coming back should feel like the scenery resolving
// rather than a light being switched on.
function overviewFadeDuration(active, base) {
    const duration = Math.max(0, base);
    return active ? duration : Math.round(duration * 4 / 3);
}

// ------------------------------------------------------------------ easing

// The offset the curve produces is a function of the STEP COUNT, and the step
// count is an integer that jumps. Driving the surfaces straight from it makes
// each navigation a hard cut: the scene is here, then it is 86 px away, in one
// frame. Everything below exists to put a real curve between those two.
//
// An exponential approach rather than a fixed-duration tween, and the
// difference matters:
//
//   * It is TIME-BASED but not TIME-BOUNDED. A tween that finishes in 350 ms
//     restarts from wherever it is on every new step, so holding down the
//     navigation key produces a stutter -- each press cancels the one before and
//     the scene crawls. An exponential approach simply retargets: the distance
//     still to cover shrinks smoothly across however many steps arrive, so a
//     burst of four steps reads as one gesture that has further to go.
//
//   * It never quite arrives, which is what lets the exact-return property
//     survive. The step count is what carries position, and it is untouched
//     here; this only decides how the scene gets *rendered* on its way there.
//     Once the residual is under half a pixel it is snapped, so the scene does
//     settle and does not render forever.
//
// `dt` in milliseconds, `tau` the time constant. The frame-rate independence is
// the point of the exponent: at 144 Hz and at 60 Hz the scene follows the same
// path, where a per-frame lerp factor would make one machine visibly slower.
function approach(current, target, dt, tau) {
    const constant = Math.max(tau, 1);
    if (!(dt > 0))
        return current;
    const alpha = 1 - Math.exp(-dt / constant);
    const next = current + (target - current) * alpha;
    // Snap once the remaining distance is below a pixel: an infinite approach
    // would otherwise keep repainting the scene for the rest of the session,
    // and sub-pixel offsets are resampled rather than moved.
    return Math.abs(target - next) < 0.5 ? target : next;
}

// Time constant for the horizontal axis, in milliseconds, derived from the
// configured motion duration.
//
// Not the duration itself. `parallaxMotionDuration` is documented and tuned as
// "how long one step takes to read as a slide", which is a *settled* time -- the
// point where the movement has effectively finished. An exponential approach
// reaches about 95 % of the distance after three time constants, so the constant
// is a third of the duration to make the two agree. Using the duration directly
// makes every switch take three times as long as the setting says, which is
// exactly the "sluggish but still jerky" feel that comes of compounding a slow
// filter with an instant jump.
function motionTau(duration) {
    return Math.max(1, Math.max(0, duration) / 3);
}

// How long the scene takes to walk from wherever it was frozen visibly to
// wherever the offset actually is by the time the overview closes.
//
// The overview stays live: clicking through cards moves focus between
// workspaces and the tracker keeps accumulating. Re-seeding on exit would
// desynchronise the accumulator from what the user saw and make the NEXT
// ordinary switch jump, so the offset is left alone and the scene is given the
// time to catch up while it is still fading in. The movement is swallowed by
// the fade -- nobody tracks coordinates through an opacity ramp.
function overviewSettleDuration(distance, base) {
    const span = Math.max(0, distance);
    const duration = Math.max(0, base);
    if (!(span > 0))
        return duration;
    return Math.min(Math.round(duration * 4), Math.round(duration + span * 1.5));
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        clamp: clamp,
        update: update,
        activeColumn: activeColumn,
        updateColumn: updateColumn,
        offset: offset,
        margin: margin,
        approach: approach,
        motionTau: motionTau,
        overviewOpacity: overviewOpacity,
        overviewFadeDuration: overviewFadeDuration,
        overviewSettleDuration: overviewSettleDuration
    };
}
