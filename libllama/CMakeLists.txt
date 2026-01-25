# NOTE: Requires CMake 3.30 for deterministic Xcode GUIDs:
# https://gitlab.kitware.com/cmake/cmake/-/merge_requests/9241
cmake_minimum_required(VERSION 3.30)

set(CMAKE_CXX_FLAGS_INIT "-fvisibility=hidden")
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0")

project(libllama)

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

# Enable Metal for GPU acceleration on macOS
set(GGML_METAL ON CACHE BOOL "Enable Metal GPU acceleration" FORCE)
set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "Embed Metal library" FORCE)

# Disable server and other extras we don't need
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "Build llama.cpp server" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "Build llama.cpp tests" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "Build llama.cpp examples" FORCE)

# Disable i8mm/MATMUL_INT8 to fix compilation on GitHub Actions runners
# The feature detection passes but compilation fails with the newer Xcode toolchain
add_compile_definitions(GGML_MATMUL_INT8=0)
add_compile_options(-U__ARM_FEATURE_MATMUL_INT8)

add_subdirectory(llama.cpp)
