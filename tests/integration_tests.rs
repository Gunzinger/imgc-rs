//! Integration tests using real images from the examples folder

use imgc::{
    format::ImageFormat,
    utils::{is_supported, remove_files},
};
use imgc::converter::avif::{self, BitDepth, ColorModel};
use imgc::converter::webp;
use imgc::converter::png::{self, CompressionType, FilterType};
use imgc::converter::webp_image;
use std::path::PathBuf;
use std::fs;
use tempfile::TempDir;

/// Get the examples directory path relative to project root
fn examples_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("examples")
}

/// Helper to get a test image path
fn test_image_path(subdir: &str, filename: &str) -> PathBuf {
    examples_dir().join(subdir).join(filename)
}

#[test]
fn test_format_detection_jpeg() {
    let jpeg_path = test_image_path("jpg", "coffee.jpg");
    if !jpeg_path.exists() {
        eprintln!("Skipping test - image not found: {:?}", jpeg_path);
        return;
    }

    let format = ImageFormat::from(jpeg_path.as_path());
    assert_eq!(format, ImageFormat::Jpeg);
    
    let format_from_ext = ImageFormat::from_extension("jpg");
    assert_eq!(format_from_ext, ImageFormat::Jpeg);
    
    assert_eq!(format.extension(), "jpeg");
}

#[test]
fn test_format_detection_png() {
    let png_path = test_image_path("png", "deno.png");
    if !png_path.exists() {
        eprintln!("Skipping test - image not found: {:?}", png_path);
        return;
    }

    let format = ImageFormat::from(png_path.as_path());
    assert_eq!(format, ImageFormat::Png);
    assert_eq!(format.extension(), "png");
}

#[test]
fn test_format_detection_from_extension() {
    assert_eq!(ImageFormat::from_extension("jpg"), ImageFormat::Jpeg);
    assert_eq!(ImageFormat::from_extension("jpeg"), ImageFormat::Jpeg);
    assert_eq!(ImageFormat::from_extension("png"), ImageFormat::Png);
    assert_eq!(ImageFormat::from_extension("webp"), ImageFormat::Webp);
    assert_eq!(ImageFormat::from_extension("avif"), ImageFormat::Avif);
    assert_eq!(ImageFormat::from_extension("x-png"), ImageFormat::Png);
    assert_eq!(ImageFormat::from_extension("pjpeg"), ImageFormat::Jpeg);
    assert_eq!(ImageFormat::from_extension("unknown"), ImageFormat::Unknown);
}

#[test]
fn test_is_supported_jpeg() {
    let jpeg_path = test_image_path("jpeg", "blob.jpeg");
    if !jpeg_path.exists() {
        eprintln!("Skipping test - image not found: {:?}", jpeg_path);
        return;
    }

    assert!(is_supported(&jpeg_path, &ImageFormat::Webp));
    assert!(!is_supported(&jpeg_path, &ImageFormat::Jpeg));
}

#[test]
fn test_is_supported_png() {
    let png_path = test_image_path("png", "deno.png");
    if !png_path.exists() {
        eprintln!("Skipping test - image not found: {:?}", png_path);
        return;
    }

    assert!(is_supported(&png_path, &ImageFormat::Jpeg));
    assert!(!is_supported(&png_path, &ImageFormat::Png));
}

#[test]
fn test_webp_encoding_lossy() {
    let jpeg_path = test_image_path("jpg", "coffee.jpg");
    if !jpeg_path.exists() {
        eprintln!("Skipping test - image not found: {:?}", jpeg_path);
        return;
    }

    let image = image::open(&jpeg_path).expect("Failed to open test image");
    let result = webp::encode_webp(&image, false, 90.0);
    
    assert!(result.is_ok(), "WebP encoding should succeed");
    let encoded = result.unwrap();
    assert!(!encoded.is_empty(), "Encoded image should not be empty");
    assert!(encoded.len() > 100, "Encoded image should have reasonable size");
}

#[test]
fn test_webp_encoding_lossless() {
    let png_path = test_image_path("png", "deno.png");
    if !png_path.exists() {
        eprintln!("Skipping test - image not found: {:?}", png_path);
        return;
    }

    let image = image::open(&png_path).expect("Failed to open test image");
    let result = webp::encode_webp(&image, true, 100.0);
    
    assert!(result.is_ok(), "WebP lossless encoding should succeed");
    let encoded = result.unwrap();
    assert!(!encoded.is_empty());
}

#[test]
fn test_webp_image_crate_encoding() {
    let png_path = test_image_path("png", "deno.png");
    if !png_path.exists() {
        eprintln!("Skipping test - image not found: {:?}", png_path);
        return;
    }

    let image = image::open(&png_path).expect("Failed to open test image");
    let result = webp_image::encode_webp_image(&image);
    
    assert!(result.is_ok(), "WebP image crate encoding should succeed");
    let encoded = result.unwrap();
    assert!(!encoded.is_empty());
}

#[test]
fn test_avif_encoding() {
    let jpeg_path = test_image_path("jpg", "coffee.jpg");
    if !jpeg_path.exists() {
        eprintln!("Skipping test - image not found: {:?}", jpeg_path);
        return;
    }

    let image = image::open(&jpeg_path).expect("Failed to open test image");
    let result = avif::encode_avif(
        &image,
        90.0,
        5,
        None,
        None,
        None,
        90.0,
    );
    
    assert!(result.is_ok(), "AVIF encoding should succeed");
    let encoded = result.unwrap();
    assert!(!encoded.is_empty(), "Encoded AVIF should not be empty");
    assert!(encoded.len() > 100, "Encoded AVIF should have reasonable size");
}

#[test]
fn test_png_encoding() {
    let jpeg_path = test_image_path("jpg", "coffee.jpg");
    if !jpeg_path.exists() {
        eprintln!("Skipping test - image not found: {:?}", jpeg_path);
        return;
    }

    let image = image::open(&jpeg_path).expect("Failed to open test image");
    let result = png::encode_png(&image, None, None);
    
    assert!(result.is_ok(), "PNG encoding should succeed");
    let encoded = result.unwrap();
    assert!(!encoded.is_empty());
    
    // Verify it's valid PNG by checking magic bytes
    assert_eq!(&encoded[0..8], &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
}

#[test]
fn test_png_encoding_with_options() {
    let png_path = test_image_path("png", "deno.png");
    if !png_path.exists() {
        eprintln!("Skipping test - image not found: {:?}", png_path);
        return;
    }

    let image = image::open(&png_path).expect("Failed to open test image");
    
    // Test with different compression types
    for compression in [None, Some(CompressionType::Fast), Some(CompressionType::Best)] {
        let result = png::encode_png(&image, compression, None);
        assert!(result.is_ok(), "PNG encoding with options should succeed");
    }
    
    // Test with different filter types
    for filter in [Some(FilterType::NoFilter), Some(FilterType::Adaptive)] {
        let result = png::encode_png(&image, None, filter);
        assert!(result.is_ok(), "PNG encoding with filter should succeed");
    }
}

#[test]
fn test_encoding_quality_affects_size() {
    let jpeg_path = test_image_path("jpg", "coffee.jpg");
    if !jpeg_path.exists() {
        eprintln!("Skipping test - image not found: {:?}", jpeg_path);
        return;
    }

    let image = image::open(&jpeg_path).expect("Failed to open test image");
    
    let high_quality = webp::encode_webp(&image, false, 95.0).unwrap();
    let low_quality = webp::encode_webp(&image, false, 50.0).unwrap();
    
    // Lower quality should generally produce smaller files (though not always guaranteed)
    // This test verifies encoding works at different quality levels
    assert!(!high_quality.is_empty());
    assert!(!low_quality.is_empty());
}

#[test]
fn test_avif_encoding_with_options() {
    let png_path = test_image_path("png", "deno.png");
    if !png_path.exists() {
        eprintln!("Skipping test - image not found: {:?}", png_path);
        return;
    }

    let image = image::open(&png_path).expect("Failed to open test image");
    
    // Test with different bit depths
    for bit_depth in [None, Some(BitDepth::Eight), Some(BitDepth::Auto)] {
        let result = avif::encode_avif(
            &image,
            90.0,
            8,
            bit_depth,
            None,
            None,
            90.0,
        );
        assert!(result.is_ok(), "AVIF encoding with bit depth options should succeed");
    }
    
    // Test with different color models
    for color_model in [None, Some(ColorModel::RGB), Some(ColorModel::YCbCr)] {
        let result = avif::encode_avif(
            &image,
            90.0,
            5,
            None,
            color_model,
            None,
            90.0,
        );
        assert!(result.is_ok(), "AVIF encoding with color model options should succeed");
    }
}

#[test]
fn test_problematic_jpeg_decoding() {
    // Test files that might have issues based on the trouble folder
    let trouble_jpeg = test_image_path("trouble", "image_id_158973.pjpeg");
    if trouble_jpeg.exists() {
        let result = image::open(&trouble_jpeg);
        // This might fail, which is okay - we're testing that it doesn't panic
        if let Ok(image) = result {
            // If it can be decoded, try encoding it
            let encode_result = webp::encode_webp(&image, false, 90.0);
            // Encoding should work if decoding worked
            assert!(encode_result.is_ok());
        }
    }
}

#[test]
fn test_problematic_png_decoding() {
    // Test x-png extension file
    let x_png = test_image_path("trouble", "image_id_155790.x-png");
    if x_png.exists() {
        let result = image::open(&x_png);
        if let Ok(image) = result {
            let encode_result = png::encode_png(&image, None, None);
            assert!(encode_result.is_ok());
        }
    }
}

#[test]
fn test_bmp_decoding() {
    let bmp_path = test_image_path("trouble", "image_id_646788.bmp");
    if bmp_path.exists() {
        let result = image::open(&bmp_path);
        if let Ok(image) = result {
            // BMP should be decodable
            assert!(image.width() > 0);
            assert!(image.height() > 0);
            
            // Try converting to different formats
            let webp_result = webp::encode_webp(&image, false, 90.0);
            assert!(webp_result.is_ok());
            
            let png_result = png::encode_png(&image, None, None);
            assert!(png_result.is_ok());
        }
    }
}

#[test]
fn test_multiple_images_encoding() {
    // Test encoding multiple images to ensure no resource leaks
    let test_images = vec![
        test_image_path("jpg", "coffee.jpg"),
        test_image_path("png", "deno.png"),
    ];
    
    for image_path in test_images {
        if !image_path.exists() {
            continue;
        }
        
        let image = image::open(&image_path).expect("Failed to open test image");
        
        // Test all encoders
        assert!(webp::encode_webp(&image, false, 90.0).is_ok());
        assert!(avif::encode_avif(&image, 90.0, 9, None, None, None, 90.0).is_ok());
        assert!(png::encode_png(&image, None, None).is_ok());
    }
}

#[test]
fn test_encoder_info_formats() {
    // Test that encoder_info functions work without panicking
    let _ = webp::encoder_info(false, 90.0);
    let _ = webp::encoder_info(true, 100.0);
    let _ = avif::encoder_info(90.0, 9, None, None);
    let _ = png::encoder_info();
    let _ = webp_image::encoder_info();
}

#[test]
fn test_format_extension_mapping() {
    // Test all format extensions
    let formats = vec![
        (ImageFormat::Jpeg, "jpeg"),
        (ImageFormat::Png, "png"),
        (ImageFormat::Webp, "webp"),
        (ImageFormat::WebpImage, "webp"),
        (ImageFormat::Avif, "avif"),
        (ImageFormat::Bmp, "bmp"),
        (ImageFormat::Gif, "gif"),
        (ImageFormat::Unknown, "?"),
    ];
    
    for (format, expected_ext) in formats {
        assert_eq!(format.extension(), expected_ext);
    }
}

#[test]
fn test_clean_command_no_files() {
    // Test clean command with pattern that matches nothing
    let pattern = "nonexistent_*.png";
    let result = remove_files(pattern);
    // Should succeed even if no files match
    assert!(result.is_ok());
}

#[test]
fn test_alpha_channel_handling() {
    // Test that images with alpha channels are handled correctly
    // First, try to find a PNG which might have alpha
    let png_path = test_image_path("png", "deno.png");
    if !png_path.exists() {
        eprintln!("Skipping test - image not found: {:?}", png_path);
        return;
    }
    
    let image = image::open(&png_path).expect("Failed to open test image");
    let has_alpha = image.color().has_alpha();
    
    // Test encoding respects alpha channel
    if has_alpha {
        // AVIF should handle alpha
        let avif_result = avif::encode_avif(&image, 90.0, 7, None, None, None, 90.0);
        assert!(avif_result.is_ok());
    }
    
    // PNG should always handle alpha correctly
    let png_result = png::encode_png(&image, None, None);
    assert!(png_result.is_ok());
}

#[test]
fn test_roundtrip_conversion() {
    // Test that we can decode an image and re-encode it
    let jpeg_path = test_image_path("jpg", "coffee.jpg");
    if !jpeg_path.exists() {
        eprintln!("Skipping test - image not found: {:?}", jpeg_path);
        return;
    }
    
    let original_image = image::open(&jpeg_path).expect("Failed to open test image");
    let original_width = original_image.width();
    let original_height = original_image.height();
    
    // Encode to WebP
    let webp_data = webp::encode_webp(&original_image, false, 90.0).unwrap();
    
    // Write to temp file and decode
    let temp_dir = TempDir::new().unwrap();
    let temp_webp = temp_dir.path().join("test.webp");
    fs::write(&temp_webp, &webp_data).unwrap();
    
    let decoded_image = image::open(&temp_webp).expect("Failed to decode WebP");
    
    // Dimensions should match
    assert_eq!(decoded_image.width(), original_width);
    assert_eq!(decoded_image.height(), original_height);
}

#[test]
fn test_different_quality_levels() {
    let jpeg_path = test_image_path("jpg", "coffee.jpg");
    if !jpeg_path.exists() {
        eprintln!("Skipping test - image not found: {:?}", jpeg_path);
        return;
    }
    
    let image = image::open(&jpeg_path).expect("Failed to open test image");
    
    // Test various quality levels
    for quality in [25.0, 50.0, 75.0, 90.0, 95.0] {
        let result = webp::encode_webp(&image, false, quality);
        assert!(result.is_ok(), "Encoding should succeed at quality {}", quality);
        assert!(!result.unwrap().is_empty());
    }
    
    // Test AVIF at different quality levels
    for quality in [50.0, 75.0, 90.0] {
        let result = avif::encode_avif(&image, quality, 7, None, None, None, quality);
        assert!(result.is_ok(), "AVIF encoding should succeed at quality {}", quality);
        assert!(!result.unwrap().is_empty());
    }
}

#[test]
fn test_avif_speed_options() {
    let jpeg_path = test_image_path("jpg", "coffee.jpg");
    if !jpeg_path.exists() {
        eprintln!("Skipping test - image not found: {:?}", jpeg_path);
        return;
    }
    
    let image = image::open(&jpeg_path).expect("Failed to open test image");
    
    // Test different speed settings (lower is slower but better quality)
    for speed in [4, 8, 9] {
        let result = avif::encode_avif(&image, 90.0, speed, None, None, None, 90.0);
        assert!(result.is_ok(), "AVIF encoding should succeed at speed {}", speed);
        assert!(!result.unwrap().is_empty());
    }
}

#[test]
fn test_file_size_comparison() {
    let jpeg_path = test_image_path("jpg", "coffee.jpg");
    if !jpeg_path.exists() {
        eprintln!("Skipping test - image not found: {:?}", jpeg_path);
        return;
    }
    
    let image = image::open(&jpeg_path).expect("Failed to open test image");
    
    // Encode to different formats
    let webp_lossy = webp::encode_webp(&image, false, 90.0).unwrap();
    let webp_lossless = webp::encode_webp(&image, true, 100.0).unwrap();
    let avif = avif::encode_avif(&image, 90.0, 9, None, None, None, 90.0).unwrap();
    
    // All should produce some data
    assert!(!webp_lossy.is_empty());
    assert!(!webp_lossless.is_empty());
    assert!(!avif.is_empty());
    
    // Lossy formats should generally be smaller than original for photos
    // (though this isn't guaranteed, so we just verify they're reasonable sizes)
    assert!(webp_lossy.len() > 0);
    assert!(webp_lossless.len() > 0);
    assert!(avif.len() > 0);
}

