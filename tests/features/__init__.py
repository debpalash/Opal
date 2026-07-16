# Opal feature test suite — chunked into per-category modules.
#
# `test_features.py` (repo entry point) is a thin shim that imports every
# module in this package so their @test decorators register, then calls
# harness.run_all().  The shared decorator/helpers/registry live in harness.py.
