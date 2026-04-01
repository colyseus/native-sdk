# Colyseus Native SDK Test Suite

This directory contains the **Zig test suite** for the Colyseus native SDK.

All tests are written in Zig, taking advantage of Zig's built-in testing framework for fast, type-safe, and maintainable tests.

## Running Tests

### Full suite (`zig build test`)

Integration tests need **example-server** on `http://localhost:2567` (same as CI). Terminal A:

```bash
cd example-server
npm install
npx tsx src/index.ts
# or: npm start   (tsx watch)
```

Terminal B, from the **repository root**:

```bash
zig build test
```

### Without a server (unit tests only)

```bash
zig build test -Dskip-integration=true
```

### Run Individual Tests

```bash
zig build test_http         # HTTP functionality tests
zig build test_auth         # Authentication tests
zig build test_room         # Room functionality tests
zig build test_storage      # Secure storage tests
zig build test_suite        # Core unit test suite
zig build test_integration  # Full integration test (requires server)
```

## Test Structure

All tests are written in **idiomatic Zig** using the built-in test framework:

### Test Files

- **`test_suite.zig`** - Core unit tests (14 tests)
  - Room creation and management
  - Secure storage operations
  - Authentication and tokens
  - Client creation
  - Settings configuration

- **`test_http.zig`** - HTTP functionality (1 test)
  - Request handling
  - Error callbacks
  - Async operations

- **`test_auth.zig`** - Authentication (1 test)
  - Token management
  - Auth callbacks
  - Persistence

- **`test_room.zig`** - Room operations (1 test)
  - Room creation
  - Message handlers
  - State management

- **`test_storage.zig`** - Secure storage (5 tests)
  - Set and get
  - Update operations
  - Key removal
  - Error handling

- **`test_integration.zig`** - Integration test (1 test)
  - Full connection flow
  - Room join/leave
  - Message sending
  - Requires running server

### Test Features

- ✅ **Type-safe**: Leverages Zig's compile-time safety
- ✅ **Fast**: Most tests run in milliseconds
- ✅ **Maintainable**: Clean, readable Zig code
- ✅ **Comprehensive**: 22 tests covering all major functionality
- ✅ **Integrated**: Native Zig build system integration

## Requirements

### Most Tests
- No external dependencies
- No running server needed
- Run in milliseconds

### Integration tests

`zig build test` runs `test_integration`, `test_schema_callbacks`, and `test_messages` against **example-server** (`localhost:2567`, room `my_room`). Start the server as in **Full suite** above.

Single integration binary:

```bash
zig build test_integration
```

## Adding New Tests

### Add to Existing Test Files

Edit any test file (e.g., `tests/test_suite.zig`) and add new test blocks:

```zig
test "my new test" {
    const testing = std.testing;
    
    // Your test code here
    try testing.expect(true);
}
```

### Create New Test Files

1. Create a new `.zig` file in `tests/` (e.g., `test_myfeature.zig`)
2. Add it to `build.zig` in the `zig_test_files` array:

```zig
.{ .name = "test_myfeature", .file = "tests/test_myfeature.zig", .description = "Run my feature tests" },
```

3. Implement your tests using Zig's test framework

## Test Output

Example success output:

```
Build Summary: … steps succeeded; … tests passed
test success
```

Individual test output includes detailed information:

```
=== Test: HTTP ===

Test: Request to offline service
HTTP Error: 0 - Couldn't connect to server
PASS: Error handler called for offline service

All HTTP tests passed!
```

## Continuous Integration

CI starts **example-server**, waits until `localhost:2567` responds, then runs `zig build test`.

