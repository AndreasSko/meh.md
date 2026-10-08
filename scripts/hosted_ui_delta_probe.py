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
from ci_process import cancellation_handler
from check_ci_test_coverage import xcresult_cases
signal.signal(signal.SIGTERM, cancellation_handler)

BASELINE = '73cf9087026abd36778b3ad83b53be451c916349'
PLATFORM = os.environ['PROBE_PLATFORM']
CASES = [
    'meh.mdUITests/NotebookLinksUITests/testWikiNavigationBacklinksAndCompletion',
    'meh.mdUITests/RecentsExpansionUITests/testTapExpansionScrollPinAndRestoreFiles',
    'meh.mdUITests/NotebookTrashUITests/testTrashMenuHitAreaAndBatchActions',
    'meh.mdUITests/NotebookCreationUITests/testPointerGapPlacesFoldersBeforeAndAfterNote',
]
evidence = Path(os.environ['RUNNER_TEMP']) / ('delta-probe-' + PLATFORM)
evidence.mkdir(exist_ok=True)
(evidence / 'baseline.json').write_text(json.dumps({'baseline': BASELINE, 'cases': CASES,
    'description': 'Reviewed candidate source; focused evidence only, one fresh simulator per method'}, indent=2))
for name, command in [('os', ['sw_vers']), ('xcode', ['xcodebuild', '-version']),
                      ('simulators', ['xcrun', 'simctl', 'list', '--json'])]:
    (evidence / (name + '.txt')).write_text(subprocess.check_output(command, text=True))
outcomes = []
with tempfile.TemporaryDirectory(prefix='meh-ci-baseline-isolation-') as temporary:
    work = Path(temporary)
    products = work / 'build/Build/Products'
    for index, identifier in enumerate(CASES):
        owned = []
        case = evidence / str(index + 1)
        case.mkdir()
        bundle = case / 'test.xcresult'
        try:
            device = None if PLATFORM == 'macos' else runner.create_simulator('ipad', owned)
            destination = 'platform=macOS' if device is None else f'platform=iOS Simulator,id={device}'
            (case / 'device.json').write_text(json.dumps({'udid': device, 'identifier': identifier}))
            if index == 0:
                runner.logged(['xcodebuild', 'build-for-testing', '-project', 'meh.md.xcodeproj',
                               '-scheme', 'meh.md iCloud Dev', '-destination', destination,
                               '-derivedDataPath', work / 'build', 'CODE_SIGNING_ALLOWED=NO'],
                              evidence / 'build.log', timeout=2400)
            plans = list(products.glob('*.xctestrun'))
            assert len(plans) == 1, plans
            original = plistlib.loads(plans[0].read_bytes())
            if PLATFORM == 'macos':
                runner.sign_macos_runner(products, original, evidence, '-')
                runner.require_available_macos_ui(products)
            with runner.loopback_fixture(work / str(index), case / 'loopback.log') as endpoint:
                environment = {'MEH_CI_SYNC_PORT': endpoint.rsplit(':', 1)[1],
                               'MEH_SYNC_TEST_WORKSPACE': 'isolation-' + uuid.uuid4().hex}
                run = products / 'ci-isolation.xctestrun'
                run.write_bytes(plistlib.dumps(runner.selected_plan(original, [identifier], environment)))
                try:
                    runner.logged(['xcodebuild', 'test-without-building', '-xctestrun', run,
                                   '-destination', destination, '-parallel-testing-enabled', 'NO',
                                   '-collect-test-diagnostics', 'never', '-resultBundlePath', bundle],
                                  case / 'test.log', timeout=1200)
                    outcomes.append({'id': identifier, 'result': 'xcodebuild_succeeded'})
                finally:
                    run.unlink()
        except Exception as error:
            outcomes.append({'id': identifier, 'result': 'failed', 'error': str(error)})
        finally:
            if PLATFORM == 'macos':
                runner.stop_owned_macos_apps(products)
            for udid in owned:
                try:
                    runner.logged(['xcrun', 'simctl', 'spawn', udid, 'log', 'show',
                                   '--style', 'json', '--last', '2h', '--predicate',
                                   'eventMessage BEGINSWITH "[MEHNativeInput]"'],
                                  case / 'native-input.log', timeout=60)
                except Exception as error:
                    (case / 'input-log-error.txt').write_text(str(error))
                subprocess.run(['xcrun', 'simctl', 'shutdown', udid], timeout=120, check=False)
                subprocess.run(['xcrun', 'simctl', 'delete', udid], timeout=120, check=True)
            if bundle.exists():
                try:
                    runner.collect(bundle, case, 'test')
                except Exception as error:
                    (case / 'collection-error.txt').write_text(str(error))
            (evidence / 'outcomes.json').write_text(json.dumps(outcomes, indent=2))
print(json.dumps(outcomes, indent=2))
print('Focused evidence only; not complete CI coverage proof')
formal_failures = []
for index, identifier in enumerate(CASES):
    summary_path = evidence / str(index + 1) / 'test-summary.json'
    if not summary_path.exists():
        formal_failures.append(identifier)
        continue
    summary = json.loads(summary_path.read_text())
    try:
        tests = json.loads((summary_path.parent / 'test-tests.json').read_text())
        if xcresult_cases(summary, tests, 'meh.mdUITests') != [identifier]:
            formal_failures.append(identifier)
    except Exception:
        formal_failures.append(identifier)
    if (summary.get('passedTests') != 1 or summary.get('failedTests') != 0
            or summary.get('skippedTests') != 0):
        formal_failures.append(identifier)
if formal_failures:
    raise SystemExit('Focused XCTest failures or missing results: ' + str(formal_failures))
