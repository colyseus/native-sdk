cmake_minimum_required(VERSION 3.14)

# Bundle the pre-built DLL
set(colyseus_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/Libraries/colyseus_flutter.dll"
  PARENT_SCOPE
)
