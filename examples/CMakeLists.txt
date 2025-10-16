# Simple example
add_executable(simple_example simple_example.c)
target_link_libraries(simple_example PRIVATE colyseus::sdk)

# Set output directory
set_target_properties(simple_example PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)