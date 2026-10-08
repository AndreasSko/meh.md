import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import uuid

sys.path.insert(0, str(Path.cwd() / 'scripts'))
import run_ui_test_coverage as runner

BASELINE = '18c877dda20b305e7443cf152f2caebd18726477'
CASES = ['meh.mdUITests/NotebookLinksUITests/testWikiNavigationBacklinksAndCompletion']
evidence = Path(os.environ['RUNNER_TEMP']) / 'wiki-title-ax-ipad'
evidence.mkdir(exist_ok=True)
diff = subprocess.check_output(['git', 'diff', BASELINE, '--',                                'meh.md', 'Packages', 'scripts/run_ui_test_coverage.py'], text=True)
assert not diff, 'Baseline app, original test bodies, and runner must remain unchanged'
(evidence / 'baseline.json').write_text(json.dumps({'baseline': BASELINE, 'cases': CASES,
    'description': 'Unchanged baseline methods; one fresh simulator and sync workspace per method'}, indent=2))
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
            device = runner.create_simulator('ipad', owned)
            destination = f'platform=iOS Simulator,id={device}'
            (case / 'device.json').write_text(json.dumps({'udid': device, 'identifier': identifier}))
            if index == 0:
                runner.logged(['xcodebuild', 'build-for-testing', '-project', 'meh.md.xcodeproj',
                               '-scheme', 'meh.md iCloud Dev', '-destination', destination,
                               '-derivedDataPath', work / 'build', 'CODE_SIGNING_ALLOWED=NO'],
                              evidence / 'build.log', timeout=2400)
            plans = list(products.glob('*.xctestrun'))
            assert len(plans) == 1, plans
            original = plistlib.loads(plans[0].read_bytes())
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
                    outcomes.append({'id': identifier, 'result': 'passed'})
                finally:
                    run.unlink()
        except Exception as error:
            outcomes.append({'id': identifier, 'result': 'failed', 'error': str(error)})
        finally:
            for udid in owned:
                subprocess.run(['xcrun', 'simctl', 'shutdown', udid], timeout=120, check=False)
                subprocess.run(['xcrun', 'simctl', 'delete', udid], timeout=120, check=True)
            if bundle.exists():
                try:
                    runner.collect(bundle, case, 'test')
                except Exception as error:
                    (case / 'collection-error.txt').write_text(str(error))
            (evidence / 'outcomes.json').write_text(json.dumps(outcomes, indent=2))
print(json.dumps(outcomes, indent=2))
print('Diagnostic baseline comparison only; not complete CI coverage proof')
