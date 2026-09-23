//! ONNX Runtime wrapper around Depth Anything V2 Small.

use anyhow::{bail, Context, Result};
use ndarray::Array4;
use ort::session::Session;
use ort::value::TensorRef;
use std::path::Path;

/// Depth Anything emits *relative inverse* depth: larger values are nearer.
///
/// Kept as a named constant rather than an inline comparison because the whole
/// meaning of the threshold slider depends on it. If a future model swaps the
/// convention, this is the single place to change.
pub const NEAR_IS_HIGH: bool = true;

/// ImageNet statistics used by the Depth Anything preprocessing step.
const MEAN: [f32; 3] = [0.485, 0.456, 0.406];
const STD: [f32; 3] = [0.229, 0.224, 0.225];

use crate::config::ModelKind;

pub struct DepthModel {
    session: Session,
    kind: ModelKind,
}

impl DepthModel {
    pub fn load(model_path: &Path, kind: ModelKind) -> Result<Self> {
        let threads = std::thread::available_parallelism()
            .map(|value| value.get())
            .unwrap_or(4)
            .min(8);
        let session = Session::builder()
            .map_err(|error| anyhow::anyhow!("cannot create an ONNX Runtime session builder: {error}"))?
            .with_intra_threads(threads)
            .map_err(|error| anyhow::anyhow!("cannot configure ONNX Runtime thread count: {error}"))?
            .commit_from_file(model_path)
            .map_err(|error| {
                anyhow::anyhow!("cannot load {}: {error}", model_path.display())
            })?;
        Ok(Self { session, kind })
    }

    /// Run depth estimation or foreground segmentation on RGB8 pixels and return a normalised `0.0..=1.0`
    /// field of shape `height * width`.
    pub fn infer(&mut self, rgb: &[u8], width: u32, height: u32) -> Result<Vec<f32>> {
        let expected = (width as usize) * (height as usize) * 3;
        if rgb.len() != expected {
            bail!(
                "expected {expected} RGB samples for {width}x{height}, received {}",
                rgb.len()
            );
        }

        let pixels = (width as usize) * (height as usize);
        match self.kind {
            ModelKind::DepthAnything | ModelKind::DepthAnythingV3 => {
                let tensor = if self.kind == ModelKind::DepthAnythingV3 {
                    // Depth Anything V3 expects 5D tensor: [batch, num_views, channels, height, width]
                    ndarray::Array5::from_shape_vec(
                        (1, 1, 3, height as usize, width as usize),
                        to_normalised_chw(rgb, width, height),
                    )
                    .context("cannot build 5D input tensor")?
                    .into_dyn()
                } else {
                    // Depth Anything V2 expects 4D tensor: [batch, channels, height, width]
                    Array4::from_shape_vec(
                        (1, 3, height as usize, width as usize),
                        to_normalised_chw(rgb, width, height),
                    )
                    .context("cannot build 4D input tensor")?
                    .into_dyn()
                };

                let input = TensorRef::from_array_view(&tensor)
                    .map_err(|error| anyhow::anyhow!("cannot wrap the input tensor: {error}"))?;
                let outputs = self
                    .session
                    .run(ort::inputs![input])
                    .map_err(|error| anyhow::anyhow!("inference failed: {error}"))?;

                let output = outputs[0]
                    .try_extract_array::<f32>()
                    .map_err(|error| anyhow::anyhow!("model output is not an f32 tensor: {error}"))?;
                let data: Vec<f32> = output.iter().copied().collect();
                if data.len() != pixels {
                    bail!(
                        "model returned {} values, expected {pixels} for {width}x{height}",
                        data.len()
                    );
                }
                if self.kind == ModelKind::DepthAnythingV3 {
                    // Depth Anything V3 outputs metric ray depth (physical distance Z),
                    // where smaller distance is closer to camera.
                    // Invert so that near objects have values close to 1.0, matching the
                    // pipeline convention (near is high).
                    let norm = normalise(&data);
                    Ok(norm.into_iter().map(|v| 1.0 - v).collect())
                } else {
                    Ok(normalise(&data))
                }
            }
            ModelKind::BiRefNet => {
                let tensor = Array4::from_shape_vec(
                    (1, 3, height as usize, width as usize),
                    to_normalised_chw(rgb, width, height),
                )
                .context("cannot build the input tensor")?;

                let input = TensorRef::from_array_view(&tensor)
                    .map_err(|error| anyhow::anyhow!("cannot wrap the input tensor: {error}"))?;
                let outputs = self
                    .session
                    .run(ort::inputs![input])
                    .map_err(|error| anyhow::anyhow!("inference failed: {error}"))?;

                let output = outputs[0]
                    .try_extract_array::<f32>()
                    .map_err(|error| anyhow::anyhow!("model output is not an f32 tensor: {error}"))?;
                let data: Vec<f32> = output.iter().copied().collect();
                if data.len() != pixels {
                    bail!(
                        "model returned {} values, expected {pixels} for {width}x{height}",
                        data.len()
                    );
                }
                Ok(sigmoid_mask(&data))
            }
        }
    }
}

/// Convert interleaved RGB8 into normalised planar CHW, as the model expects.
fn to_normalised_chw(rgb: &[u8], width: u32, height: u32) -> Vec<f32> {
    let pixels = (width as usize) * (height as usize);
    let mut planar = vec![0f32; pixels * 3];
    for index in 0..pixels {
        for channel in 0..3 {
            let value = rgb[index * 3 + channel] as f32 / 255.0;
            planar[channel * pixels + index] = (value - MEAN[channel]) / STD[channel];
        }
    }
    planar
}

/// Apply sigmoid to raw logits from BiRefNet: `1 / (1 + exp(-x))`.
/// Maps logits to calibrated foreground probabilities in `0.0..=1.0`.
fn sigmoid_mask(values: &[f32]) -> Vec<f32> {
    values
        .iter()
        .map(|&value| {
            if !value.is_finite() {
                0.0
            } else {
                (1.0 / (1.0 + (-value).exp())).clamp(0.0, 1.0)
            }
        })
        .collect()
}

/// Min-max scale to `0.0..=1.0`.
///
/// Relative depth has no absolute unit, so the range has to be re-derived per
/// image; a constant input is mapped to a constant mid-grey instead of dividing
/// by zero.
fn normalise(values: &[f32]) -> Vec<f32> {
    let mut minimum = f32::INFINITY;
    let mut maximum = f32::NEG_INFINITY;
    for value in values {
        if !value.is_finite() {
            continue;
        }
        minimum = minimum.min(*value);
        maximum = maximum.max(*value);
    }
    if !minimum.is_finite() || !maximum.is_finite() || maximum <= minimum {
        return vec![0.5; values.len()];
    }
    let span = maximum - minimum;
    values
        .iter()
        .map(|value| {
            if value.is_finite() {
                ((value - minimum) / span).clamp(0.0, 1.0)
            } else {
                0.5
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalise_maps_extremes_to_zero_and_one() {
        let normalised = normalise(&[-3.0, 0.0, 3.0]);
        assert_eq!(normalised[0], 0.0);
        assert_eq!(normalised[2], 1.0);
        assert!((normalised[1] - 0.5).abs() < 1e-6);
    }

    #[test]
    fn normalise_survives_a_constant_field() {
        let normalised = normalise(&[7.0, 7.0, 7.0]);
        assert_eq!(normalised, vec![0.5, 0.5, 0.5]);
    }

    #[test]
    fn normalise_survives_non_finite_input() {
        let normalised = normalise(&[f32::NAN, f32::NAN]);
        assert_eq!(normalised, vec![0.5, 0.5]);
    }

    #[test]
    fn normalise_replaces_isolated_non_finite_samples_with_mid_depth() {
        let normalised = normalise(&[0.0, f32::NAN, 10.0, f32::INFINITY]);

        assert_eq!(normalised, vec![0.0, 0.5, 1.0, 0.5]);
        assert!(normalised.iter().all(|value| value.is_finite()));
    }

    #[test]
    fn normalise_handles_the_full_finite_float_range() {
        let normalised = normalise(&[-f32::MAX, 0.0, f32::MAX]);

        assert_eq!(normalised, vec![0.0, 0.5, 1.0]);
        assert!(normalised.iter().all(|value| value.is_finite()));
    }

    #[test]
    fn chw_layout_is_channel_major_and_normalised() {
        // One pixel, pure white.
        let planar = to_normalised_chw(&[255, 255, 255], 1, 1);
        assert_eq!(planar.len(), 3);
        for (channel, value) in planar.iter().enumerate() {
            let expected = (1.0 - MEAN[channel]) / STD[channel];
            assert!((value - expected).abs() < 1e-5);
        }
    }

    #[test]
    fn sigmoid_mask_maps_logits_correctly() {
        let res = sigmoid_mask(&[0.0, -100.0, 100.0, f32::NAN]);
        assert!((res[0] - 0.5).abs() < 1e-6);
        assert_eq!(res[1], 0.0);
        assert_eq!(res[2], 1.0);
        assert_eq!(res[3], 0.0);
    }

    #[test]
    fn birefnet_session_inspection() {
        let home = match std::env::var("HOME") {
            Ok(val) => val,
            Err(_) => return,
        };
        let path = std::path::PathBuf::from(home).join(".local/share/depthscape/models/birefnet-lite/model.onnx");
        if !path.exists() {
            return;
        }
        let session = Session::builder().unwrap().commit_from_file(&path).unwrap();
        assert_eq!(session.inputs().len(), 1);
        assert_eq!(session.outputs().len(), 1);

        let dummy_rgb = vec![128u8; 1024 * 1024 * 3];
        let mut model = DepthModel::load(&path, crate::config::ModelKind::BiRefNet).unwrap();
        let result = model.infer(&dummy_rgb, 1024, 1024).unwrap();
        assert_eq!(result.len(), 1024 * 1024);
        for &v in &result {
            assert!((0.0..=1.0).contains(&v));
        }
    }

    #[test]
    fn da3_session_inspection() {
        let home = match std::env::var("HOME") {
            Ok(val) => val,
            Err(_) => return,
        };
        let path = std::path::PathBuf::from(home).join(".local/share/depthscape/models/depth-anything-v3-small/model.onnx");
        if !path.exists() {
            return;
        }
        let session = Session::builder().unwrap().commit_from_file(&path).unwrap();
        assert_eq!(session.inputs().len(), 1);
        assert_eq!(session.outputs().len(), 4);

        let dummy_rgb = vec![128u8; 518 * 294 * 3];
        let mut model = DepthModel::load(&path, crate::config::ModelKind::DepthAnythingV3).unwrap();
        let result = model.infer(&dummy_rgb, 518, 294).unwrap();
        assert_eq!(result.len(), 518 * 294);
        for &v in &result {
            assert!((0.0..=1.0).contains(&v));
        }
    }
}
