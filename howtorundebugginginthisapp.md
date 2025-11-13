  Window 1 (tail the debug output):
  tail -f /tmp/debug_output.log

  Window 2 (run the app, stderr to file):
  DEBUG_TOOLS=1 ./zig-out/bin/localharness 2> /tmp/debug_output.log
