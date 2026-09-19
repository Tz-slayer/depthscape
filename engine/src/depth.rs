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

pub struct DepthModel {
    session: Session,
}

impl DepthModel {
    pub fn load(model_path: &Path) -> Result<Self> {
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
        Ok(Self { session })
    }

    /// Run depth estimation on RGB8 pixels and return a normalised `0.0..=1.0`
    /// depth field of shape `height * width`.
    pub fn infer(&mut self, rgb: &[u8], width: u32, height: u32) -> Result<Vec<f32>> {
        let expected = (width as usize) * (height as usize) * 3;
        if rgb.len() != expected {
            bail!(
                "expected {expected} RGB samples for {width}x{height}, received {}",
                rgb.len()
            );
        }

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
            .map_err(|error| anyhow::anyhow!("depth inference failed: {error}"))?;

        let output = outputs[0]
            .try_extract_array::<f32>()
            .map_err(|error| anyhow::anyhow!("depth output is not an f32 tensor: {error}"))?;
        let data: Vec<f32> = output.iter().copied().collect();

        let pixels = (width as usize) * (height as usize);
        if data.len() != pixels {
            bail!(
                "model returned {} values, expected {pixels} for {width}x{height}",
                data.len()
            );
        }

        Ok(normalise(&data))
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
        .map(|value| ((value - minimum) / span).clamp(0.0, 1.0))
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
    fn chw_layout_is_channel_major_and_normalised() {
        // One pixel, pure white.
        let planar = to_normalised_chw(&[255, 255, 255], 1, 1);
        assert_eq!(planar.len(), 3);
        for (channel, value) in planar.iter().enumerate() {
            let expected = (1.0 - MEAN[channel]) / STD[channel];
            assert!((value - expected).abs() < 1e-5);
        }
    }
}
