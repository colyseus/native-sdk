cmake_minimum_required(VERSION 3.15)
project(colyseus-native-sdk VERSION 0.1.0 LANGUAGES C)

# C standard
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Build type
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# Compiler flags
if(MSVC)
    add_compile_options(/W4)
else()
    add_compile_options(-Wall -Wextra -pedantic)
endif()

# Options
option(BUILD_EXAMPLES "Build example programs" ON)
option(BUILD_TESTS "Build tests" OFF)
option(BUILD_SHARED_LIBS "Build shared library" ON)

# Find dependencies
find_package(CURL REQUIRED)

# wslay - assume it's in system or third_party
# You may need to adjust this based on your setup
find_library(WSLAY_LIBRARY NAMES wslay)
find_path(WSLAY_INCLUDE_DIR wslay/wslay.h)

if(NOT WSLAY_LIBRARY OR NOT WSLAY_INCLUDE_DIR)
    message(STATUS "wslay not found in system, looking in third_party")
    set(WSLAY_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/wslay/lib/includes)
    # You may need to build wslay separately or add it as submodule
endif()

# Third-party header-only libraries
set(SDS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/sds)
set(UTHASH_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/uthash/src)
set(CJSON_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/cJSON)

include_directories(
        ${SDS_DIR}
        ${UTHASH_DIR}
        ${CJSON_DIR}
        ${WSLAY_INCLUDE_DIR}
)

# Source files
set(COLYSEUS_SOURCES
        # Core
        src/settings.c
        src/client.c
        src/room.c

        # Network
        src/network/http.c
        src/network/websocket_transport.c

        # Utils
        src/utils/StrUtil.c
        src/utils/sha1_c.c
)

# Third-party sources that need compilation
set(THIRD_PARTY_SOURCES
        ${SDS_DIR}/sds.c
        ${CJSON_DIR}/cJSON.c
)

# Build library
if(BUILD_SHARED_LIBS)
    add_library(colyseus SHARED
            ${COLYSEUS_SOURCES}
            ${THIRD_PARTY_SOURCES}
    )
else()
    add_library(colyseus STATIC
            ${COLYSEUS_SOURCES}
            ${THIRD_PARTY_SOURCES}
    )
endif()

# Add alias for consistent naming
add_library(colyseus::sdk ALIAS colyseus)

# Include directories
target_include_directories(colyseus
        PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:include>
        PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# Link libraries
target_link_libraries(colyseus
        PUBLIC
        CURL::libcurl
        PRIVATE
        ${WSLAY_LIBRARY}
)

# Platform-specific libraries
if(UNIX AND NOT APPLE)
    target_link_libraries(colyseus PRIVATE m pthread)
elseif(APPLE)
    target_link_libraries(colyseus PRIVATE pthread)
elseif(WIN32)
    target_link_libraries(colyseus PRIVATE ws2_32)
endif()

# Compiler definitions
target_compile_definitions(colyseus PRIVATE
        $<$<CONFIG:Debug>:DEBUG>
        $<$<CONFIG:Release>:NDEBUG>
)

# Set output directories
set_target_properties(colyseus PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
        LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib
        ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib
)

# Installation
install(TARGETS colyseus
        EXPORT colyseus-targets
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
        INCLUDES DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)

install(DIRECTORY include/colyseus
        DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
        FILES_MATCHING PATTERN "*.h"
)

# Export targets
install(EXPORT colyseus-targets
        FILE colyseus-targets.cmake
        NAMESPACE colyseus::
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/colyseus
)

# Create config file
include(CMakePackageConfigHelpers)

configure_package_config_file(
        ${CMAKE_CURRENT_SOURCE_DIR}/cmake/colyseus-config.cmake.in
        ${CMAKE_CURRENT_BINARY_DIR}/colyseus-config.cmake
        INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/colyseus
)

write_basic_package_version_file(
        ${CMAKE_CURRENT_BINARY_DIR}/colyseus-config-version.cmake
        VERSION ${PROJECT_VERSION}
        COMPATIBILITY SameMajorVersion
)

install(FILES
        ${CMAKE_CURRENT_BINARY_DIR}/colyseus-config.cmake
        ${CMAKE_CURRENT_BINARY_DIR}/colyseus-config-version.cmake
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/colyseus
)

# Examples
if(BUILD_EXAMPLES)
    add_subdirectory(examples)
endif()

# Tests
if(BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()

# Print summary
message(STATUS "")
message(STATUS "Colyseus Native SDK Configuration:")
message(STATUS "  Version: ${PROJECT_VERSION}")
message(STATUS "  Build type: ${CMAKE_BUILD_TYPE}")
message(STATUS "  Shared libs: ${BUILD_SHARED_LIBS}")
message(STATUS "  C Compiler: ${CMAKE_C_COMPILER}")
message(STATUS "  C Standard: ${CMAKE_C_STANDARD}")
message(STATUS "  Install prefix: ${CMAKE_INSTALL_PREFIX}")
message(STATUS "")