cmake_minimum_required(VERSION 3.14)
project(MembershipAllocationClientModulePlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LOGOS_MODULE_BUILDER_ROOT is not set.")
endif()

configure_file(${CMAKE_CURRENT_SOURCE_DIR}/metadata.json
               ${CMAKE_CURRENT_BINARY_DIR}/metadata.json COPYONLY)

find_package(nlohmann_json REQUIRED)

if(WIN32)
    find_library(TINYCBOR_LIB NAMES libtinycbor.a PATHS $ENV{LOGOS_EXT_ROOT_LIBP2P}/lib ${CMAKE_CURRENT_SOURCE_DIR}/lib NO_DEFAULT_PATH REQUIRED)
else()
    set(TINYCBOR_LIB tinycbor)
endif()

logos_module(
    NAME membership_allocation_client_module
    SOURCES
        src/own_node.h
        src/own_node.cpp
    EXTERNAL_LIBS
        libp2p
    LINK_LIBRARIES
        ${TINYCBOR_LIB}
)

target_link_libraries(membership_allocation_client_module_module_plugin PUBLIC nlohmann_json::nlohmann_json)
