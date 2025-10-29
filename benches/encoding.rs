use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};
use imgc::converter::avif::encode_avif;
use imgc::converter::webp::encode_webp;
use imgc::converter::webp_image::encode_webp_image;
use image::DynamicImage;
use std::path::PathBuf;
use std::fs;

fn load_test_images() -> Vec<(String, DynamicImage)> {
    let examples_dir = PathBuf::from("examples");
    let mut images = Vec::new();
    
    // Collect a limited number of images from different subdirectories for faster benchmarks
    let subdirs = vec!["jpg", "jpeg", "png"];
    
    for subdir in subdirs {
        let dir = examples_dir.join(subdir);
        if dir.exists() {
            if let Ok(entries) = fs::read_dir(&dir) {
                let mut count = 0;
                for entry in entries.flatten().take(3) { // Limit to 3 images per directory
                    let path = entry.path();
                    if let Some(ext) = path.extension() {
                        let ext_str = ext.to_string_lossy().to_lowercase();
                        if matches!(ext_str.as_str(), "jpg" | "jpeg" | "png" | "bmp") {
                            if let Ok(img) = image::open(&path) {
                                let name = format!("{}/{}", subdir, path.file_name().unwrap().to_string_lossy());
                                images.push((name, img));
                                count += 1;
                                if count >= 3 {
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    if images.is_empty() {
        eprintln!("Warning: No test images found in examples directory");
    }
    
    images
}

fn bench_webp_quality(c: &mut Criterion) {
    let images = load_test_images();
    if images.is_empty() {
        return;
    }
    
    let mut group = c.benchmark_group("webp_quality");
    group.sample_size(10);
    
    let qualities = vec![25.0, 50.0, 75.0, 90.0, 95.0, 100.0];
    
    for (img_name, image) in &images {
        for quality in &qualities {
            group.throughput(Throughput::Bytes(image.width() as u64 * image.height() as u64 * 4)); // Approximate bytes
            group.bench_with_input(
                BenchmarkId::new(format!("{}_q{}", img_name, quality), quality),
                quality,
                |b, &q| {
                    b.iter(|| {
                        encode_webp(black_box(image), false, black_box(q)).unwrap();
                    });
                },
            );
        }
    }
    
    // Also benchmark lossless mode
    for (img_name, image) in &images {
        group.throughput(Throughput::Bytes(image.width() as u64 * image.height() as u64 * 4));
        group.bench_with_input(
            BenchmarkId::new(format!("{}_lossless", img_name), &true),
            &true,
            |b, _| {
                b.iter(|| {
                    encode_webp(black_box(image), true, black_box(100.0)).unwrap();
                });
            },
        );
    }
    
    group.finish();
}

fn bench_webp_image(c: &mut Criterion) {
    let images = load_test_images();
    if images.is_empty() {
        return;
    }
    
    let mut group = c.benchmark_group("webp_image");
    group.sample_size(10);
    
    for (img_name, image) in &images {
        group.throughput(Throughput::Bytes(image.width() as u64 * image.height() as u64 * 4));
        group.bench_function(BenchmarkId::from_parameter(img_name), |b| {
            b.iter(|| {
                encode_webp_image(black_box(image)).unwrap();
            });
        });
    }
    
    group.finish();
}

fn bench_avif_quality_speed(c: &mut Criterion) {
    let images = load_test_images();
    if images.is_empty() {
        return;
    }
    
    let mut group = c.benchmark_group("avif_quality_speed");
    group.sample_size(10);
    
    let qualities = vec![50.0, 75.0, 90.0, 95.0];
    let speeds = vec![2, 4, 6, 9];
    
    for (img_name, image) in &images {
        for quality in &qualities {
            for speed in &speeds {
                group.throughput(Throughput::Bytes(image.width() as u64 * image.height() as u64 * 4));
                let bench_name = format!("{}_q{}_s{}", img_name, quality, speed);
                group.bench_with_input(
                    BenchmarkId::from_parameter(&bench_name),
                    &(*quality, *speed),
                    |b, (q, s)| {
                        b.iter(|| {
                            encode_avif(
                                black_box(image),
                                black_box(*q),
                                black_box(*s),
                                None,
                                None,
                                None,
                                black_box(*q),
                            )
                            .unwrap();
                        });
                    },
                );
            }
        }
    }
    
    group.finish();
}

criterion_group!(
    name = benches;
    config = Criterion::default()
        .warm_up_time(std::time::Duration::from_secs(1))
        .measurement_time(std::time::Duration::from_secs(2));
    targets = bench_webp_quality, bench_webp_image, bench_avif_quality_speed
);
criterion_main!(benches);

