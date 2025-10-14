# CMakeLists.txt
cmake_minimum_required(VERSION 3.15)
project(colyseus-native-sdk VERSION 0.1.0)

set(CMAKE_CXX_STANDARD 17)

option(WITH_HTTP_CURL "Use libcurl for HTTP" ON)
option(WITH_WS_WSLAY "Use wslay for WebSocket" ON)

# Dependencies
find_package(CURL REQUIRED)
find_package(RapidJSON CONFIG REQUIRED)

add_library(colyseus-sdk SHARED
        src/settings.cpp
        src/client.cpp
        src/network/http.cpp
)

target_include_directories(colyseus-sdk PUBLIC include)
target_link_libraries(colyseus-sdk PRIVATE CURL::libcurl)