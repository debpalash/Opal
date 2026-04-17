#!/usr/bin/env python3
"""
ZigZag Test Dashboard Server
Serves the test dashboard and runs the test suite on demand.
Usage: python3 tests/server.py [--port 9090]
"""

import http.server
import json
import subprocess
import os
import sys

PORT = 9090
TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(TESTS_DIR)
DASHBOARD_FILE = os.path.join(TESTS_DIR, "dashboard.html")
RESULTS_FILE = os.path.join(TESTS_DIR, "results.json")
TEST_SCRIPT = os.path.join(TESTS_DIR, "test_features.py")

class TestDashboardHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Quiet logging
        pass

    def do_GET(self):
        if self.path == '/' or self.path == '/index.html':
            self.serve_file(DASHBOARD_FILE, 'text/html')
        elif self.path == '/results':
            self.serve_file(RESULTS_FILE, 'application/json')
        elif self.path == '/run':
            self.run_tests(os.path.join(TESTS_DIR, "test_features.py"), "Feature")
        elif self.path == '/run-realtime':
            self.run_tests(os.path.join(TESTS_DIR, "test_realtime.py"), "Realtime")
        elif self.path == '/run-all':
            self.run_combined()
        else:
            self.send_error(404)

    def serve_file(self, path, content_type):
        if not os.path.exists(path):
            self.send_error(404, f"File not found: {os.path.basename(path)}")
            return
        with open(path, 'rb') as f:
            data = f.read()
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', len(data))
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(data)

    def run_tests(self, script_path, label="Tests"):
        print(f"  ▶ Running {label} suite...")
        try:
            result = subprocess.run(
                [sys.executable, script_path],
                cwd=PROJECT_DIR,
                capture_output=True,
                text=True,
                timeout=180
            )
            if result.stdout:
                print(result.stdout)
            if result.stderr:
                print(result.stderr, file=sys.stderr)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                "status": "ok" if result.returncode == 0 else "fail",
                "returncode": result.returncode
            }).encode())
        except subprocess.TimeoutExpired:
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"status": "timeout"}).encode())
        except Exception as e:
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"status": "error", "detail": str(e)}).encode())

    def run_combined(self):
        """Run both feature + realtime suites, merge results"""
        import time as _t
        print(f"  ▶ Running ALL suites...")
        all_tests = []
        all_categories = {}

        for script, label in [
            (os.path.join(TESTS_DIR, "test_features.py"), "Feature"),
            (os.path.join(TESTS_DIR, "test_realtime.py"), "Realtime")
        ]:
            try:
                subprocess.run([sys.executable, script], cwd=PROJECT_DIR,
                    capture_output=True, text=True, timeout=180)
                with open(RESULTS_FILE) as f:
                    data = json.load(f)
                    all_tests.extend(data.get("tests", []))
                    for cat, counts in data.get("categories", {}).items():
                        if cat not in all_categories:
                            all_categories[cat] = {"pass": 0, "fail": 0, "warn": 0, "skip": 0}
                        for k in ["pass", "fail", "warn", "skip"]:
                            all_categories[cat][k] += counts.get(k, 0)
            except:
                pass

        merged = {
            "timestamp": _t.strftime("%Y-%m-%dT%H:%M:%S"),
            "total": len(all_tests),
            "passed": sum(1 for t in all_tests if t["status"] == "pass"),
            "failed": sum(1 for t in all_tests if t["status"] == "fail"),
            "warnings": sum(1 for t in all_tests if t["status"] == "warn"),
            "skipped": sum(1 for t in all_tests if t["status"] == "skip"),
            "categories": all_categories,
            "tests": all_tests
        }

        with open(RESULTS_FILE, "w") as f:
            json.dump(merged, f, indent=2)

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({"status": "ok"}).encode())

def main():
    port = PORT
    if '--port' in sys.argv:
        idx = sys.argv.index('--port')
        port = int(sys.argv[idx + 1])

    server = http.server.HTTPServer(('0.0.0.0', port), TestDashboardHandler)
    print(f"""
╔══════════════════════════════════════════════════╗
║  ⚡ ZigZag Test Dashboard                        ║
║  http://localhost:{port}                           ║
║  Press Ctrl+C to stop                            ║
╚══════════════════════════════════════════════════╝
""")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n  Stopped.")
        server.server_close()

if __name__ == '__main__':
    main()
