cmake_minimum_required(VERSION 3.16)
project(goal005_observe C)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})
find_package(VPP REQUIRED)

add_vpp_plugin(goal005_observe
  SOURCES observe.c
  API_FILES observe.api
  COMPONENT vpp-plugin-core
)
