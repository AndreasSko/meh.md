import json
import os
import plistlib
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import uuid

sys.path.insert(0, str(Path.cwd() / 'scripts'))
import run_ui_test_coverage as runner

signal.signal(signal.SIGTERM, lambda signum, frame: (_ for _ in ()).throw(KeyboardInterrupt()))
evidence = Path(os.environ['RUNNER_TEMP']) / 'ordered-fixture-probe'
evidence.mkdir(exist_ok=True)
owned = []
phases = []
with tempfile.TemporaryDirectory(prefix='meh-ci-ordered-probe-') as temporary:
    work = Path(temporary)
    products = work / 'build/Build/Products'
    try:
        phone = runner.create_simulator('iphone', owned)
        pad = runner.create_simulator('ipad', owned)
        with runner.loopback_fixture(work / 'server', evidence / 'loopback.log') as endpoint:
            runner.logged(['xcodebuild', 'build-for-testing', '-project', 'meh.md.xcodeproj',
                           '-scheme', 'meh.md iCloud Dev', '-destination',
                           f'platform=iOS Simulator,id={phone}', '-derivedDataPath',
                           work / 'build', 'CODE_SIGNING_ALLOWED=NO'], evidence / 'build.log', timeout=1800)
            plans = list(products.glob('*.xctestrun'))
            assert len(plans) == 1, plans
            original = plistlib.loads(plans[0].read_bytes())
            environment = {'MEH_CI_SYNC_PORT': endpoint.rsplit(':', 1)[1],
                           'MEH_SYNC_TEST_WORKSPACE': 'ci-' + uuid.uuid4().hex}
            for name, device, method in (
                ('phone-publish', phone, 'test01PublishFromPhone'),
                ('pad-reply', pad, 'test02ReceiveAndReplyFromPad'),
                ('phone-reopen', phone, 'test03ReceiveReplyOnPhoneAndRestart'),
            ):
                identifier = f'meh.mdUITests/LocalSyncUITests/{method}'
                plan = runner.selected_plan(original, [identifier], environment)
                run = products / f'ci-{name}.xctestrun'
                run.write_bytes(plistlib.dumps(plan))
                bundle = evidence / f'{name}.xcresult'
                phases.append((name, bundle))
                runner.logged(['xcodebuild', 'test-without-building', '-xctestrun', run,
                               '-destination', f'platform=iOS Simulator,id={device}',
                               '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics',
                               'never', '-resultBundlePath', bundle], evidence / f'{name}.log', timeout=1200)
                run.unlink()
    finally:
        (evidence / 'owned-simulators.json').write_text(json.dumps(owned) + '\n')
        for name, bundle in phases:
            if bundle.exists():
                try:
                    runner.collect(bundle, evidence, name)
                except Exception as error:
                    print(f'{name} evidence export: {error}', flush=True)
        for device in owned:
            subprocess.run(['xcrun', 'simctl', 'shutdown', device], timeout=120, check=False)
            subprocess.run(['xcrun', 'simctl', 'delete', device], timeout=120, check=True)
print('Focused ordered fixture validation completed; this is not complete CI matrix proof', flush=True)
