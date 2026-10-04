"""Behavioral tests of the dependency gate, independent of repository wording."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('architecture', Path(__file__).resolve().parents[1] / 'scripts/check_architecture.py')
architecture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(architecture)


class ArchitectureBoundaries(unittest.TestCase):
    def test_new_import_rejected_even_in_an_existing_legacy_module(self):
        source = {'src/services/legacy.zig': 'const dvui = @import("dvui");\nconst settings = @import("../ui/settings.zig");'}
        errors = architecture.violations(source, {'src/services/legacy.zig -> dvui'})
        self.assertEqual(errors, ['new presentation dependency: src/services/legacy.zig -> ../ui/settings.zig'])

    def test_documentation_and_comments_do_not_enforce_or_violate_boundaries(self):
        source = {'src/services/store.zig': '// @import("dvui")\nconst rules = @import("rules.zig");'}
        self.assertEqual(architecture.violations(source, set()), [])

    def test_import_after_test_declaration_is_still_rejected(self):
        sources = {"src/services/feature.zig": 'test "first" {}\npub fn render() void { _ = @import("dvui"); }'}
        self.assertEqual(len(architecture.violations(sources, set())), 1)

    def test_nested_modules_are_checked(self):
        import tempfile
        import json
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src/services/nested").mkdir(parents=True)
            (root / "docs").mkdir()
            (root / "docs/architecture-exceptions.json").write_text(json.dumps({"presentation_imports": []}))
            (root / "src/services/nested/store.zig").write_text('const ui = @import("../../ui/settings.zig");')
            self.assertEqual(len(architecture.check(root)), 1)

    def test_removed_dependency_requires_removing_its_exception(self):
        self.assertEqual(len(architecture.violations({}, {'src/services/legacy.zig -> dvui'})), 1)


if __name__ == '__main__':
    unittest.main()
