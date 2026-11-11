//! Spatial layer generation, ported from the former C++/OpenCV helper.
//!
//! Ported from the C++/OpenCV helper that used to run as a subprocess; the
//! golden replay in `tests::spatial_golden_replay` is what pins the behaviour
//! down. Inputs arrive already decoded, so OpenCV's codec layer is unused.

use anyhow::{Context, Result};
use opencv::{core, imgproc, prelude::*};

fn ocv_err(ctx: &str, e: opencv::Error) -> anyhow::Error {
    anyhow::anyhow!("{ctx}: {e}")
}

/// Ellipse structuring element, matching `cv::getStructuringElement(MORPH_ELLIPSE, {n, n})`.
fn ellipse(n: i32) -> Result<core::Mat> {
    let n = n.max(1) as usize;
    let mut data = vec![0u8; n * n];
    let c = (n - 1) as f64 / 2.0;
    let r = n as f64 / 2.0;
    for y in 0..n {
        for x in 0..n {
            let dx = (x as f64 - c) / r;
            let dy = (y as f64 - c) / r;
            if dx * dx + dy * dy <= 1.0 {
                data[y * n + x] = 255;
            }
        }
    }
    let rows: Vec<&[u8]> = data.chunks_exact(n).collect();
    core::Mat::from_slice_2d(&rows).context("ellipse kernel")
}

/// `labels == value` for a single-channel 32S Mat, yielding 0/255 8UC1.
fn eq_scalar(src: &core::Mat, value: i32) -> Result<core::Mat> {
    let mut dst = core::Mat::default();
    core::compare(
        src,
        &core::Scalar::all(value as f64),
        &mut dst,
        core::CMP_EQ,
    )
    .map_err(|e| ocv_err("compare", e))?;
    Ok(dst)
}

/// Threshold a single-channel Mat against a scalar.
fn cmp_scalar(src: &core::Mat, value: f64, op: i32) -> Result<core::Mat> {
    let mut dst = core::Mat::default();
    core::compare(src, &core::Scalar::all(value), &mut dst, op)
        .map_err(|e| ocv_err("compare", e))?;
    Ok(dst)
}

/// `cv::Mat::setTo(value, mask)` has no binding. Every call site in the original
/// targets a continuous single-channel 8-bit Mat, so a byte-level masked fill is
/// exact and needs no temporary Mat.
fn set_masked(dst: &mut core::Mat, mask: &core::Mat, value: u8) -> Result<()> {
    anyhow::ensure!(
        dst.is_continuous() && mask.is_continuous(),
        "set_masked: non-continuous Mat"
    );
    anyhow::ensure!(dst.typ() == core::CV_8UC1, "set_masked: dst is not 8UC1");
    let len = dst.total();
    anyhow::ensure!(mask.total() == len, "set_masked: size mismatch");
    let dst_ptr = dst.data_mut();
    let mask_ptr = mask.data();
    if dst_ptr.is_null() || mask_ptr.is_null() {
        anyhow::bail!("set_masked: Mat has no buffer");
    }
    let out = unsafe { std::slice::from_raw_parts_mut(dst_ptr, len) };
    let m = unsafe { std::slice::from_raw_parts(mask_ptr, len) };
    for (o, &mv) in out.iter_mut().zip(m.iter()) {
        if mv != 0 {
            *o = value;
        }
    }
    Ok(())
}

/// Zero a half-open row range, matching `mat.rowRange(a, b).setTo(0)`.
fn zero_rows(m: &mut core::Mat, from: i32, to: i32) -> Result<()> {
    if m.empty() || to <= from {
        return Ok(());
    }
    anyhow::ensure!(m.is_continuous(), "zero_rows: non-continuous Mat");
    let cols = m.cols() as usize;
    let len = m.total();
    let ptr = m.data_mut();
    if ptr.is_null() {
        anyhow::bail!("zero_rows: Mat has no buffer");
    }
    let bytes = unsafe { std::slice::from_raw_parts_mut(ptr, len) };
    let start = (from as usize).min(m.rows() as usize) * cols;
    let end = (to as usize).min(m.rows() as usize) * cols;
    bytes[start..end].fill(0);
    Ok(())
}

/// Zero a half-open column range, matching `mat.colRange(a, b).setTo(0)`.
fn zero_cols(m: &mut core::Mat, from: i32, to: i32) -> Result<()> {
    if m.empty() || to <= from {
        return Ok(());
    }
    anyhow::ensure!(m.is_continuous(), "zero_cols: non-continuous Mat");
    let cols = m.cols() as usize;
    let len = m.total();
    let ptr = m.data_mut();
    if ptr.is_null() {
        anyhow::bail!("zero_cols: Mat has no buffer");
    }
    let bytes = unsafe { std::slice::from_raw_parts_mut(ptr, len) };
    let from = (from as usize).min(cols);
    let to = (to as usize).min(cols);
    for row in bytes.chunks_exact_mut(cols) {
        row[from..to].fill(0);
    }
    Ok(())
}

fn count_non_zero(m: &core::Mat) -> Result<i32> {
    core::count_non_zero(m).map_err(|e| ocv_err("countNonZero", e))
}

fn stats_at(stats: &core::Mat, row: i32, col: i32) -> Result<i32> {
    stats
        .at_2d::<i32>(row, col)
        .map_err(|e| ocv_err("stats access", e))
        .copied()
}

/// Select a compact connected region, rejecting candidates cropped by the top or
/// sides. A subject may legitimately extend past the bottom edge.
pub fn component(
    input: &core::Mat,
    min_area: f64,
    max_area: f64,
    bottom_allowed: bool,
    edge_allowed: bool,
) -> Result<core::Mat> {
    let mut labels = core::Mat::default();
    let mut stats = core::Mat::default();
    let mut centroids = core::Mat::default();
    let count = imgproc::connected_components_with_stats(
        input,
        &mut labels,
        &mut stats,
        &mut centroids,
        8,
        core::CV_32SC1,
    )
    .map_err(|e| ocv_err("connectedComponentsWithStats", e))?;

    let total = input.total() as f64;
    let mut best = 0i32;
    let mut best_area = 0i32;
    for i in 1..count {
        let area = stats_at(&stats, i, imgproc::CC_STAT_AREA)?;
        let x = stats_at(&stats, i, imgproc::CC_STAT_LEFT)?;
        let y = stats_at(&stats, i, imgproc::CC_STAT_TOP)?;
        let w = stats_at(&stats, i, imgproc::CC_STAT_WIDTH)?;
        let h = stats_at(&stats, i, imgproc::CC_STAT_HEIGHT)?;
        let right = x + w;
        let bottom = y + h;
        if (area as f64) < total * min_area || (area as f64) > total * max_area {
            continue;
        }
        if !edge_allowed && (x < 2 || y < 2 || right > input.cols() - 2) {
            continue;
        }
        if !bottom_allowed && bottom > input.rows() - 2 {
            continue;
        }
        if best == 0 || area > best_area {
            best = i;
            best_area = area;
        }
    }

    if best == 0 {
        return Ok(core::Mat::default());
    }
    eq_scalar(&labels, best)
}

/// Close small holes in `mask`, keeping only those whose surrounding ring sits at
/// a depth no farther than the ring itself.
pub fn restore_holes(mask: &mut core::Mat, depth: &core::Mat) -> Result<()> {
    if mask.empty() {
        return Ok(());
    }
    let span = mask.cols().min(mask.rows()) as f64;
    let diameter = ((span * 0.025).round() as i32).clamp(9, 41) | 1;

    let kernel = ellipse(diameter)?;
    let mut closed = core::Mat::default();
    imgproc::morphology_ex(
        mask,
        &mut closed,
        imgproc::MORPH_CLOSE,
        &kernel,
        core::Point::new(-1, -1),
        1,
        core::BORDER_CONSTANT,
        core::Scalar::all(0.),
    )
    .map_err(|e| ocv_err("morphologyEx", e))?;

    let mut flooded = closed.clone();
    let mut rect = core::Rect::new(0, 0, 0, 0);
    imgproc::flood_fill(
        &mut flooded,
        core::Point::new(0, 0),
        core::Scalar::all(255.),
        Some(&mut rect),
        core::Scalar::all(0.),
        core::Scalar::all(0.),
        4 | (255 << 8),
    )
    .map_err(|e| ocv_err("floodFill", e))?;

    let mut holes = core::Mat::default();
    core::bitwise_not(&flooded, &mut holes, &core::Mat::default())
        .map_err(|e| ocv_err("bitwise_not", e))?;

    // Include holes that the closing itself repaired: looking only at residual
    // holes would drop exactly the pixels morphology already fixed.
    let mut original_outside = core::Mat::default();
    core::bitwise_not(mask, &mut original_outside, &core::Mat::default())
        .map_err(|e| ocv_err("bitwise_not mask", e))?;
    let mut newly_closed = core::Mat::default();
    core::bitwise_and(
        &closed,
        &original_outside,
        &mut newly_closed,
        &core::Mat::default(),
    )
    .map_err(|e| ocv_err("bitwise_and", e))?;
    let mut holes_merged = core::Mat::default();
    core::bitwise_or(
        &holes,
        &newly_closed,
        &mut holes_merged,
        &core::Mat::default(),
    )
    .map_err(|e| ocv_err("bitwise_or", e))?;
    holes = holes_merged;

    let mut labels = core::Mat::default();
    let mut stats = core::Mat::default();
    let mut centroids = core::Mat::default();
    let count = imgproc::connected_components_with_stats(
        &holes,
        &mut labels,
        &mut stats,
        &mut centroids,
        8,
        core::CV_32SC1,
    )
    .map_err(|e| ocv_err("cc stats holes", e))?;

    let total = mask.total() as f64;
    let ring_kernel = ellipse(7)?;
    for i in 1..count {
        let area = stats_at(&stats, i, imgproc::CC_STAT_AREA)?;
        if (area as f64) > total * 0.025 {
            continue;
        }
        let hole = eq_scalar(&labels, i)?;
        let mut ring = core::Mat::default();
        imgproc::dilate(
            &hole,
            &mut ring,
            &ring_kernel,
            core::Point::new(-1, -1),
            1,
            core::BORDER_CONSTANT,
            core::Scalar::all(0.),
        )
        .map_err(|e| ocv_err("dilate ring", e))?;
        let mut ring_supported = core::Mat::default();
        core::bitwise_and(&ring, mask, &mut ring_supported, &core::Mat::default())
            .map_err(|e| ocv_err("and ring", e))?;
        ring = ring_supported;
        if count_non_zero(&ring)? == 0 {
            continue;
        }
        let mean = core::mean(depth, &ring).map_err(|e| ocv_err("mean", e))?;
        let supported = cmp_scalar(depth, (mean[0] - 6553.5).max(0.), core::CMP_GE)?;
        let mut supported_hole = core::Mat::default();
        core::bitwise_and(
            &supported,
            &hole,
            &mut supported_hole,
            &core::Mat::default(),
        )
        .map_err(|e| ocv_err("and hole", e))?;
        if count_non_zero(&supported_hole)? >= (area as f64 * 0.8) as i32 {
            set_masked(mask, &hole, 255)?;
        }
    }
    Ok(())
}

/// `src.copyTo(dst, mask)` for continuous single-channel 8-bit Mats.
fn copy_masked(dst: &mut core::Mat, src: &core::Mat, mask: &core::Mat) -> Result<()> {
    anyhow::ensure!(
        dst.is_continuous() && src.is_continuous() && mask.is_continuous(),
        "copy_masked: non-continuous Mat"
    );
    anyhow::ensure!(
        dst.typ() == core::CV_8UC1 && src.typ() == core::CV_8UC1 && mask.typ() == core::CV_8UC1,
        "copy_masked: expected 8UC1"
    );
    let len = dst.total();
    anyhow::ensure!(
        src.total() == len && mask.total() == len,
        "copy_masked: size mismatch"
    );
    let (sp, mp) = (src.data(), mask.data());
    if sp.is_null() || mp.is_null() {
        anyhow::bail!("copy_masked: Mat has no buffer");
    }
    let s = unsafe { std::slice::from_raw_parts(sp, len) };
    let m = unsafe { std::slice::from_raw_parts(mp, len) };
    let d = unsafe { std::slice::from_raw_parts_mut(dst.data_mut(), len) };
    for i in 0..len {
        if m[i] != 0 {
            d[i] = s[i];
        }
    }
    Ok(())
}

/// `mat(rect).setTo(value)` for continuous single-channel 8-bit Mats.
fn fill_rect(m: &mut core::Mat, x: i32, y: i32, w: i32, h: i32, value: u8) -> Result<()> {
    if m.empty() || w <= 0 || h <= 0 {
        return Ok(());
    }
    anyhow::ensure!(m.is_continuous(), "fill_rect: non-continuous Mat");
    let cols = m.cols() as usize;
    let len = m.total();
    let (x, y, rw, rh) = (
        x.max(0) as usize,
        y.max(0) as usize,
        (x.max(0) + w.max(0)) as usize,
        (y.max(0) + h.max(0)) as usize,
    );
    let bytes = unsafe { std::slice::from_raw_parts_mut(m.data_mut(), len) };
    for row in bytes
        .chunks_exact_mut(cols)
        .take(rh.min(m.rows() as usize))
        .skip(y)
    {
        row[x.min(cols)..rw.min(cols)].fill(value);
    }
    Ok(())
}

/// `cv::boundingRect` over a binary raster mask.
fn bounding_rect_of_mask(m: &core::Mat) -> Result<Option<(i32, i32, i32, i32)>> {
    if m.empty() {
        return Ok(None);
    }
    anyhow::ensure!(
        m.is_continuous() && m.typ() == core::CV_8UC1,
        "bounding_rect: expected continuous 8UC1"
    );
    let cols = m.cols() as usize;
    let len = m.total();
    let bytes = unsafe {
        std::slice::from_raw_parts(
            {
                let q = m.data();
                if q.is_null() {
                    anyhow::bail!("bounding_rect: no buffer");
                }
                q
            },
            len,
        )
    };
    let (mut x0, mut y0, mut x1, mut y1) = (i32::MAX, i32::MAX, i32::MIN, i32::MIN);
    for (idx, &v) in bytes.iter().enumerate() {
        if v == 0 {
            continue;
        }
        let y = (idx / cols) as i32;
        let x = (idx % cols) as i32;
        x0 = x0.min(x);
        x1 = x1.max(x);
        y0 = y0.min(y);
        y1 = y1.max(y);
    }
    if x1 < x0 {
        return Ok(None);
    }
    Ok(Some((x0, y0, x1 - x0 + 1, y1 - y0 + 1)))
}

/// OpenCV 5 moved `DistanceTypes` into `opencv2/geometry/2d.hpp` and the binding
/// crate does not emit a `geometry` module, so the constant is not exposed.
/// Value taken from that header: `DIST_L2 = 2`.
const DIST_L2: i32 = 2;

fn zeros_u8(rows: i32, cols: i32) -> Result<core::Mat> {
    core::Mat::zeros(rows, cols, core::CV_8UC1)
        .map_err(|e| ocv_err("zeros", e))?
        .to_mat()
        .map_err(|e| ocv_err("zeros to_mat", e))
}

/// Borrow a continuous 8-bit Mat's pixels as a byte slice. Callers must have
/// checked the type; per-pixel `at_2d` in these loops is several times slower
/// than OpenCV, so the hot paths iterate slices instead.
fn bytes_of(m: &core::Mat) -> Result<&[u8]> {
    anyhow::ensure!(m.is_continuous(), "bytes_of: non-continuous Mat");
    anyhow::ensure!(m.depth() == core::CV_8U, "bytes_of: expected 8-bit depth");
    let len = m.total() * m.channels() as usize;
    let p = m.data();
    if p.is_null() {
        anyhow::bail!("bytes_of: no buffer");
    }
    Ok(unsafe { std::slice::from_raw_parts(p, len) })
}

fn i32s_of(m: &core::Mat) -> Result<&[i32]> {
    anyhow::ensure!(m.is_continuous(), "i32s_of: non-continuous Mat");
    anyhow::ensure!(m.typ() == core::CV_32SC1, "i32s_of: expected CV_32SC1");
    let len = m.total();
    let p = m.data();
    if p.is_null() {
        anyhow::bail!("i32s_of: no buffer");
    }
    Ok(unsafe { std::slice::from_raw_parts(p as *const i32, len) })
}

fn erode_with(src: &core::Mat, dst: &mut core::Mat, n: i32) -> Result<()> {
    imgproc::erode(
        src,
        dst,
        &ellipse(n)?,
        core::Point::new(-1, -1),
        1,
        core::BORDER_CONSTANT,
        core::Scalar::all(0.),
    )
    .map_err(|e| ocv_err("erode", e))
}

fn dilate_with(src: &core::Mat, dst: &mut core::Mat, n: i32) -> Result<()> {
    imgproc::dilate(
        src,
        dst,
        &ellipse(n)?,
        core::Point::new(-1, -1),
        1,
        core::BORDER_CONSTANT,
        core::Scalar::all(0.),
    )
    .map_err(|e| ocv_err("dilate", e))
}

fn blur(src: &core::Mat, dst: &mut core::Mat, sigma: f64) -> Result<()> {
    imgproc::gaussian_blur(
        src,
        dst,
        core::Size::new(0, 0),
        sigma,
        sigma,
        core::BORDER_DEFAULT,
        core::AlgorithmHint::ALGO_HINT_DEFAULT,
    )
    .map_err(|e| ocv_err("gaussianBlur", e))
}

fn band_and(src1: &core::Mat, src2: &core::Mat) -> Result<core::Mat> {
    let mut dst = core::Mat::default();
    core::bitwise_and(src1, src2, &mut dst, &core::Mat::default())
        .map_err(|e| ocv_err("bitwise_and", e))?;
    Ok(dst)
}

fn band_or(src1: &core::Mat, src2: &core::Mat) -> Result<core::Mat> {
    let mut dst = core::Mat::default();
    core::bitwise_or(src1, src2, &mut dst, &core::Mat::default())
        .map_err(|e| ocv_err("bitwise_or", e))?;
    Ok(dst)
}

/// Depth-only segmentation fallback: seed GrabCut from depth bands and keep the
/// component that actually overlaps the seed.
pub fn segment_depth(
    photo: &core::Mat,
    depth: &core::Mat,
    edge_subject: bool,
) -> Result<core::Mat> {
    let (w, h) = (photo.cols(), photo.rows());
    let mut labels = zeros_u8(h, w)?;
    let seed;

    if !edge_subject {
        let candidate = component(
            &cmp_scalar(depth, 0.30 * 65535.0, core::CMP_GT)?,
            0.015,
            0.55,
            false,
            false,
        )?;
        if candidate.empty() {
            return Ok(core::Mat::default());
        }
        let mut inside = core::Mat::default();
        erode_with(&candidate, &mut inside, 21)?;
        let mut around = core::Mat::default();
        dilate_with(&candidate, &mut around, 21)?;
        set_masked(&mut labels, &around, imgproc::GC_PR_BGD as u8)?;
        set_masked(&mut labels, &candidate, imgproc::GC_PR_FGD as u8)?;
        set_masked(&mut labels, &inside, imgproc::GC_FGD as u8)?;
        seed = candidate;
    } else {
        let mut high = cmp_scalar(depth, 0.58 * 65535.0, core::CMP_GT)?;
        zero_rows(&mut high, (h as f64 * 0.78) as i32, h)?;
        zero_cols(&mut high, 0, (w as f64 * 0.12) as i32)?;
        zero_cols(&mut high, (w as f64 * 0.88) as i32, w)?;
        let seed_m = component(&high, 0.004, 0.22, false, false)?;
        if seed_m.empty() {
            return Ok(core::Mat::default());
        }

        let mut expanded = cmp_scalar(depth, 0.50 * 65535.0, core::CMP_GT)?;
        zero_rows(&mut expanded, (h as f64 * 0.78) as i32, h)?;
        zero_cols(&mut expanded, 0, (w as f64 * 0.12) as i32)?;
        zero_cols(&mut expanded, (w as f64 * 0.88) as i32, w)?;
        expanded = component(&expanded, 0.004, 0.45, true, false)?;

        let mut box_ = bounding_rect_of_mask(&seed_m)?.unwrap_or((0, 0, 0, 0));
        let mut expanded_active = !expanded.empty();
        if expanded_active {
            let overlap = band_and(&expanded, &seed_m)?;
            let candidate_box = bounding_rect_of_mask(&expanded)?;
            let wide_enough =
                count_non_zero(&overlap)? >= (count_non_zero(&seed_m)? as f64 * 0.8) as i32;
            let fits = candidate_box
                .map(|b| (b.2 as f64) < w as f64 * 0.75)
                .unwrap_or(false);
            if wide_enough && fits {
                box_ = candidate_box.unwrap();
            } else {
                expanded_active = false;
            }
        }

        let margin = ((w as f64 * 0.025) as i32).max((box_.2 as f64 * 0.12) as i32);
        let left = 2i32.max(box_.0 - margin);
        let right = (w - 2).min(box_.0 + box_.2 + margin);
        let top = 2i32.max(box_.1 - box_.3 / 6);
        if right - left < (w as f64 * 0.08) as i32 || top > (h as f64 * 0.62) as i32 {
            return Ok(core::Mat::default());
        }
        fill_rect(
            &mut labels,
            left,
            top,
            right - left,
            h - top,
            imgproc::GC_PR_BGD as u8,
        )?;

        let mut likely = cmp_scalar(depth, 0.48 * 65535.0, core::CMP_GT)?;
        if expanded_active {
            likely = band_and(&likely, &expanded)?;
        }
        zero_cols(&mut likely, 0, left)?;
        zero_cols(&mut likely, right, w)?;
        zero_rows(&mut likely, 0, top)?;
        set_masked(&mut labels, &likely, imgproc::GC_PR_FGD as u8)?;
        let mut eroded_seed = core::Mat::default();
        erode_with(&seed_m, &mut eroded_seed, 11)?;
        set_masked(&mut labels, &eroded_seed, imgproc::GC_FGD as u8)?;
        seed = eroded_seed;
    }

    let mut bg_model = core::Mat::default();
    let mut fg_model = core::Mat::default();
    imgproc::grab_cut(
        photo,
        &mut labels,
        core::Rect::new(0, 0, 0, 0),
        &mut bg_model,
        &mut fg_model,
        4,
        imgproc::GC_INIT_WITH_MASK,
    )
    .map_err(|e| ocv_err("grabCut", e))?;

    let mut binary = band_or(
        &eq_scalar(&labels, imgproc::GC_FGD)?,
        &eq_scalar(&labels, imgproc::GC_PR_FGD)?,
    )?;
    if edge_subject {
        binary = band_and(&binary, &cmp_scalar(depth, 0.45 * 65535.0, core::CMP_GT)?)?;
    }
    binary = component(
        &binary,
        0.015,
        if edge_subject { 0.35 } else { 0.55 },
        edge_subject,
        false,
    )?;
    if binary.empty() {
        return Ok(core::Mat::default());
    }
    let overlap = band_and(&binary, &seed)?;
    let ratio = if edge_subject { 0.9 } else { 0.65 };
    if count_non_zero(&overlap)? < (count_non_zero(&seed)? as f64 * ratio) as i32 {
        return Ok(core::Mat::default());
    }
    if edge_subject {
        if let Some(b) = bounding_rect_of_mask(&binary)? {
            if (b.2 as f64) > w as f64 * 0.65 || b.1 > (h as f64 * 0.5) as i32 {
                return Ok(core::Mat::default());
            }
        }
    }
    let mut closed = core::Mat::default();
    imgproc::morphology_ex(
        &binary,
        &mut closed,
        imgproc::MORPH_CLOSE,
        &ellipse(if edge_subject { 11 } else { 3 })?,
        core::Point::new(-1, -1),
        1,
        core::BORDER_CONSTANT,
        core::Scalar::all(0.),
    )
    .map_err(|e| ocv_err("morphologyEx", e))?;
    let mut binary = closed;
    restore_holes(&mut binary, depth)?;
    Ok(binary)
}

/// Build the foreground matte from the matting model's confidence map, using the
/// depth segmentation only to repair edges and interior holes.
pub fn mask_from_model(
    confidence: &core::Mat,
    photo: &core::Mat,
    depth: &core::Mat,
) -> Result<(core::Mat, core::Mat)> {
    let none = (core::Mat::default(), core::Mat::default());
    if confidence.empty() {
        return Ok(none);
    }
    let (w, h) = (photo.cols(), photo.rows());
    let mut proposed = component(
        &cmp_scalar(confidence, 64.0, core::CMP_GT)?,
        0.005,
        0.60,
        true,
        true,
    )?;
    if proposed.empty() {
        return Ok(none);
    }

    let mut strong = cmp_scalar(depth, 0.58 * 65535.0, core::CMP_GT)?;
    zero_rows(&mut strong, (h as f64 * 0.78) as i32, h)?;
    zero_cols(&mut strong, 0, (w as f64 * 0.12) as i32)?;
    zero_cols(&mut strong, (w as f64 * 0.88) as i32, w)?;
    let strong = component(&strong, 0.004, 0.22, false, true)?;
    if strong.empty() {
        return Ok(none);
    }
    if count_non_zero(&band_and(&strong, &proposed)?)?
        < (count_non_zero(&strong)? as f64 * 0.55) as i32
    {
        return Ok(none);
    }

    let mut repair = segment_depth(photo, depth, false)?;
    if repair.empty() {
        repair = segment_depth(photo, depth, true)?;
    }
    let mut support = core::Mat::default();
    if !repair.empty() {
        let mut vicinity = core::Mat::default();
        dilate_with(&proposed, &mut vicinity, 31)?;
        support = band_and(&repair, &vicinity)?;
        proposed = band_or(&proposed, &support)?;
    }

    let before = proposed.clone();
    restore_holes(&mut proposed, depth)?;
    let mut holes = core::Mat::default();
    core::subtract(&proposed, &before, &mut holes, &core::Mat::default(), -1)
        .map_err(|e| ocv_err("subtract", e))?;
    let mut allowed = core::Mat::default();
    dilate_with(&proposed, &mut allowed, 17)?;

    let mut alpha = zeros_u8(h, w)?;
    copy_masked(&mut alpha, confidence, &allowed)?;
    if !support.empty() {
        set_masked(&mut alpha, &support, 255)?;
    }
    set_masked(&mut alpha, &holes, 255)?;
    // IS-Net Anime confidence can stay low across a solid face or clothing even
    // when its subject component is reliable; the interior must be opaque so
    // reconstructed background never shows through the subject.
    let mut interior = core::Mat::default();
    erode_with(&proposed, &mut interior, 11)?;
    set_masked(&mut alpha, &interior, 255)?;
    let mut blurred = core::Mat::default();
    blur(&alpha, &mut blurred, 0.7)?;
    Ok((proposed, blurred))
}

/// Reconstruct the region the foreground will vacate: nearest visible pixel,
/// mirrored where possible, then a blurred blend over the dilated seam.
pub fn background_fill(photo: &core::Mat, mask: &core::Mat) -> Result<core::Mat> {
    let (w, h) = (photo.cols() as usize, photo.rows() as usize);
    anyhow::ensure!(
        photo.typ() == core::CV_8UC3,
        "background_fill: photo must be 8UC3"
    );
    let radius = 12usize.max(((w.min(h) as f64 * 0.012).round() as usize) * 2 + 1);

    let mut hidden = core::Mat::default();
    dilate_with(mask, &mut hidden, radius as i32)?;
    let mut distance = core::Mat::default();
    let mut labels = core::Mat::default();
    imgproc::distance_transform_with_labels(
        &hidden,
        &mut distance,
        &mut labels,
        DIST_L2,
        5,
        imgproc::DIST_LABEL_PIXEL,
    )
    .map_err(|e| ocv_err("distanceTransform", e))?;

    let mut max_label = 0f64;
    core::min_max_loc(
        &labels,
        None,
        Some(&mut max_label),
        None,
        None,
        &core::Mat::default(),
    )
    .map_err(|e| ocv_err("minMaxLoc", e))?;
    let mut nearest: Vec<(i32, i32)> = vec![(-1, -1); max_label as usize + 1];
    let hidden_b = bytes_of(&hidden)?;
    let labels_i = i32s_of(&labels)?;
    for idx in 0..(w * h) {
        if hidden_b[idx] != 0 {
            continue;
        }
        let l = labels_i[idx] as usize;
        if l < nearest.len() {
            nearest[l] = ((idx % w) as i32, (idx / w) as i32);
        }
    }

    let photo_b = bytes_of(photo)?;
    let mut filled = photo_b.to_vec();
    for idx in 0..(w * h) {
        if hidden_b[idx] == 0 {
            continue;
        }
        let l = labels_i[idx] as usize;
        let mut p = *nearest.get(l).unwrap_or(&(-1, -1));
        if p.0 < 0 {
            continue;
        }
        let reflected = (2 * p.0 - idx as i32 % w as i32, 2 * p.1 - (idx / w) as i32);
        if reflected.0 >= 0
            && reflected.1 >= 0
            && (reflected.0 as usize) < w
            && (reflected.1 as usize) < h
            && hidden_b[reflected.1 as usize * w + reflected.0 as usize] == 0
        {
            p = reflected;
        }
        let src = (p.1 as usize * w + p.0 as usize) * 3;
        let dst = idx * 3;
        filled[dst..dst + 3].copy_from_slice(&photo_b[src..src + 3]);
    }

    let filled_mat = mat3_from_bytes(&filled, w, h)?;
    let mut blurred = core::Mat::default();
    blur(&filled_mat, &mut blurred, 2.0)?;
    let mut blend = core::Mat::default();
    blur(&hidden, &mut blend, 1.4)?;

    let blurred_b = bytes_of(&blurred)?;
    let blend_b = bytes_of(&blend)?;
    let mut out = vec![0u8; w * h * 3];
    for (px, &blend) in blend_b.iter().enumerate() {
        let a = blend as f64 / 255.0;
        for c in 0..3 {
            let i = px * 3 + c;
            let v = photo_b[i] as f64 * (1.0 - a) + blurred_b[i] as f64 * a;
            out[i] = v.clamp(0.0, 255.0).round() as u8;
        }
    }
    mat3_from_bytes(&out, w, h)
}

/// Build a continuous CV_8UC3 Mat from packed RGB bytes: row-slice as 8UC1, then
/// fold every three bytes into a channel.
fn mat3_from_bytes(v: &[u8], w: usize, h: usize) -> Result<core::Mat> {
    anyhow::ensure!(v.len() == w * h * 3, "mat3_from_bytes: length mismatch");
    let mut m = unsafe { core::Mat::new_rows_cols(h as i32, w as i32, core::CV_8UC3) }
        .map_err(|e| ocv_err("new_rows_cols", e))?;
    let dst = m.data_mut();
    if dst.is_null() {
        anyhow::bail!("mat3_from_bytes: no buffer");
    }
    unsafe { std::slice::from_raw_parts_mut(dst, v.len()) }.copy_from_slice(v);
    Ok(m)
}

/// Soft influence field around the nearest foreground, driving widget parallax.
pub fn influence_map(depth: &core::Mat, mask: &core::Mat) -> Result<core::Mat> {
    let near = component(
        &band_and(&cmp_scalar(depth, 0.82 * 65535.0, core::CMP_GT)?, mask)?,
        0.001,
        0.30,
        false,
        false,
    )?;
    if near.empty() {
        return zeros_u8(depth.rows(), depth.cols());
    }
    let mut spread = core::Mat::default();
    dilate_with(&near, &mut spread, 101)?;
    let mut soft = core::Mat::default();
    blur(&spread, &mut soft, 25.0)?;
    Ok(soft)
}

/// Result of one spatial asset pass, in `image` buffers so the OpenCV `Mat`
/// layer stays inside this module.
pub struct Outcome {
    pub background: image::RgbImage,
    pub alpha: image::GrayImage,
    pub influence: image::GrayImage,
    pub used_model: bool,
}

fn mat_u16(values: &[u16], w: usize, h: usize) -> Result<core::Mat> {
    anyhow::ensure!(values.len() == w * h, "mat_u16: length mismatch");
    let mut m = unsafe { core::Mat::new_rows_cols(h as i32, w as i32, core::CV_16UC1) }
        .map_err(|e| ocv_err("new_rows_cols 16U", e))?;
    let p = m.data_mut();
    if p.is_null() {
        anyhow::bail!("mat_u16: no buffer");
    }
    unsafe { std::slice::from_raw_parts_mut(p as *mut u16, values.len()) }.copy_from_slice(values);
    Ok(m)
}

fn mat_u8(values: &[u8], w: usize, h: usize) -> Result<core::Mat> {
    anyhow::ensure!(values.len() == w * h, "mat_u8: length mismatch");
    let mut m = unsafe { core::Mat::new_rows_cols(h as i32, w as i32, core::CV_8UC1) }
        .map_err(|e| ocv_err("new_rows_cols 8U", e))?;
    let p = m.data_mut();
    if p.is_null() {
        anyhow::bail!("mat_u8: no buffer");
    }
    unsafe { std::slice::from_raw_parts_mut(p, values.len()) }.copy_from_slice(values);
    Ok(m)
}

fn gray_of(m: &core::Mat, w: usize, h: usize) -> Result<image::GrayImage> {
    anyhow::ensure!(m.typ() == core::CV_8UC1, "gray_of: expected 8UC1");
    image::GrayImage::from_vec(w as u32, h as u32, bytes_of(m)?.to_vec())
        .context("gray_of: buffer length")
}

fn rgb_of(m: &core::Mat, w: usize, h: usize) -> Result<image::RgbImage> {
    anyhow::ensure!(m.typ() == core::CV_8UC3, "rgb_of: expected 8UC3");
    image::RgbImage::from_vec(w as u32, h as u32, bytes_of(m)?.to_vec())
        .context("rgb_of: buffer length")
}

/// The former helper's `main()`: pick a foreground mask, then emit the three
/// spatial layers. `confidence` is the matting model output; when it is absent
/// or fails depth validation this falls back to depth-guided segmentation.
pub fn generate(
    photo: &image::RgbImage,
    depth: &[u16],
    confidence: Option<&image::GrayImage>,
) -> Result<Outcome> {
    let (w, h) = (photo.width() as usize, photo.height() as usize);
    let photo_mat = mat3_from_bytes(photo.as_raw(), w, h)?;
    let depth_mat = mat_u16(depth, w, h)?;

    let mut alpha = core::Mat::default();
    let mut mask = core::Mat::default();
    let mut used_model = false;

    if let Some(conf) = confidence {
        let conf_mat = mat_u8(conf.as_raw(), w, h)?;
        let (m, a) = mask_from_model(&conf_mat, &photo_mat, &depth_mat)?;
        if !m.empty() {
            mask = m;
            alpha = a;
            used_model = true;
        }
    }
    if mask.empty() {
        mask = segment_depth(&photo_mat, &depth_mat, false)?;
        if mask.empty() {
            mask = segment_depth(&photo_mat, &depth_mat, true)?;
        }
        if mask.empty() {
            anyhow::bail!("no suitable foreground subject was found");
        }
    }
    if alpha.empty() {
        erode_with(&mask, &mut alpha, 3)?;
        let mut softened = core::Mat::default();
        blur(&alpha, &mut softened, 0.9)?;
        alpha = softened;
    }

    Ok(Outcome {
        background: rgb_of(&background_fill(&photo_mat, &mask)?, w, h)?,
        alpha: gray_of(&alpha, w, h)?,
        influence: gray_of(&influence_map(&depth_mat, &mask)?, w, h)?,
        used_model,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Replays the frozen C++ helper inputs and writes the Rust outputs, so the
    /// golden comparison runs on identical bytes rather than a re-derived depth
    /// map. Run with: `cargo test --release -- --ignored --nocapture spatial_golden`
    #[test]
    #[ignore]
    fn spatial_golden_replay() {
        let dir =
            std::env::var("DEPTHSCAPE_GOLDEN").unwrap_or_else(|_| "../.data/golden-cpp".into());
        let read = |name: &str| {
            image::open(format!("{dir}/in/{name}"))
                .unwrap_or_else(|e| panic!("cannot read in/{name}: {e}"))
        };
        let photo = read("photo.png").to_rgb8();
        let depth_img = read("depth.png").into_luma16();
        let confidence = read("model.png").to_luma8();
        let depth: Vec<u16> = depth_img.pixels().map(|p| p[0]).collect();

        let started = std::time::Instant::now();
        let out = generate(&photo, &depth, Some(&confidence)).expect("golden replay failed");
        let elapsed = started.elapsed();

        let out_dir = format!("{dir}/out-rust");
        std::fs::create_dir_all(&out_dir).expect("cannot create out-rust");
        out.background
            .save(format!("{out_dir}/background.png"))
            .unwrap();
        out.alpha.save(format!("{out_dir}/matte.png")).unwrap();
        out.influence
            .save(format!("{out_dir}/influence.png"))
            .unwrap();
        println!(
            "Rust 版: 耗时 {:.2}s  used_model={}  尺寸 {}x{}",
            elapsed.as_secs_f64(),
            out.used_model,
            photo.width(),
            photo.height()
        );
    }
}
