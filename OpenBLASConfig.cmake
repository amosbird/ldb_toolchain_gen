# ---- OpenBLAS package configuration ----
# This file is used by CMake's find_package() to locate and configure OpenBLAS.

# Package version
set(OpenBLAS_VERSION "0.3.30")

# Root dir is relative to this file's location
file(REAL_PATH "usr" _OpenBLAS_ROOT_DIR BASE_DIRECTORY "${CMAKE_CURRENT_LIST_DIR}")

# Include + library paths
set(OpenBLAS_INCLUDE_DIR "${_OpenBLAS_ROOT_DIR}/include")
set(OpenBLAS_LIBRARY "${_OpenBLAS_ROOT_DIR}/lib/libopenblas.a")

if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    set(OPENMP_COMPILE_OPTIONS "-fopenmp=libgomp")
elseif(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    set(OPENMP_COMPILE_OPTIONS "-fopenmp")
else()
    message(FATAL_ERROR "Unsupported compiler for OpenMP")
endif()

add_library(_openmp INTERFACE)
target_compile_options(_openmp INTERFACE ${OPENMP_COMPILE_OPTIONS})
target_link_options(_openmp INTERFACE ${OPENMP_COMPILE_OPTIONS})
target_link_libraries(_openmp INTERFACE gomp dl)
add_library(OpenMP::OpenMP ALIAS _openmp)

if(NOT TARGET OpenBLAS::OpenBLAS)
    add_library(OpenBLAS::OpenBLAS UNKNOWN IMPORTED)
    set_target_properties(OpenBLAS::OpenBLAS PROPERTIES
        IMPORTED_LOCATION "${OpenBLAS_LIBRARY}"
        INTERFACE_INCLUDE_DIRECTORIES "${OpenBLAS_INCLUDE_DIR}"
        INTERFACE_LINK_LIBRARIES "OpenMP::OpenMP;m;pthread"
    )
endif()

# Backwards-compatible variables
set(OpenBLAS_INCLUDE_DIRS "${OpenBLAS_INCLUDE_DIR}")
set(OpenBLAS_LIBRARIES "${OpenBLAS_LIBRARY};OpenMP::OpenMP;m;pthread")

# Mark variables for find_package_handle_standard_args
set(OpenBLAS_FOUND TRUE)
