use crate::Error;
use image::DynamicImage;
use webp::{Encoder};
use crate::converter::DEPENDENCIES;

/// Provides encoder information
pub fn encoder_info(lossless: bool, qualify: f32) -> String {
    // we might have multiple versions of the package, use rfind to find the newest one
    let mut webp_version = "";
    match DEPENDENCIES.iter().rfind(|&&(name, _)| name == "webp") {
        Some((_name, version)) => {
            webp_version = version;
        }
        None => {
            println!("Package '{}' not found", "webp");
        }
    };

    format!(
        "Using \"webp\" ({}) with options (lossless: {}, qualify: {})",
        webp_version,
        lossless,
        qualify
    )
}


/// Encodes a `DynamicImage` to bytes of webp format
pub fn encode_webp(image: &DynamicImage, lossless: bool, quality: f32) -> Result<Vec<u8>, Error> {
    let converted_image: Option<DynamicImage> = match image {
        DynamicImage::ImageLuma8(_) => {
            Some(DynamicImage::ImageRgb8(image.to_rgb8()))
        },
        DynamicImage::ImageLumaA8(_) => {
            Some(DynamicImage::ImageRgba8(image.to_rgba8()))
        }
        _ => None,
    };

    let encoder = if let Some(ref img) = converted_image {
        // Use the converted image (Luma[A]8 paths are unimplemented in the webp lib :D
        Encoder::from_image(img)
            .map_err(|e| Error::from_string(format!("Failed to create webp encoder for luma input: {:?}", e)))?
    } else {
        Encoder::from_image(image)
            .map_err(|e| Error::from_string(format!("Failed to create webp encoder: {:?}", e)))?
    };

    let webp_data = encoder
        .encode_simple(lossless, quality)
        .map_err(|e| Error::from_string(format!("webp encoding failed: {:?}", e)))?;

    Ok(webp_data.to_vec())
}