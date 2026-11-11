//! Spatial asset preparation, computed in-process by `crate::spatial_ops`.

use anyhow::{bail, Context, Result};
use image::{DynamicImage, ImageBuffer, Luma, RgbImage, RgbaImage};

use crate::{
    config::{ModelDescriptor, Paths, SPATIAL_MAX_DIMENSION},
    spatial_ops::Outcome,
    spatial_segment,
};

pub struct Prepared {
    pub background: Vec<u8>,
    pub foreground: Vec<u8>,
    pub depth: Vec<u8>,
    pub matte: Vec<u8>,
    pub influence: Vec<u8>,
    /// The already-downscaled photo the spatial layers were computed from. The
    /// 3D scene samples this instead of the original wallpaper file.
    pub photo: Vec<u8>,
    pub warning: Option<String>,
}

pub fn prepare(
    paths: &Paths,
    source: &RgbImage,
    depth: &[f32],
    segment_model: &'static ModelDescriptor,
) -> Result<Prepared> {
    let (sw, sh) = source.dimensions();
    if depth.len() != sw as usize * sh as usize {
        bail!("spatial depth dimensions do not match the wallpaper");
    }
    let scale = (SPATIAL_MAX_DIMENSION as f64 / sw.max(sh) as f64).min(1.0);
    let (w, h) = (
        ((sw as f64 * scale).round() as u32).max(1),
        ((sh as f64 * scale).round() as u32).max(1),
    );
    let photo = image::imageops::resize(source, w, h, image::imageops::FilterType::Triangle);
    let depth_full = ImageBuffer::<Luma<u16>, Vec<u16>>::from_raw(
        sw,
        sh,
        depth
            .iter()
            .map(|x| (x.clamp(0.0, 1.0) * 65535.0).round() as u16)
            .collect(),
    )
    .context("cannot build spatial depth image")?;
    let depth_image =
        image::imageops::resize(&depth_full, w, h, image::imageops::FilterType::Triangle);
    let mut warning = None;
    let confidence = match spatial_segment::predict(paths, segment_model, &photo, w, h) {
        Ok(image) => Some(image),
        Err(error) => {
            let message = format!(
                "{} unavailable ({error:#}); using depth-guided foreground segmentation",
                segment_model.name
            );
            eprintln!("Depthscape: {message}");
            warning = Some(message);
            None
        }
    };

    let depth_u16: Vec<u16> = depth_image.pixels().map(|p| p[0]).collect();
    let Outcome {
        background,
        alpha,
        influence,
        used_model,
    } = crate::spatial_ops::generate(&photo, &depth_u16, confidence.as_ref())?;
    if confidence.is_some() && !used_model {
        let message = "IS-Net Anime subject did not pass depth validation; using depth-guided foreground segmentation".to_string();
        eprintln!("Depthscape: {message}");
        warning = Some(message);
    }

    // The compositor consumes encoded PNGs; nothing crosses a temporary file any more.
    let foreground = RgbaImage::from_fn(w, h, |x, y| {
        let rgb = photo.get_pixel(x, y);
        image::Rgba([rgb[0], rgb[1], rgb[2], alpha.get_pixel(x, y)[0]])
    });
    let encode = |image: DynamicImage| -> Result<Vec<u8>> {
        let mut cursor = std::io::Cursor::new(Vec::new());
        image.write_to(&mut cursor, image::ImageFormat::Png)?;
        Ok(cursor.into_inner())
    };
    Ok(Prepared {
        background: encode(DynamicImage::ImageRgb8(background))?,
        foreground: encode(DynamicImage::ImageRgba8(foreground))?,
        depth: encode(DynamicImage::ImageLuma16(depth_image))?,
        matte: encode(DynamicImage::ImageLuma8(alpha))?,
        influence: encode(DynamicImage::ImageLuma8(influence))?,
        photo: encode(DynamicImage::ImageRgb8(photo))?,
        warning,
    })
}

#[cfg(test)]
mod tests {
    /// A near blob on a far ground plane, sized and textured the way a real
    /// photograph is: the model path rejects a subject covering more than ~22%
    /// of the frame, and GrabCut needs intensity variation to fit its GMMs.
    #[test]
    fn generate_produces_a_matte_over_the_modelled_subject() {
        let (w, h) = (64usize, 64usize);
        let subject = |x: u32, y: u32| (x > 24 && x < 40) && (y > 12 && y < 36);
        let photo = image::RgbImage::from_fn(w as u32, h as u32, |x, y| {
            let tone = ((x * 7 + y * 11) % 97) as u8;
            if subject(x, y) {
                image::Rgb([
                    200u8.saturating_add(tone / 4),
                    60u8.saturating_add(tone / 6),
                    60,
                ])
            } else {
                image::Rgb([
                    20u8.saturating_add(tone / 3),
                    30,
                    40u8.saturating_add(tone / 5),
                ])
            }
        });
        let depth: Vec<u16> = (0..h)
            .flat_map(|y| {
                (0..w).map(move |x| {
                    if subject(x as u32, y as u32) {
                        60_000u16
                    } else {
                        8_000u16
                    }
                })
            })
            .collect();
        let confidence = image::GrayImage::from_fn(w as u32, h as u32, |x, y| {
            image::Luma([if subject(x, y) { 250u8 } else { 0u8 }])
        });

        let out = crate::spatial_ops::generate(&photo, &depth, Some(&confidence)).unwrap();
        assert!(
            out.used_model,
            "modelled subject should be accepted, not the depth fallback"
        );
        assert_eq!(out.alpha.dimensions(), (w as u32, h as u32));
        assert_eq!(out.background.dimensions(), (w as u32, h as u32));
        let covered = out.alpha.pixels().filter(|p| p[0] > 128).count();
        assert!(
            covered > 100,
            "matte must cover the subject, got {covered} pixels"
        );
    }

    #[test]
    fn generate_falls_back_to_depth_when_the_model_output_is_absent() {
        let (w, h) = (48usize, 48usize);
        let photo = image::RgbImage::from_fn(w as u32, h as u32, |x, y| {
            let subject = (x > 12 && x < 34) && (y > 6 && y < 40);
            if subject {
                image::Rgb([210, 200, 90])
            } else {
                image::Rgb([20, 30, 40])
            }
        });
        let depth: Vec<u16> = (0..h)
            .flat_map(|y| {
                (0..w).map(move |x| {
                    let subject = (x > 12 && x < 34) && (y > 6 && y < 40);
                    if subject {
                        62_000u16
                    } else {
                        5_000u16
                    }
                })
            })
            .collect();

        let out = crate::spatial_ops::generate(&photo, &depth, None).unwrap();
        assert!(!out.used_model);
        assert!(out.alpha.pixels().any(|p| p[0] > 128));
    }
}
