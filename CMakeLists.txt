cmake_minimum_required(VERSION 3.15)
project(colyseus-native-sdk VERSION 0.1.0)

set(CMAKE_CXX_STANDARD 17)

option(WITH_HTTP_CURL "Use libcurl for HTTP" ON)
option(WITH_WS_WSLAY "Use wslay for WebSocket" ON)

# Dependencies
find_package(CURL REQUIRED)
find_package(RapidJSON CONFIG REQUIRED)

# Find wslay
find_path(WSLAY_INCLUDE_DIR wslay/wslay.h)
find_library(WSLAY_LIBRARY wslay)

add_library(colyseus-sdk SHARED
        src/common/settings.cpp
        src/client.cpp
        src/network/http.cpp
        src/network/websocket_transport.cpp
)

target_include_directories(colyseus-sdk PUBLIC
        include
        ${WSLAY_INCLUDE_DIR}
)

target_link_libraries(colyseus-sdk PRIVATE
        CURL::libcurl
        ${WSLAY_LIBRARY}
)

# Link RapidJSON (header-only, so just include)
target_link_libraries(colyseus-sdk PRIVATE rapidjson)