// Pure-function tests for the parallax curve.
//
// Run: node test/depthscrollmath.test.js
//
// The numbers in `motion curve` are taken from the reference implementation's
// measurements on a 2560x1440 output, so a failure here means the curve has
// drifted away from behaviour that was verified against real pixels.

const assert = require("assert");
const M = require("../qml/DepthScrollMath.js");

let passed = 0;
function test(name, body) {
    body();
    passed += 1;
    console.log("  ok  " + name);
}

// ------------------------------------------------------------------- clamp
test("clamp bounds both ends", () => {
    assert.strictEqual(M.clamp(5, 0, 10), 5);
    assert.strictEqual(M.clamp(-5, 0, 10), 0);
    assert.strictEqual(M.clamp(15, 0, 10), 10);
});

// --------------------------------------------------- vertical accumulator
const workspaces = (activeIdx) => [
    { id: 3, idx: 1, output: "DP-3", is_active: activeIdx === 1 },
    { id: 9, idx: 2, output: "DP-3", is_active: activeIdx === 2 },
    { id: 11, idx: 3, output: "DP-3", is_active: activeIdx === 3 },
    { id: 20, idx: 1, output: "DP-1", is_active: false }
];

test("first reading seeds without moving", () => {
    const state = M.update(null, workspaces(1), "DP-3");
    assert.strictEqual(state.steps, 0);
    assert.strictEqual(state.id, "3");
});

test("renumbering an unchanged workspace is not navigation", () => {
    let state = M.update(null, workspaces(1), "DP-3");
    state = M.update(state, workspaces(2), "DP-3");
    const before = state.steps;
    // Same id, shifted idx: must hold.
    const renumbered = workspaces(2).map(w => w.id === 9 ? { ...w, idx: 5 } : w);
    state = M.update(state, renumbered, "DP-3");
    assert.strictEqual(state.steps, before);
});

test("one workspace down accumulates +1, back returns exactly", () => {
    let state = M.update(null, workspaces(1), "DP-3");
    state = M.update(state, workspaces(2), "DP-3");
    assert.strictEqual(state.steps, 1);
    state = M.update(state, workspaces(3), "DP-3");
    assert.strictEqual(state.steps, 2);
    state = M.update(state, workspaces(2), "DP-3");
    assert.strictEqual(state.steps, 1);
    state = M.update(state, workspaces(1), "DP-3");
    assert.strictEqual(state.steps, 0);
    // The offset must be back at the origin, not merely close.
    assert.strictEqual(M.offset(0, 1440, 0.075, 216, false), 0);
});

test("workspaces on other outputs are ignored", () => {
    const list = [
        { id: 3, idx: 1, output: "DP-3", is_active: true },
        { id: 20, idx: 1, output: "DP-1", is_active: false },
        { id: 21, idx: 2, output: "DP-1", is_active: true }
    ];
    const state = M.update(null, list, "DP-1");
    assert.strictEqual(state.id, "21");
});

test("an output with no active workspace yields nothing", () => {
    assert.strictEqual(M.update(null, workspaces(1), "DP-9"), null);
});

test("no active workspace holds the previous state", () => {
    const state = M.update(null, workspaces(1), "DP-3");
    const held = M.update(state, workspaces(0), "DP-3");
    assert.strictEqual(held, state);
});

// ------------------------------------------------- horizontal accumulator
const windowAt = (column, workspaceId, focused = true) => ({
    is_focused: focused,
    workspace_id: workspaceId,
    layout: { pos_in_scrolling_layout: [column, 0] }
});

test("column is read back from the focused window", () => {
    const column = M.activeColumn([windowAt(3, 9)], ["9"]);
    assert.strictEqual(column.column, 3);
    assert.strictEqual(column.workspaceId, "9");
});

test("a column on another output's workspace is not ours", () => {
    assert.strictEqual(M.activeColumn([windowAt(3, 99)], ["9"]), null);
});

test("an empty workspace yields no column", () => {
    assert.strictEqual(M.activeColumn([], ["9"]), null);
    assert.strictEqual(M.activeColumn(null, ["9"]), null);
});

test("column steps accumulate and return", () => {
    let state = M.updateColumn(null, M.activeColumn([windowAt(1, 9)], ["9"]));
    assert.strictEqual(state.steps, 0);
    state = M.updateColumn(state, M.activeColumn([windowAt(2, 9)], ["9"]));
    assert.strictEqual(state.steps, 1);
    state = M.updateColumn(state, M.activeColumn([windowAt(3, 9)], ["9"]));
    assert.strictEqual(state.steps, 2);
    state = M.updateColumn(state, M.activeColumn([windowAt(1, 9)], ["9"]));
    assert.strictEqual(state.steps, 0);
});

test("a workspace switch re-seeds the column instead of accumulating", () => {
    let state = M.updateColumn(null, M.activeColumn([windowAt(1, 9)], ["9"]));
    state = M.updateColumn(state, M.activeColumn([windowAt(4, 9)], ["9"]));
    assert.strictEqual(state.steps, 3);
    // Focus lands in a different workspace whose window sits at column 7. That
    // is a side effect of the vertical keypress, not a horizontal navigation.
    state = M.updateColumn(state, M.activeColumn([windowAt(7, 11)], ["9", "11"]));
    assert.strictEqual(state.steps, 3);
    assert.strictEqual(state.column, 7);
    // And the next real column move is measured from the new reference.
    state = M.updateColumn(state, M.activeColumn([windowAt(8, 11)], ["9", "11"]));
    assert.strictEqual(state.steps, 4);
});

// ------------------------------------------------------------- motion curve
// The reference measured these on a 2560x1440 output with its defaults:
// reserve 12% of the axis on both, first step 6% of height vertically and 8% of
// width horizontally. So f is 0.5 vertically and 0.667 horizontally, which is
// exactly the asymmetry its README reports.
test("motion curve reproduces the measured vertical numbers", () => {
    const size = 1440;
    const reserve = size * 0.12;          // 172.8
    const step = 0.06;                    // fraction of the axis
    const first = M.offset(1, size, step, reserve, false);
    const second = M.offset(2, size, step, reserve, false);
    // Reference: vertical moves 86.4 then 129.6 (increments 86.4 then 43.2).
    assert.ok(Math.abs(Math.abs(first) - 86.4) < 0.05, "first was " + first);
    assert.ok(Math.abs(Math.abs(second) - 129.6) < 0.05, "second was " + second);
    assert.ok(Math.abs(Math.abs(second - first) - 43.2) < 0.05);
});

test("motion curve reproduces the measured horizontal numbers", () => {
    const size = 2560;
    const reserve = size * 0.12;          // 307.2
    const step = 0.08;                    // fraction of the axis
    const first = M.offset(1, size, step, reserve, false);
    const second = M.offset(2, size, step, reserve, false);
    // Reference: horizontal moves 204.8 then 273.1 (increments 204.8 then 68.3).
    assert.ok(Math.abs(Math.abs(first) - 204.8) < 0.05, "first was " + first);
    assert.ok(Math.abs(Math.abs(second) - 273.1) < 0.05, "second was " + second);
    assert.ok(Math.abs(Math.abs(second - first) - 68.3) < 0.05);
});

test("every step is strictly smaller than the one before it", () => {
    const size = 1440;
    const reserve = size * 0.12;
    const step = 0.06;
    let previous = 0;
    let previousDelta = Infinity;
    for (let n = 1; n <= 12; n++) {
        const value = Math.abs(M.offset(n, size, step, reserve, false));
        const delta = value - previous;
        assert.ok(delta < previousDelta, "step " + n + " did not decelerate");
        assert.ok(delta > 0, "step " + n + " did not advance");
        previousDelta = delta;
        previous = value;
    }
});

test("the offset asymptotes to the reserve and never exceeds it", () => {
    const size = 1440;
    const reserve = size * 0.12;
    const step = 0.06;
    for (const n of [1, 5, 50, 500, 100000]) {
        const value = Math.abs(M.offset(n, size, step, reserve, false));
        assert.ok(value <= reserve + 1e-9, "n=" + n + " exceeded the reserve");
    }
    assert.ok(Math.abs(M.offset(100000, size, step, reserve, false)) > reserve - 0.01);
});

test("the curve is monotonic, so the return path is exact", () => {
    const size = 1440;
    const reserve = size * 0.12;
    const step = 0.06;
    // Strictly increasing in |steps|. Checked to 20 rather than 40 because at
    // f = 0.5 the remaining distance is 2^-n: by n = 28 it is 3.7e-9, below the
    // precision the comparison would need. Nothing navigates 28 workspaces.
    let previous = 0;
    for (let n = 1; n <= 20; n++) {
        const value = Math.abs(M.offset(n, size, step, reserve, false));
        assert.ok(value > previous, "not monotonic at n=" + n);
        previous = value;
    }
});

test("navigating back returns the offset to exactly zero", () => {
    const size = 1440;
    const reserve = size * 0.12;
    const step = 0.06;
    const out = M.offset(7, size, step, reserve, false);
    const back = M.offset(0, size, step, reserve, false);
    assert.ok(out !== 0);
    assert.strictEqual(back, 0);
});

test("a step larger than the reserve still keeps a direction", () => {
    // f would be >= 1 without the internal cap, which would make the curve
    // divide by zero and lose its sign.
    const value = M.offset(1, 1000, 5, 100, false);
    assert.ok(isFinite(value));
    assert.ok(value < 0);
});

test("inverted flips the direction", () => {
    const size = 1440;
    const reserve = size * 0.12;
    const step = 0.06;
    const normal = M.offset(3, size, step, reserve, false);
    const flipped = M.offset(3, size, step, reserve, true);
    assert.ok(Math.abs(normal + flipped) < 1e-9);
});

// ------------------------------------------------------------------ margin
test("margin scales both axes by the identical factor", () => {
    const width = 2560, height = 1440, travel = 0.12;
    const mx = M.margin(width, travel);
    const my = M.margin(height, travel);
    // The canvas aspect ratio must equal the viewport's, or PreserveAspectCrop
    // crops and reframes.
    const canvasAspect = (width + 2 * mx) / (height + 2 * my);
    assert.ok(Math.abs(canvasAspect - width / height) < 1e-9);
});

test("margin grows past the travel budget", () => {
    assert.ok(M.margin(1000, 0.1) > 100);
});

test("no travel means no margin", () => {
    assert.strictEqual(M.margin(1000, 0), 1);
});

// --------------------------------------------------------- overview fading
test("overview resting opacity is not treated as fully transparent", () => {
    assert.strictEqual(M.overviewOpacity(true, 0.12), 0.12);
    assert.strictEqual(M.overviewOpacity(false, 0.12), 1);
});

test("overview opacity is clamped to a sane range", () => {
    assert.strictEqual(M.overviewOpacity(true, -1), 0);
    assert.strictEqual(M.overviewOpacity(true, 5), 1);
});

test("fade-out is slower than fade-in", () => {
    const inDuration = M.overviewFadeDuration(true, 240);
    const outDuration = M.overviewFadeDuration(false, 240);
    assert.strictEqual(inDuration, 240);
    assert.strictEqual(outDuration, 320);
});

test("settle duration stretches with distance but stays bounded", () => {
    const base = 350;
    assert.strictEqual(M.overviewSettleDuration(0, base), base);
    const small = M.overviewSettleDuration(20, base);
    const large = M.overviewSettleDuration(500, base);
    assert.ok(small > base);
    assert.ok(large > small);
    assert.ok(large <= base * 4 + 1);
});

// ------------------------------------------------------------------ easing
test("motionTau derives time constant from motion duration", () => {
    assert.strictEqual(M.motionTau(300), 100);
    assert.strictEqual(M.motionTau(0), 1);
    assert.strictEqual(M.motionTau(-50), 1);
});

test("approach smoothly advances towards target", () => {
    const start = 0;
    const target = 100;
    const dt = 16;
    const tau = 100;
    const next = M.approach(start, target, dt, tau);
    assert.ok(next > start);
    assert.ok(next < target);
    // Zero dt does not advance
    assert.strictEqual(M.approach(start, target, 0, tau), start);
    // Negative dt does not advance
    assert.strictEqual(M.approach(start, target, -5, tau), start);
});

test("approach snaps to target when within half pixel", () => {
    const target = 100;
    const near = 99.7;
    const snapped = M.approach(near, target, 16, 100);
    assert.strictEqual(snapped, target);

    const nearBelow = 100.3;
    const snappedBelow = M.approach(nearBelow, target, 16, 100);
    assert.strictEqual(snappedBelow, target);
});

console.log("\n" + passed + " / " + passed + " passed");

