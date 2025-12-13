# NOTE: we need this version for deterministic Xcode GUIDs:
# https://gitlab.kitware.com/cmake/cmake/-/merge_requests/9241
# Without this change, the GUIDs will be different every time the project is generated.
cmake_minimum_required(VERSION 3.30)

set(CMAKE_CXX_FLAGS_INIT "-fvisibility=hidden")
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0")

project(libwhisper)

option(BUILD_SHARED_LIBS "build shared libraries" OFF)

# Enable Link Time Optimization for better performance
set(GGML_LTO ON CACHE BOOL "Enable LTO" FORCE)

# Configure OpenMP for Apple Silicon (Homebrew libomp)
set(OpenMP_C_FLAGS "-Xclang -fopenmp" CACHE STRING "OpenMP C flags" FORCE)
set(OpenMP_CXX_FLAGS "-Xclang -fopenmp" CACHE STRING "OpenMP CXX flags" FORCE)
set(OpenMP_C_LIB_NAMES "omp" CACHE STRING "OpenMP C lib names" FORCE)
set(OpenMP_CXX_LIB_NAMES "omp" CACHE STRING "OpenMP CXX lib names" FORCE)
set(OpenMP_omp_LIBRARY "/opt/homebrew/opt/libomp/lib/libomp.dylib" CACHE FILEPATH "OpenMP library" FORCE)
include_directories("/opt/homebrew/opt/libomp/include")

# Enable CoreML for Neural Engine acceleration
set(WHISPER_COREML ON CACHE BOOL "Enable CoreML" FORCE)
set(WHISPER_COREML_ALLOW_FALLBACK ON CACHE BOOL "Allow fallback if CoreML fails" FORCE)

# Disable i8mm/MATMUL_INT8 to fix compilation on GitHub Actions runners
# The feature detection passes but compilation fails with the newer Xcode toolchain
# Undefine the feature macro to prevent i8mm intrinsics from being used
add_compile_definitions(GGML_MATMUL_INT8=0)
add_compile_options(-U__ARM_FEATURE_MATMUL_INT8)

add_subdirectory(whisper.cpp)
