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

# wslay
find_library(WSLAY_LIBRARY NAMES wslay)
find_path(WSLAY_INCLUDE_DIR wslay/wslay.h)

if(NOT WSLAY_LIBRARY OR NOT WSLAY_INCLUDE_DIR)
    message(FATAL_ERROR "wslay not found. Please install wslay.")
endif()

# Third-party header-only libraries
set(SDS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/sds)
set(UTHASH_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/uthash/src)
set(CJSON_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/cJSON)

# Verify third-party directories exist
foreach(dir ${SDS_DIR} ${UTHASH_DIR} ${CJSON_DIR})
    if(NOT EXISTS ${dir})
        message(FATAL_ERROR "Missing third-party dependency: ${dir}. Run 'git submodule update --init --recursive'")
    endif()
endforeach()

include_directories(
        ${SDS_DIR}
        ${UTHASH_DIR}
        ${CJSON_DIR}
        ${WSLAY_INCLUDE_DIR}
)

# Source files
set(COLYSEUS_SOURCES
        # Core
        src/common/settings.c
        src/client.c
        src/room.c

        # Auth
        src/auth/auth.c
        src/auth/secure_storage.c

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
if(ANDROID)
    find_library(log-lib log)
    target_link_libraries(colyseus PRIVATE ${log-lib} android)
elseif(UNIX AND NOT APPLE)
    target_link_libraries(colyseus PRIVATE m pthread dl)
elseif(APPLE)
    target_link_libraries(colyseus PRIVATE
            pthread
            "-framework Security"
            "-framework CoreFoundation"
    )
elseif(WIN32)
    target_link_libraries(colyseus PRIVATE ws2_32 advapi32)
elseif(EMSCRIPTEN)
    message(STATUS "Building for Web/WASM, using fallback storage")
else()
    message(WARNING "Unknown platform, using fallback storage only")
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
        LIBRARY DESTINATION lib
        ARCHIVE DESTINATION lib
        RUNTIME DESTINATION bin
)

install(DIRECTORY include/colyseus
        DESTINATION include
        FILES_MATCHING PATTERN "*.h"
)

# Examples
if(BUILD_EXAMPLES AND EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/examples)
    add_subdirectory(examples)
endif()

# Tests
if(BUILD_TESTS)
    enable_testing()

    # Storage tests
    add_executable(test_storage tests/test_storage.c)
    target_link_libraries(test_storage PRIVATE colyseus::sdk)

    # Auth tests
    add_executable(test_auth tests/test_auth.c)
    target_link_libraries(test_auth PRIVATE colyseus::sdk)

    # Room tests
    add_executable(test_room tests/test_room.c)
    target_link_libraries(test_room PRIVATE colyseus::sdk)

    # HTTP tests
    add_executable(test_http tests/test_http.c)
    target_link_libraries(test_http PRIVATE colyseus::sdk)

    # Integration test (requires running server)
    add_executable(test_integration tests/test_integration.c)
    target_link_libraries(test_integration PRIVATE colyseus::sdk)

    # Set output directory
    set_target_properties(
            test_storage
            test_auth
            test_room
            test_http
            test_integration
            PROPERTIES
            RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin/tests
    )

    # Add tests to CTest
    add_test(NAME storage COMMAND test_storage)
    add_test(NAME auth COMMAND test_auth)
    add_test(NAME room COMMAND test_room)
    add_test(NAME http COMMAND test_http)
    add_test(NAME integration COMMAND test_integration)
endif()

# Print summary
message(STATUS "")
message(STATUS "Colyseus Native SDK Configuration:")
message(STATUS "  Version: ${PROJECT_VERSION}")
message(STATUS "  Build type: ${CMAKE_BUILD_TYPE}")
message(STATUS "  Shared libs: ${BUILD_SHARED_LIBS}")
message(STATUS "  C Compiler: ${CMAKE_C_COMPILER}")
message(STATUS "  Install prefix: ${CMAKE_INSTALL_PREFIX}")
message(STATUS "")