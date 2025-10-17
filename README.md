# Work In progress

To build, first checkout the root folder of the native-sdk
```git submodule update --init --recursive
mkdir -p build 
cd build
rm -rf *
cmake ..
cmake --build .
```

For running any script from example

`./lib/{script_name}`
