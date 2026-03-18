cmake_minimum_required(VERSION 3.14)
project(kgd-client C)

add_library(kgd kgd.c mpack.c)
add_library(kgd::kgd ALIAS kgd)

target_include_directories(kgd PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
  $<INSTALL_INTERFACE:include>
)

target_compile_definitions(kgd PRIVATE MPACK_NODE=0 MPACK_EXTENSIONS=0)
target_compile_features(kgd PRIVATE c_std_11)

find_package(Threads REQUIRED)
target_link_libraries(kgd PRIVATE Threads::Threads)
