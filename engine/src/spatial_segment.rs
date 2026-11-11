//! Foreground confidence for the spatial matte, independent of the depth model.

use anyhow::{bail, Context, Result};
use image::{GrayImage, ImageBuffer, Luma, RgbImage};
use ndarray::Array4;
use ort::{
    session::{OutputSelector, RunOptions, Session},
    value::TensorRef,
};

use crate::{
    config::{ModelDescriptor, ModelKind, Paths},
    depth::DepthModel,
    model,
};

const SIDE: u32 = 1024;

pub fn predict(
    paths: &Paths,
    descriptor: &'static ModelDescriptor,
    photo: &RgbImage,
    width: u32,
    height: u32,
) -> Result<GrayImage> {
    // The caller falls back to depth-guided segmentation when this fails, so a
    // missing foreground model degrades gracefully instead of triggering an
    // unrequested download. Install it explicitly with `setup --model <id>`.
    if model::state(paths, descriptor)? != model::ModelState::Ready {
        bail!(
            "foreground model '{}' is not installed; download it with `depthscape-engine setup --model {}`",
            descriptor.id,
            descriptor.id
        );
    }
    let path = model::model_path(paths, descriptor);
    match descriptor.kind {
        ModelKind::SpatialIsNet => predict_isnet(&path, descriptor, photo, width, height),
        ModelKind::BiRefNet => predict_birefnet(&path, descriptor.kind, photo, width, height),
        _ => bail!(
            "{} is a depth model, not a spatial foreground model",
            descriptor.id
        ),
    }
}

fn predict_isnet(
    path: &std::path::Path,
    descriptor: &crate::config::ModelDescriptor,
    photo: &RgbImage,
    width: u32,
    height: u32,
) -> Result<GrayImage> {
    let mut session = Session::builder()
        .map_err(|e| anyhow::anyhow!("cannot create IS-Net session: {e}"))?
        .with_intra_threads(4)
        .map_err(|e| anyhow::anyhow!("cannot configure IS-Net session: {e}"))?
        .commit_from_file(path)
        .map_err(|e| {
            anyhow::anyhow!(
                "cannot load spatial foreground model {}: {e}",
                path.display()
            )
        })?;
    if session.inputs().len() != 1
        || session.outputs().len() != 1
        || session.inputs()[0].dtype().tensor_type() != Some(ort::value::TensorElementType::Float32)
        || session.inputs()[0]
            .dtype()
            .tensor_shape()
            .map(|shape| &shape[..])
            != Some(&[1, 3, 1024, 1024][..])
    {
        bail!("IS-Net does not match its pinned input/output contract");
    }
    let input_name = session.inputs()[0].name();
    let output_name = session.outputs()[0].name();
    if (input_name != "img" && input_name != "input_image")
        || (output_name != "mask" && output_name != "output_image")
    {
        bail!("IS-Net unexpected input/output names: in={input_name}, out={output_name}");
    }

    // Match rembg's DisSession preprocessing: resize to a square with Lanczos,
    // scale by the image-wide maximum channel value, then subtract means
    // (ImageNet RGB means for isnet-anime, 0.5 for general-use isnet).
    let is_anime = descriptor.id.contains("anime");
    let means = if is_anime {
        [0.485, 0.456, 0.406]
    } else {
        [0.5, 0.5, 0.5]
    };
    let resized = image::imageops::resize(photo, SIDE, SIDE, image::imageops::FilterType::Lanczos3);
    let max_pixel = resized
        .pixels()
        .flat_map(|pixel| pixel.0)
        .max()
        .unwrap_or(1)
        .max(1) as f32;
    let count = (SIDE * SIDE) as usize;
    let mut chw = vec![0.0f32; count * 3];
    for (index, pixel) in resized.pixels().enumerate() {
        for channel in 0..3 {
            chw[channel * count + index] = pixel[channel] as f32 / max_pixel - means[channel];
        }
    }
    let tensor = Array4::from_shape_vec((1, 3, SIDE as usize, SIDE as usize), chw)?;
    let input = TensorRef::from_array_view(&tensor)
        .map_err(|e| anyhow::anyhow!("cannot prepare IS-Net input: {e}"))?;
    let options = RunOptions::new()
        .map_err(|e| anyhow::anyhow!("cannot configure IS-Net outputs: {e}"))?
        .with_outputs(OutputSelector::no_default().with(output_name));
    let outputs = session
        .run_with_options(ort::inputs![input], &options)
        .map_err(|e| anyhow::anyhow!("IS-Net inference failed: {e}"))?;
    if outputs.len() != 1 {
        bail!(
            "IS-Net returned {} selected outputs, expected 1",
            outputs.len()
        );
    }
    let field = outputs[0]
        .try_extract_array::<f32>()
        .map_err(|e| anyhow::anyhow!("invalid IS-Net output: {e}"))?;
    if field.shape() != [1, 1, SIDE as usize, SIDE as usize] {
        bail!("unexpected IS-Net output shape: {:?}", field.shape());
    }
    let (min, max) = field
        .iter()
        .fold((f32::INFINITY, f32::NEG_INFINITY), |(lo, hi), &v| {
            if v.is_finite() {
                (lo.min(v), hi.max(v))
            } else {
                (lo, hi)
            }
        });
    if !min.is_finite() || !max.is_finite() || max - min < 0.00001 {
        bail!("IS-Net returned an invalid foreground confidence map");
    }
    let pixels: Vec<u8> = field
        .iter()
        .map(|v| {
            if v.is_finite() {
                (((v - min) / (max - min)).clamp(0.0, 1.0) * 255.0).round() as u8
            } else {
                0
            }
        })
        .collect();
    let matte = ImageBuffer::<Luma<u8>, _>::from_raw(SIDE, SIDE, pixels)
        .context("cannot construct spatial foreground confidence")?;
    Ok(image::imageops::resize(
        &matte,
        width,
        height,
        image::imageops::FilterType::Lanczos3,
    ))
}

fn predict_birefnet(
    path: &std::path::Path,
    kind: ModelKind,
    photo: &RgbImage,
    width: u32,
    height: u32,
) -> Result<GrayImage> {
    // BiRefNet shares the preprocessing and sigmoid postprocessing already used
    // by the depth pipeline; only the caller's interpretation differs.
    let mut model = DepthModel::load(path, kind)?;
    let resized = image::imageops::resize(photo, SIDE, SIDE, image::imageops::FilterType::Lanczos3);
    let field = model
        .infer(resized.as_raw(), SIDE, SIDE)
        .context("cannot run the BiRefNet foreground model")?;
    let pixels: Vec<u8> = field
        .iter()
        .map(|value| (value.clamp(0.0, 1.0) * 255.0).round() as u8)
        .collect();
    let matte = ImageBuffer::<Luma<u8>, _>::from_raw(SIDE, SIDE, pixels)
        .context("cannot construct the BiRefNet foreground confidence")?;
    Ok(image::imageops::resize(
        &matte,
        width,
        height,
        image::imageops::FilterType::Lanczos3,
    ))
}
