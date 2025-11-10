# Colyseus Native SDK Test Suite

This directory contains the **Zig test suite** for the Colyseus native SDK.

All tests are written in Zig, taking advantage of Zig's built-in testing framework for fast, type-safe, and maintainable tests.

## Running Tests

### Run All Tests

```bash
zig build test
```

This runs:
- **22 Zig tests** across 6 test suites
- Most tests run without requiring a server
- Integration test requires a running Colyseus server

### Run Tests Without Integration Test

If you don't have a Colyseus server running:

```bash
zig build test -Dskip-integration
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

### Integration Test
To run the full integration test (`test_integration.zig`), you need:

1. A running Colyseus server on `localhost:2567`
2. A room named `my_room` available

Start the example server:
```bash
cd example-server
npm install
npm start
```

Then run:
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

When running `zig build test -Dskip-integration`:

```
Build Summary: 17/17 steps succeeded; 22/22 tests passed
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

For CI/CD pipelines, use:
```bash
zig build test -Dskip-integration
```

This ensures tests run without requiring a live server.

