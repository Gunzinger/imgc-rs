/// This module provides webp conversion via the webp crate
pub mod webp;
/// This module provides avif conversion via the ravif crate
pub mod avif;
/// This module provides webp conversion via the image crate
pub mod webp_image;
/// This module provides png conversion via the image crate
pub mod png;
mod mozjpeg;

use crate::{
    converter::avif::encode_avif,
    converter::avif::{AlphaColorMode, BitDepth, ColorModel},
    converter::webp::encode_webp,
    converter::webp_image::encode_webp_image,
    converter::png::encode_png,
    converter::png::{CompressionType, FilterType},
    converter::mozjpeg::encode_mozjpeg,
    format::ImageFormat,
    Error,
};
use std::{
    collections::{LinkedList},
    fs,
    path::{Path, PathBuf},
    error::Error as StdError,
    sync::{Arc, atomic::AtomicBool},
};
use image::{ImageReader, ImageFormat as ImageImageFormat, DynamicImage, RgbImage};
use rayon::prelude::*;
use bytesize::ByteSize;
use indicatif::{ParallelProgressIterator, ProgressStyle};
use jpeg_decoder::Decoder;

// Include dependency version numbers
include!(concat!(env!("OUT_DIR"), "/versions.rs"));

/// Configuration parameters shared across all encoders
#[derive(Clone)]
pub struct CommonConfig {
    /// Glob pattern to match images to convert.
    /// Example: `images/**/*.png`
    pub pattern: String,

    /// Output directory (flat) of processed images.
    /// Defaults to the same location as the original images with the new file extension.
    pub output: String,

    /// Overwrite the existing output file if the current conversion resulted in a smaller file.
    /// Defaults to true.
    pub overwrite_if_smaller: bool,

    /// Overwrite existing outputs?
    /// Defaults to false. (Determined by filename match)
    pub overwrite_existing: bool,

    /// Discards the encoding result if it is larger than the input file (does not create an output file).
    /// Defaults to false.
    pub discard_if_larger_than_input: bool,
}

fn handle_conversion_error(path: PathBuf, err: Box<dyn StdError + Send + Sync>) -> (i32, i32, i32) {
    println!("File {}: could not be converted, error: {}", path.display() , err);
    (-2, 0, 0)
}

fn base_from_pattern(pattern: &str) -> String {
    let mut base = PathBuf::new();

    for part in Path::new(pattern) {
        let s = part.to_string_lossy();
        if s.contains('*') || s.contains('?') || s.contains('[') {
            break;
        }
        base.push(part);
    }

    base.to_string_lossy().to_string()
}

/// Processes and encodes images in a given directory to the specified image format.
pub fn convert_images(
    conf: CommonConfig,
    img_format: &ImageFormat,
    option_lossless: &Option<bool>,
    option_quality: &Option<f32>,
    option_speed: &Option<u8>,
    option_png_compression_type: &Option<CompressionType>,
    option_png_filter_type: &Option<FilterType>,
    option_avif_bit_depth: &Option<BitDepth>,
    option_avif_color_model: &Option<ColorModel>,
    option_avif_alpha_color_mode: &Option<AlphaColorMode>,
    option_avif_alpha_quality: &Option<f32>,
) -> Result<(), Error> {
    let mut paths: Vec<PathBuf> = glob::glob(&*conf.pattern)?
        .filter_map(|entry| entry.ok())
        .filter(|path|{
            let format = ImageFormat::from(path.as_path());
            format != ImageFormat::Unknown
                && format != ImageFormat::Avif // disable reading avif (FIXME: re-enable with reliable build+integration for reader)
        })
        .collect();
    paths.sort_by(|a,b| a.file_name().cmp(&b.file_name()));
    // TODO: check for collision candidates (same filename but different extensions => same encoded output filename format...)
    //  and come up with a solution
    let pattern_base = base_from_pattern(&conf.pattern);

    if paths.is_empty() {
        println!("No images to convert, check input glob pattern and supported input formats.");
        return Ok(());
    }

    // create output directory if it does not exist
    if ! conf.output.is_empty() {
        let output_directory = Path::new(&conf.output);
        if ! fs::exists(output_directory)? {
            // is it possible to warn in docker if the target output directory is not host mounted?
            println!("Creating output directory \"{:?}\"", output_directory);
            fs::create_dir_all(output_directory).unwrap_or_else(|err| {
                eprintln!("Error creating the output directory: {err}");
                std::process::exit(1);
            });
        }
    }
    // IDEA: create output filename from configurable regex

    println!("Converting {} files...", paths.len());
    let encoder_data = match img_format {
        ImageFormat::Webp => webp::encoder_info(option_lossless.unwrap_or(false), option_quality.unwrap_or(90.)),
        ImageFormat::WebpImage => webp_image::encoder_info(),
        ImageFormat::Avif => avif::encoder_info(option_quality.unwrap_or(90.), option_speed.unwrap_or(3), None, None),
        ImageFormat::Png => png::encoder_info(),
        ImageFormat::Jpeg => mozjpeg::encoder_info(),
        _ => "unknown encoder".parse().unwrap(),
    };
    println!("{}", encoder_data);

    let global_stop = Arc::new(AtomicBool::new(false));
    let stop_signal = global_stop.clone();
    let mut ctrlc_counter = 0;
    ctrlc::set_handler(move || {
        if !global_stop.load(std::sync::atomic::Ordering::Relaxed) {
            println!("received Ctrl+C, stopping further queue processing!");
            global_stop.store(true, std::sync::atomic::Ordering::Relaxed);
        } else {
            println!("an encoding task is still active!{} processing will end afterwards.", str::repeat("!", ctrlc_counter));
        }
        ctrlc_counter += 1;
    }).expect("Error setting Ctrl-C handler");

    let style = ProgressStyle::with_template("[{elapsed_precise}/~{duration_precise} ({eta_precise} rem.)] {wide_bar:.cyan/blue} {pos:>7}/{len:7}").unwrap();
    let _results: LinkedList<(isize, usize, usize)> = paths.clone()
        .into_par_iter()
        .progress_with_style(style)
        .map(|path|
            if stop_signal.load(std::sync::atomic::Ordering::Relaxed) {
                return (-1, 0, 0);
            } else {
                 convert_image(
                     &*path, img_format,
                     conf.output.clone(), pattern_base.clone(), conf.overwrite_if_smaller,
                     conf.overwrite_existing, conf.discard_if_larger_than_input,
                     option_lossless, option_quality, option_speed,
                     option_png_compression_type, option_png_filter_type,
                     option_avif_bit_depth, option_avif_color_model, option_avif_alpha_color_mode, option_avif_alpha_quality
                 )
            }
            .map_err(|err| handle_conversion_error(path, err)).unwrap_or_else(|_| (-2, 0, 0))
        )
        .collect();

    let encode_successful = _results.par_iter()
        .filter(|(status, _, _)| *status == 0).count();
    let encode_skipped = _results.par_iter()
        .filter(|(status, _, _)| *status == -1).count();
    let encode_errors = _results.par_iter()
        .filter(|(status, _, _)| *status == -2).count();

    let total_input_size = _results.par_iter()
        .filter(|(status, _, _)| *status == 0 || *status == -1)
        .map(|(_, input_size, _)| input_size).sum::<usize>();
    let total_output_size = _results.par_iter()
        .filter(|(status, _, _)| *status == 0 || *status == -1)
        .map(|(_, _, output_size)| output_size).sum::<usize>();

    println!("Encode statistics:");
    println!("Successful: {:?}", encode_successful);
    println!("Skipped:    {:?}", encode_skipped);
    println!("Errors:     {:?}", encode_errors);
    if total_input_size > 0 && total_output_size > 0 {
        println!("Total input size:  {}", ByteSize::b(total_input_size as u64));
        println!("Total output size: {}", ByteSize::b(total_output_size as u64));
        println!("Compression ratio: {:.02}%", total_output_size as f64 / total_input_size as f64 * 100.0);
    } else {
        println!("Input and output size could not be determined, please try using OS-native binaries.")
    }
    Ok(())
}

fn try_read_image(input_path: &Path) -> Result<DynamicImage, Box<dyn StdError + Send + Sync>> {
    // first try with autodetection
    let result = (|| -> Result<DynamicImage, Box<dyn StdError + Send + Sync>> {
        Ok(ImageReader::open(input_path)?.decode()?)
    })();

    if result.is_ok() {
        return result;
    }

    let err = result.err().unwrap();
    let msg = err.to_string();
    
    // "Illegal start bytes:8950" => imposter png hiding in other file extension
    if msg.contains("Illegal start bytes") && msg.contains("8950") {
        let mut reader = ImageReader::open(input_path)?;
        reader.set_format(ImageImageFormat::Png);
        if let Ok(decoded) = reader.decode() {
            return Ok(decoded);
        }
    }

    // Otherwise try generic extension based fallbacks, legacy pjpeg, x-png, etc.
    let ext = input_path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    // 2️⃣ If it's a JPEG-like file, try jpeg-decoder
    if ext == "pjpeg" || ext == "jpg" || ext == "jpeg" {
        //println!("image-rs could not load: {}; retrying with jpeg-decoder...", input_path.display());
        if let Ok(file) = fs::File::open(input_path) {
            let mut decoder = Decoder::new(file);
            if let Ok(pixels) = decoder.decode() {
                if let Some(info) = decoder.info() {
                    // Convert raw pixels to RgbImage
                    let img = RgbImage::from_raw(
                        info.width.into(),
                        info.height.into(),
                        pixels,
                    )
                        .ok_or("Failed to convert jpeg-decoder output to RgbImage")?;
                    return Ok(DynamicImage::ImageRgb8(img));
                }
            }
        }
    }

    let mut reader = ImageReader::open(input_path)?;
    match ext.as_str() {
        "pjpeg" | "jpg" | "jpeg" => reader.set_format(ImageImageFormat::Jpeg),
        "x-png" | "png" => reader.set_format(ImageImageFormat::Png),
        _ => return Err(err), // nothing else to try
    }

    if let Ok(decoded) = reader.decode() {
        Ok(decoded)
    } else {
        Err(err)
    }
}

fn normalize_prefix<P: AsRef<Path>>(p: P) -> PathBuf {
    let path = p.as_ref();

    let mut components = path.components().peekable();
    let mut normalized = PathBuf::new();

    // Skip leading CurrentDir (`.`) if present
    while let Some(c) = components.peek() {
        if c.as_os_str() == "." {
            components.next();
        } else {
            break;
        }
    }

    for c in components {
        normalized.push(c);
    }

    normalized
}

/// Encodes an image to the specified image format and saves it to the specified output directory.
fn convert_image(
    input_path: &Path,
    img_format: &ImageFormat,
    output: String,
    pattern_base: String,
    overwrite_if_smaller: bool,
    overwrite_existing: bool,
    discard_if_larger_than_input: bool,
    option_lossless: &Option<bool>,
    option_quality: &Option<f32>,
    option_speed: &Option<u8>,
    option_png_compression_type: &Option<CompressionType>,
    option_png_filter_type: &Option<FilterType>,
    option_avif_bit_depth: &Option<BitDepth>,
    option_avif_color_model: &Option<ColorModel>,
    option_avif_alpha_color_mode: &Option<AlphaColorMode>,
    option_avif_alpha_quality: &Option<f32>,
) -> Result<(isize, usize, usize), Box<dyn StdError + Send + Sync>> {
    // returns tuple (status, input_size (B), output_size (B))
    let ext = img_format.extension();
    let output_path;
    if output.is_empty() {
        output_path = input_path.with_extension(ext)
    } else {
        let pattern_base_norm = normalize_prefix(&pattern_base);
        let input_path_norm = normalize_prefix(&input_path);
        let rel_path = input_path_norm
            .strip_prefix(&pattern_base_norm)
            .unwrap_or_else(|_| Path::new(&input_path_norm));

        output_path = Path::new(&output)
            .join(rel_path.parent().unwrap_or_else(|| Path::new("")))
            .join(input_path_norm.file_stem().unwrap())
            .with_extension(ext);

        fs::create_dir_all(Path::new(&output).join(rel_path.parent().unwrap_or_else(|| Path::new(""))))?;
    };

    if fs::exists(output_path.clone())? && !overwrite_existing && !overwrite_if_smaller {
        // file exists, and we do not have any overwrite flag on? => return early
        //println!("skipped because output path exists and overwrite options are unset {}", input_path.display());
        return Ok((-1, 0, 0))
    }

    let image = try_read_image(input_path)?;

    let encode_lossless = option_lossless.unwrap_or(false);
    let encode_quality: f32 = option_quality.unwrap_or(90.);
    let encode_speed: u8 = option_speed.unwrap_or(3);

    let image_data = match img_format {
        // TODO: more PNG lossless optimizers, jpeg xl
        ImageFormat::Webp => encode_webp(&image, encode_lossless, encode_quality)?,
        ImageFormat::WebpImage => encode_webp_image(&image)?,
        ImageFormat::Avif => encode_avif(
            &image, encode_quality, encode_speed,
            *option_avif_bit_depth, *option_avif_color_model,
            *option_avif_alpha_color_mode, option_avif_alpha_quality.unwrap_or(90.))?,
        ImageFormat::Png => encode_png(&image, *option_png_compression_type, *option_png_filter_type)?,
        ImageFormat::Jpeg => encode_mozjpeg(&image)?,
        _ => return Err(Box::new(Error::from_string("Unsupported image format".to_string()))),
    };

    let output_size =  image_data.len();
    if fs::exists(output_path.clone())? &&
        output_size >= fs::metadata(output_path.clone())?.len() as usize &&
        overwrite_if_smaller {
        // overwrite if smaller flag is on, but output exists and is already smaller than our encode
        //  => abort
        // TODO: how to propagate this information upwards into statistics?
        //println!(
        //    "skipped because output path exists,\
        //      overwrite_if_smaller is active,\
        //      but new output is larger than the existing one {}",
        //    input_path.display());
        return Ok((-1, 0, 0));
    }

    let input_size = fs::metadata(&input_path)?.len() as usize;
    if discard_if_larger_than_input && output_size >= input_size {
        // TODO: how to propagate this information upwards into statistics?
        //println!(
        //    "skipped because the output is larger than the input,\
        //      and discard_if_larger_than_input is active {}",
        //    input_path.display());
        return Ok((-1, 0, 0));
    }

    fs::write(output_path.clone(), image_data)?;
    Ok((0, input_size, output_size))
}
