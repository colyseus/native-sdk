cmake_minimum_required(VERSION 3.10)

# Bundle the pre-built shared library
set(colyseus_flutter_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/Libraries/libcolyseus_flutter.so"
  PARENT_SCOPE
)
