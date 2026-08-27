# Example

A whole client in one file: join, read state, react to changes, send, leave.

```sh
# 1. the server
cd ../../../example-server && npm install && npm start

# 2. the native library
cd ../platforms/swift && ./build.sh

# 3. this
cd example && swift run
```

Point it elsewhere with an argument: `swift run ColyseusExample ws://host:port`.
