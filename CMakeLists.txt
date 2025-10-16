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

# Dependencies
find_package(CURL REQUIRED)

# Check for wslay (you may need to add it as a submodule or use find_package)
# For now, assuming it's in system or third_party
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/third_party/wslay/include)

# Third-party header-only libraries
include_directories(
        ${CMAKE_CURRENT_SOURCE_DIR}/third_party/sds
        ${CMAKE_CURRENT_SOURCE_DIR}/third_party/uthash/src
        ${CMAKE_CURRENT_SOURCE_DIR}/third_party/cJSON
)

# Source files
set(COLYSEUS_SOURCES
        src/settings.c
        src/client.c
        src/room.c
        src/network/http.c
        src/network/websocket_transport.c
        src/utils/str_util.c
)

# Third-party sources that need compilation
set(THIRD_PARTY_SOURCES
        third_party/sds/sds.c
        third_party/cJSON/cJSON.c
)

# Build shared library
add_library(colyseus SHARED
        ${COLYSEUS_SOURCES}
        ${THIRD_PARTY_SOURCES}
)

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
        PRIVATE
        CURL::libcurl
)

# Platform-specific libraries
if(UNIX AND NOT APPLE)
    target_link_libraries(colyseus PRIVATE m pthread)
elseif(WIN32)
    target_link_libraries(colyseus PRIVATE ws2_32)
endif()

# Installation
install(TARGETS colyseus
        LIBRARY DESTINATION lib
        ARCHIVE DESTINATION lib
        RUNTIME DESTINATION bin
)

install(DIRECTORY include/colyseus
        DESTINATION include
)

# Examples (optional)
option(BUILD_EXAMPLES "Build example programs" ON)
if(BUILD_EXAMPLES)
    add_subdirectory(examples)
endif()

# Tests (optional)
option(BUILD_TESTS "Build tests" OFF)
if(BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()

# Third-party libraries (as submodules)
add_subdirectory(third_party/sds)
add_subdirectory(third_party/cJSON)

# uthash is header-only
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/third_party/uthash/src)

# SHA1 (our own header-only)
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include/colyseus/utils)