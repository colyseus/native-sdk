# GameMaker porting notes

GML and GameMaker behaviours that cost debugging time while porting a
multiplayer client to this extension. None of them are SDK bugs, and several
fail silently. Verified on runtime 2024.14.3.260 (macOS VM runner and HTML5)
unless noted; the air-hockey demo's GameMaker client
(`demos/air-hockey/clients/gamemaker`) hits every one of them and records
how each is handled, including a `--probe` lane that settles the runtime's
capabilities on both runners before anything depends on them.

## Silent failures

**`self` inside a struct literal is the literal, not the enclosing struct.**
A callback context written as `{ v: self }` captures the wrong object, and
anything it writes back goes nowhere. Bind first:

```gml
var _me = self;
tween_start({ ctx: { v: _me, from: vis } });
```

**Function literals do not capture `var` locals.** Code ported from GDScript
or TypeScript that relies on closures compiles and quietly does nothing.
Every callback API in this wrapper therefore takes an explicit context:
`method(ctx_struct, fn)` binds `self` to the struct, and that is where the
state has to live.

**`display_reset()` is unsupported on HTML5 and fails as a console error, not
an exception.** A `try`/`catch` around it reports success. Feature-detect by
target (`os_browser == browser_not_a_browser`) instead.

**`audio_emitter_*` is unavailable on HTML5** (`Emitter with index 0 does not
exist!`). Positional audio needs the pan baked into stereo buffers if the web
export matters.

**`room` and `speed` are built-in instance variables.** Assigning a room
handle to `room` throws `Unexisting room number: N`, and a struct method named
`speed` is a compile error. Prefix your own names.

## Language and toolchain limits

- No scientific-notation literals: `1e-12` is a syntax error.
- No `draw_arc`, and no arc or annulus primitive of any kind. Rings need a
  hand-rolled triangle strip.
- Gradient draw calls (`draw_circle_colour`, `draw_roundrect_colour_ext`) vary
  colour from centre to edge but not alpha. Soft glows need a per-vertex-alpha
  fan.
- `screen_save()` is sandboxed to the save area, and the VM runner's save area
  is its own bundle id (`com.yoyogames.macyoyorunner`), not the game's. Print
  `game_save_id` and lift the file out from there.
- Igor does not rasterise TTFs. `GMAssetCompiler` reads glyph metrics from a
  font `.yy` and loads a pre-rendered atlas; the FreeType binding ships only
  inside the IDE. A hand-authored font `.yy` yields no glyphs. Generate a
  sprite font and use `font_add_sprite_ext`, which (unlike `font_add`) also
  works on HTML5.

## Igor (the command-line build)

- The HTML5 folder command is lowercase: `-- HTML5 folder`. Only `--tf` names
  the destination.
- `-- Mac Run` does not forward arguments to the game. Use environment
  variables on desktop (`environment_get_variable`). In a browser, URL query
  parameters surface through `parameter_string()`.
- Igor caches the extension binary. After rebuilding `libcolyseus.dylib`,
  delete the cache and temp directories you passed with `--cache` / `--temp`
  or the old binary keeps running.

## HTML5 specifics

- The WASM module instantiates after the game has entered its main loop.
  Gate client creation on `colyseus_is_ready()` (see
  [HTML5_SETUP.md](HTML5_SETUP.md)).
- The emitter writes a syntactically invalid stub (`function name{}`) for any
  function nothing references, and one such stub breaks the whole page. Keep
  every exported function reachable; a self-check function that references
  each helper is the usual fix.
- Bitwise operators lower to JavaScript int32, not int64, and `div` lowers to
  a rounded division rather than truncation. Integer literals above 2^31 emit
  as `new Long(...)`, and dividing by a `Long` is an integer division, so
  `x / 4294967296` is 0 for any `x` below 2^32. `power(2, 32)` constant-folds
  back into the same `Long`. A chain of power-of-two divisions
  (`(x / 65536) / 65536`) is exact on both runners.
- The toolchain can parse a long decimal literal to a neighbouring double, so
  a cross-runtime numeric assertion needs a small relative tolerance rather
  than exact equality. Comparing raw integers sidesteps it entirely.
- Inside struct methods, field access on `self` is unreliable: fields named
  `x` and `y` alias the calling instance's built-ins, and non-static
  constructor methods fail the build at the obfuscation step
  ("Unknown identifier in compile_if_weak_ref"). State in globals plus plain
  global functions is the shape that ports cleanly; a struct can keep thin
  static shims that only pass arguments through.
- GML exceptions surface as page errors on an `_lT` object with `message` and
  `stacktrace` fields, and they halt the game loop. A headless probe should
  hook `window` `error` events and require a positive boot signal: silence is
  not success on a page that never booted.
