"""Real SwiftPM library/app consumer, original and fixed, without cache resources."""
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

report = Path(__file__).resolve().parent
repo = report.parents[2]
with tempfile.TemporaryDirectory(prefix='nextnotes-portable-resource-check-') as temporary:
    root = Path(temporary)
    library = root / 'Sources/ResourceLibrary'
    executable = root / 'Sources/Probe'
    library.mkdir(parents=True)
    executable.mkdir(parents=True)
    (root/'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ResourceFixture", targets: [
 .target(name: "ResourceLibrary", resources: [.copy("probe.txt")]),
 .executableTarget(name: "Probe", dependencies: ["ResourceLibrary"])])
''')
    (library/'lookup.swift').write_text('''import Foundation
@inline(never) public func resourceText() -> String {
 let url = Bundle.module.url(forResource: "probe", withExtension: "txt")!
 return try! String(contentsOf: url, encoding: .utf8)
}
''')
    (library/'probe.txt').write_text('PORTABLE_RESOURCE_FIXTURE_OK')
    (executable/'main.swift').write_text('import ResourceLibrary\nprint(resourceText())\n')
    cache = root/'cache'
    command = ['swift','build','-c','release','--build-system','native','--jobs','2',
               '--scratch-path',str(cache),'-Xswiftc','-no-whole-module-optimization',
               '-Xswiftc','-enable-batch-mode','-Xswiftc','-driver-batch-count','-Xswiftc','16']
    with (report/'resource-fixture-build.log').open('w') as log:
        subprocess.run(command, cwd=root, check=True, stdout=log, stderr=log)
    product = (cache/'release').resolve()
    bundles = list(product.glob('*.bundle'))
    assert len(bundles) == 1
    app = root/'ResourceFixture.app'
    (app/'Contents/MacOS').mkdir(parents=True)
    (app/'Contents/Resources').mkdir()
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier='ai.pivotstudio.nextnotes.resource-fixture',
        CFBundleExecutable='Probe', CFBundlePackageType='APPL')))
    shutil.copytree(bundles[0], app/'Contents/Resources'/bundles[0].name)
    hidden = root/'hidden.bundle'
    bundles[0].rename(hidden)
    results = []
    for mode in ['original','fixed']:
        if mode == 'fixed':
            with (report/'resource-fixture-relink.log').open('w') as log:
                subprocess.run(['python3',str(repo/'Tools/package-resource-accessors.py'),
                                str(cache),'release','--product','Probe'],check=True,stdout=log,stderr=log)
        binary = app/'Contents/MacOS/Probe'
        shutil.copyfile(product/'Probe',binary)
        binary.chmod(0o755)
        subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
        subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True,capture_output=True)
        run = subprocess.run([str(binary)],capture_output=True,text=True,timeout=15)
        (report/('resource-fixture-'+mode+'.log')).write_text(run.stdout+run.stderr)
        result = dict(mode=mode,exit=run.returncode,signature_valid=True,
                      sdk_resource_absent=not bundles[0].exists(),
                      packaged_resource_exists=(app/'Contents/Resources'/bundles[0].name/'probe.txt').is_file(),
                      binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                      expected_output='PORTABLE_RESOURCE_FIXTURE_OK' in run.stdout)
        results.append(result)
    assert results[0]['exit'] != 0 and not results[0]['expected_output']
    assert results[1]['exit'] == 0 and results[1]['expected_output']
    assert all(x['sdk_resource_absent'] and x['signature_valid'] and x['packaged_resource_exists'] for x in results)
(report/'resource-fixture-results.json').write_text(json.dumps(results,indent=2)+'\n')
print('PORTABLE_RESOURCES_ORIGINAL_FAILED_FIXED_OK')
