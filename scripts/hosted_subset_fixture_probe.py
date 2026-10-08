import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import uuid

sys.path.insert(0, str(Path.cwd() / 'scripts'))
import run_ui_test_coverage as runner
import check_ci_test_coverage as checker

parser = argparse.ArgumentParser()
parser.add_argument('--platform', choices=('ipad', 'macos'), required=True)
parser.add_argument('--identifiers', type=Path, required=True)
args = parser.parse_args()
identifiers = json.loads(args.identifiers.read_text())
assert identifiers and len(identifiers) == len(set(identifiers))
signal.signal(signal.SIGTERM, lambda signum, frame: (_ for _ in ()).throw(KeyboardInterrupt()))
evidence = Path(os.environ['RUNNER_TEMP']) / ('focused-fixture-' + args.platform)
evidence.mkdir(exist_ok=True)
(evidence / 'selected-identifiers.json').write_text(json.dumps(identifiers, indent=2) + '\n')
owned = []
bundle = evidence / 'focused.xcresult'
with tempfile.TemporaryDirectory(prefix='meh-ci-focused-probe-') as temporary:
    work = Path(temporary)
    products = work / 'build/Build/Products'
    try:
        device = None if args.platform == 'macos' else runner.create_simulator(args.platform, owned)
        destination = 'platform=macOS' if device is None else f'platform=iOS Simulator,id={device}'
        with runner.loopback_fixture(work / 'server', evidence / 'loopback.log') as endpoint:
            runner.logged(['xcodebuild', 'build-for-testing', '-project', 'meh.md.xcodeproj',
                           '-scheme', 'meh.md iCloud Dev', '-destination', destination,
                           '-derivedDataPath', work / 'build', 'CODE_SIGNING_ALLOWED=NO'],
                          evidence / 'build.log', timeout=2400)
            plans = list(products.glob('*.xctestrun'))
            assert len(plans) == 1, plans
            original = plistlib.loads(plans[0].read_bytes())
            if device is None:
                runner.sign_macos_runner(products, original, evidence, '-')
            environment = {'MEH_CI_SYNC_PORT': endpoint.rsplit(':', 1)[1],
                           'MEH_SYNC_TEST_WORKSPACE': 'ci-' + uuid.uuid4().hex}
            run = products / 'ci-focused.xctestrun'
            run.write_bytes(plistlib.dumps(runner.selected_plan(original, identifiers, environment)))
            if device is None:
                runner.require_available_macos_ui(products)
            runner.logged(['xcodebuild', 'test-without-building', '-xctestrun', run,
                           '-destination', destination, '-parallel-testing-enabled', 'NO',
                           '-collect-test-diagnostics', 'never', '-resultBundlePath', bundle],
                          evidence / 'focused.log', timeout=5400)
            run.unlink()
    finally:
        if device is None:
            runner.stop_owned_macos_apps(products)
        (evidence / 'owned-simulators.json').write_text(json.dumps(owned) + '\n')
        for udid in owned:
            subprocess.run(['xcrun', 'simctl', 'shutdown', udid], timeout=120, check=False)
            subprocess.run(['xcrun', 'simctl', 'delete', udid], timeout=120, check=True)
        if bundle.exists():
            runner.collect(bundle, evidence, 'focused')
passed = checker.xcresult_cases(json.loads((evidence / 'focused-summary.json').read_text()),
                              json.loads((evidence / 'focused-tests.json').read_text()), 'meh.mdUITests')
assert set(passed) == set(identifiers), (passed, identifiers)
print(f'Focused fixture validation passed {len(passed)} selected methods; this is not complete CI matrix proof', flush=True)
