import tempfile
from pathlib import Path
import unittest

from ci_test_inventory import inventory, _condition


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def source(self, text, path="Tests/ExampleTests/ExampleTests.swift"):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)

    def test_platform_branches_and_multiple_classes(self):
        self.source('''
        final class ExampleTests: XCTestCase {
          #if os(macOS)
          func testMac() {}
          #elseif canImport(UIKit)
          func testMobile() {}
          #endif
          func testShared(
          ) async throws {}
        }
        final class SecondTests: XCTestCase {
          func testSecond() {}
        }
        ''')
        mac = inventory(self.root, "macos")
        phone = inventory(self.root, "iphone")
        self.assertEqual([r["method"] for r in mac],
                         ["testMac", "testShared", "testSecond"])
        self.assertEqual([r["method"] for r in phone],
                         ["testMobile", "testShared", "testSecond"])
        self.assertEqual(mac[-1]["id"],
                         "ExampleTests/SecondTests/testSecond")

    def test_comments_and_literals_do_not_create_tests_or_end_bodies(self):
        self.source('''
        // class Fake: XCTestCase { func testFake() {} }
        final class ExampleTests: XCTestCase {
          func testReal() {
            let text = "} func testFake() {"
            let multiline = """\n{ }\n"""
            /* func testComment() {} */
          }
        }
        ''')
        self.assertEqual([r["method"] for r in inventory(self.root, "macos")],
                         ["testReal"])

    def test_device_skip_classification(self):
        self.source('''
        #if os(iOS)
        final class ExampleTests: XCTestCase {
          func testPad() throws {
            try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad,
                          "Requires iPad")
          }
          func testPhone() throws {
            try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
          }
          func testOrdinary() {}
        }
        #endif
        ''', "meh.mdUITests/ExampleTests.swift")
        phone = {r["method"]: r for r in inventory(self.root, "iphone")}
        pad = {r["method"]: r for r in inventory(self.root, "ipad")}
        self.assertTrue(phone["testPad"]["expected_skip"])
        self.assertFalse(pad["testPad"]["expected_skip"])
        self.assertTrue(pad["testPhone"]["expected_skip"])
        self.assertFalse(phone["testPhone"]["expected_skip"])
        self.assertFalse(phone["testOrdinary"]["expected_skip"])
        self.assertEqual(inventory(self.root, "macos"), [])

    def test_fixture_and_cloud_categories(self):
        for name, category, skip in [
                ("ICloudDevelopmentUITests", "live-icloud", True),
                ("NotebookImportUITests", "import-fixture", False),
                ("LocalSyncUITests", "ordered-loopback", False)]:
            with self.subTest(name=name):
                self.source(f"class {name}: XCTestCase {{ func testRun() {{}} }}",
                            f"meh.mdUITests/{name}.swift")
                record = next(r for r in inventory(self.root, "iphone")
                              if r["class_name"] == name)
                self.assertEqual(record["category"], category)
                self.assertEqual(record["expected_skip"], skip)

    def test_unknown_conditions_fail_closed_even_in_inactive_branch(self):
        self.source('''
        #if os(iOS)
        #if SOME_NEW_FEATURE
        class ExampleTests: XCTestCase { func testRun() {} }
        #endif
        #endif
        ''')
        with self.assertRaisesRegex(ValueError, "Unsupported Swift conditional"):
            inventory(self.root, "macos")

    def test_parameterized_tests_fail_closed(self):
        self.source('''
        class ExampleTests: XCTestCase { func testRun(value: Int) {} }
        ''')
        with self.assertRaisesRegex(ValueError, "Unsupported test declaration"):
            inventory(self.root, "macos")

    def test_duplicate_ids_fail_closed(self):
        self.source('''
        class ExampleTests: XCTestCase {
          func testRun() {}
          func testRun() {}
        }
        ''')
        with self.assertRaisesRegex(ValueError, "Duplicate XCTest IDs"):
            inventory(self.root, "macos")

    def test_test_outside_case_and_unbalanced_directive_fail(self):
        self.source("func testLoose() {}")
        with self.assertRaisesRegex(ValueError, "outside one XCTestCase"):
            inventory(self.root, "macos")
        self.source("#endif\n")
        with self.assertRaisesRegex(ValueError, "Unbalanced"):
            inventory(self.root, "macos")

    def test_host_probe_exemption_is_narrow(self):
        self.source("""
        class NativeEditorIntegrationTests: XCTestCase {
          func testFiveReturnsKeepNativeInsertionIndicatorVisible() throws {
            throw XCTSkip("Host has no indicator")
          }
          func testOrdinary() throws { throw XCTSkip("Unexpected skip") }
        }
        """, "Tests/NativeEditorTests/NativeEditorIntegrationTests.swift")
        records = {r["method"]: r for r in inventory(self.root, "macos")}
        host = records["testFiveReturnsKeepNativeInsertionIndicatorVisible"]
        self.assertEqual(host["category"], "app-host")
        self.assertTrue(host["expected_skip"])
        self.assertFalse(records["testOrdinary"]["expected_skip"])

    def test_benchmark_opt_in_and_immutable_skips_remain_required(self):
        self.source("""
        class ExampleTests: XCTestCase {
          func testBenchmark() throws {
            throw XCTSkip("Set MEH_BENCHMARK=1")
          }
          func testImmutable() throws {
            throw XCTSkip("Filesystem does not support immutable files")
          }
        }
        """)
        self.assertFalse(any(r["expected_skip"]
                             for r in inventory(self.root, "macos")))

    def test_compound_conditions(self):
        self.assertTrue(_condition("os(iOS) && !canImport(AppKit)", "ipad"))
        self.assertTrue(_condition("os(iOS) || os(macOS)", "macos"))
        with self.assertRaises(ValueError):
            _condition("unknown", "macos")


if __name__ == "__main__":
    unittest.main()
