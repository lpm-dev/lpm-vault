import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class CooperativeRunnerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="cooperative runner ")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.root = Path(cls.directory.name)
        cls.runner = cls.root / "runner"
        cls.helper = cls.root / "fake helper"
        helper_source = cls.root / "helper.c"
        helper_source.write_text(r'''
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    FILE *record = fopen(getenv("RUNNER_CAPTURE"), "w");
    if (record == NULL) return 1;
    const char *names[] = {
        "LIBDISPATCH_COOPERATIVE_POOL_STRICT",
        "DYLD_LIBRARY_PATH",
        "DYLD_FRAMEWORK_PATH"
    };
    for (size_t index = 0; index < sizeof(names) / sizeof(names[0]); ++index) {
        const char *value = getenv(names[index]);
        fprintf(record, "%s\n", value == NULL ? "<absent>" : value);
    }
    for (int index = 0; index < argc; ++index) fprintf(record, "%s\n", argv[index]);
    fclose(record);
    return atoi(getenv("RUNNER_EXIT"));
}
''')
        for source, output in [
            (Path(__file__).with_name("cooperative-test-runner.c"), cls.runner),
            (helper_source, cls.helper),
        ]:
            subprocess.run(
                ["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
                 str(source), "-o", str(output)],
                check=True, capture_output=True, text=True,
            )

    def launch(self, *arguments, exit_code=0):
        capture = self.root / "capture.txt"
        environment = {
            **os.environ,
            "LIBDISPATCH_COOPERATIVE_POOL_STRICT": "0",
            "DYLD_LIBRARY_PATH": "/fixture libraries",
            "DYLD_FRAMEWORK_PATH": "/fixture frameworks",
            "RUNNER_CAPTURE": str(capture),
            "RUNNER_EXIT": str(exit_code),
        }
        result = subprocess.run(
            [str(self.runner), *map(str, arguments)],
            env=environment, capture_output=True, text=True,
        )
        return result, capture

    def test_child_environment_and_arguments(self):
        result, capture = self.launch(
            self.helper, "bundle with spaces", "--filter", "first|second",
            "--testing-library", "swift-testing",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(capture.read_text().splitlines(), [
            "1", "/fixture libraries", "/fixture frameworks", str(self.helper),
            "--test-bundle-path", "bundle with spaces", "--filter", "first|second",
            "--testing-library", "swift-testing", "bundle with spaces",
        ])

    def test_child_failure_is_preserved(self):
        result, _ = self.launch(self.helper, "bundle", exit_code=73)
        self.assertEqual(result.returncode, 73)

    def test_missing_arguments_fail(self):
        result, _ = self.launch()
        self.assertEqual(result.returncode, 2)
        self.assertIn("Expected", result.stderr)

    def test_helper_launch_failure_is_reported(self):
        result, _ = self.launch(self.root / "missing helper", "bundle")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Launch Swift Testing", result.stderr)


if __name__ == "__main__":
    unittest.main()
