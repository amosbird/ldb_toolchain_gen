cmake_minimum_required(VERSION 3.14)

project(glibc-compatibility)

enable_language(ASM)
include(CheckIncludeFile)
check_include_file("sys/random.h" HAVE_SYS_RANDOM_H)

macro(add_glob cur_list)
    file(GLOB __tmp RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} ${ARGN})
    list(APPEND ${cur_list} ${__tmp})
endmacro()

macro(add_headers_and_sources prefix common_path)
    add_glob(${prefix}_headers ${CMAKE_CURRENT_SOURCE_DIR} ${common_path}/*.h)
    add_glob(${prefix}_sources ${common_path}/*.cpp ${common_path}/*.c ${common_path}/*.h)
endmacro()

add_headers_and_sources(glibc_compatibility .)
add_headers_and_sources(glibc_compatibility musl)
add_headers_and_sources(glibc_compatibility memcpy)
set_source_files_properties(memcpy/memcpy.c PROPERTIES COMPILE_FLAGS "-fno-builtin-memcpy")

list (APPEND glibc_compatibility_sources musl/x86_64/syscall.s musl/x86_64/longjmp.s)
set (musl_arch_include_dir musl/x86_64)

list(REMOVE_ITEM glibc_compatibility_sources musl/getentropy.c)
if(HAVE_SYS_RANDOM_H)
    list(APPEND glibc_compatibility_sources musl/getentropy.c)
endif()

# Need to omit frame pointers to match the performance of glibc
set (CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fomit-frame-pointer")
add_library(glibc-compatibility STATIC ${glibc_compatibility_sources})
target_include_directories(glibc-compatibility PRIVATE ${musl_arch_include_dir})
target_compile_options(glibc-compatibility PRIVATE -fPIC)
