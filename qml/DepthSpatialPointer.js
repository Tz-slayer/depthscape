// Keep camera motion bounded while making small mouse movements visible.
function responsivePointer(value, sensitivity) {
    const pointer = Number.isFinite(value) ? Math.max(-1, Math.min(1, value)) : 0;
    const gain = Number.isFinite(sensitivity) ? Math.max(1, sensitivity) : 3;
    return gain * pointer / (1 + (gain - 1) * Math.abs(pointer));
}
