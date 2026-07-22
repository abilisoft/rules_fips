use std::env;
use std::path::PathBuf;
use std::process::Command;

fn run(program: &str, arguments: &[String]) {
    let status = Command::new(program)
        .args(arguments)
        .env("PATH", "")
        .status()
        .unwrap_or_else(|error| panic!("failed to start {program}: {error}"));
    assert!(status.success(), "{program} exited with {status}");
}

fn flags(name: &str) -> Vec<String> {
    env::var(name)
        .unwrap_or_default()
        .split_whitespace()
        .map(str::to_owned)
        .collect()
}

fn main() {
    let original_directory = env::current_dir().expect("build-script working directory is required");
    let output = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR is required"));
    let source = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is required"))
        .join("native.c");
    let object = output.join("native.o");
    let archive = output.join("libnative_fixture.a");
    let compiler = env::var("CC").expect("target CC is required");
    let archiver = env::var("AR").expect("target AR is required");

    let mut compile_arguments = flags("CFLAGS");
    compile_arguments.extend([
        "-c".to_owned(),
        source.display().to_string(),
        "-o".to_owned(),
        object.display().to_string(),
    ]);
    env::set_current_dir(&output).expect("change to the native build directory");
    run(&compiler, &compile_arguments);

    let mut archive_arguments = flags("ARFLAGS");
    archive_arguments.extend([
        "crs".to_owned(),
        archive.display().to_string(),
        object.display().to_string(),
    ]);
    run(&archiver, &archive_arguments);
    env::set_current_dir(&original_directory).expect("restore the build-script working directory");

    let cmake = env::var("CMAKE").expect("hermetic CMAKE is required");
    let expected_ninja = env::var("EXPECTED_NINJA").expect("declared Ninja path is required");
    let cmake_source = PathBuf::from(
        env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is required"),
    )
    .join("cmake");
    let cmake_build = output.join("cmake");
    std::fs::create_dir_all(&cmake_build).expect("create the CMake build directory");
    let mut configure_arguments = vec![
        "-S".to_owned(),
        cmake_source.display().to_string(),
        "-B".to_owned(),
        cmake_build.display().to_string(),
        "-G".to_owned(),
        "Ninja".to_owned(),
        format!("-DCMAKE_C_COMPILER={compiler}"),
        format!("-DCMAKE_AR={archiver}"),
        "-DCMAKE_SYSTEM_NAME=Linux".to_owned(),
        "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY".to_owned(),
    ];
    let cflags = flags("CFLAGS").join(" ");
    configure_arguments.push(format!("-DCMAKE_C_FLAGS={cflags}"));
    env::set_current_dir(&cmake_build).expect("change to the CMake build directory");
    run(&cmake, &configure_arguments);
    let cache = std::fs::read_to_string(cmake_build.join("CMakeCache.txt")).expect("read the CMake cache");
    let expected_cache_entry = format!("CMAKE_MAKE_PROGRAM:FILEPATH={expected_ninja}");
    assert!(
        cache.lines().any(|line| line == expected_cache_entry),
        "CMake selected a make program other than the declared Ninja: expected {expected_cache_entry}",
    );
    run(
        &cmake,
        &[
            "--build".to_owned(),
            cmake_build.display().to_string(),
        ],
    );
    env::set_current_dir(&original_directory).expect("restore the build-script working directory");

    println!("cargo::rerun-if-changed=test/toolchain/native.c");
    println!("cargo::rustc-link-search=native={}", output.display());
    println!("cargo::rustc-link-lib=static=native_fixture");
    println!("cargo::rerun-if-changed=test/toolchain/cmake/CMakeLists.txt");
    println!("cargo::rerun-if-changed=test/toolchain/cmake/native.c");
}
