use crate::Error;
use image::{DynamicImage, EncodableLayout};
use crate::converter::DEPENDENCIES;
use std::panic;

/// Provides encoder information
pub fn encoder_info() -> String {
    // we might have multiple versions of the package, use rfind to find the newest one
    let mut mozjpeg_version = "";
    match DEPENDENCIES.iter().rfind(|&&(name, _)| name == "mozjpeg") {
        Some((_name, version)) => {
            mozjpeg_version = version;
        }
        None => {
            println!("Package '{}' not found", "mozjpeg");
        }
    };

    format!(
        "Using \"mozjpeg\" ({})",
        mozjpeg_version
    )
}


/// Encodes a `DynamicImage` to bytes of webp format
pub fn encode_mozjpeg(image: &DynamicImage) -> Result<Vec<u8>, Error> {
    let result = panic::catch_unwind(|| {
        let mut comp = mozjpeg::Compress::new(mozjpeg::ColorSpace::JCS_RGB);
        comp.set_size(image.width() as usize, image.height() as usize);

        let mut comp = comp.start_compress(Vec::new())
            .map_err(|e| Error::from_string(format!("mozjpeg encoding (start_compress) failed: {:?}", e)))?;

        comp.write_scanlines(image.to_rgb8().as_bytes())
            .map_err(|e| Error::from_string(format!("mozjpeg encoding (write_scanlines) failed: {:?}", e)))?;

        comp.finish().map_err(|e| Error::from_string(format!("mozjpeg encoding (finish) failed: {:?}", e)))
    });

    result.unwrap_or_else(|e| Err(Error::from_string(format!("mozjpeg encoding panicked: {:?}", e))))
}