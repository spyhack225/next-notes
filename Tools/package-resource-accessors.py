"""Mitigate SwiftPM's CLI-only Bundle.module lookup when packaging a signed macOS app.

Compile only generated resource accessors with a standard Resources lookup and
relink using SwiftPM's exact object list. SDK sources, objects and interfaces stay
untouched. Fail closed if SwiftPM's template, ABI or manifest format changes.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def module_symbols(path):
    text = subprocess.check_output(['nm', '-gU', str(path)], text=True)
    return {line.split()[-1] for line in text.splitlines()
            if line.split() and '6module' in line.split()[-1]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('scratch', type=Path)
    parser.add_argument('configuration')
    parser.add_argument('--product', default='NextNotes')
    args = parser.parse_args()
    scratch = args.scratch.expanduser().resolve()
    product_dir = (scratch / args.configuration).resolve()
    description = json.loads((product_dir / 'description.json').read_text())
    binary = product_dir / args.product
    links = []
    for line in (scratch / (args.configuration + '.yaml')).read_text().splitlines():
        if line.startswith('    args: ['):
            command = json.loads(line.split('args: ', 1)[1])
            if '-emit-executable' in command and '-o' in command and command[command.index('-o')+1] == str(binary):
                links.append(command)
    assert len(links) == 1, 'Expected exactly one SwiftPM product linker command'
    link = links[0]
    lists = [Path(a[1:]) for a in link if a.startswith('@') and a.endswith('/Objects.LinkFileList')]
    assert len(lists) == 1, 'Expected one native object list'
    original_list = lists[0].read_text().splitlines()
    objects = [shlex.split(line)[0] for line in original_list if line.strip()]
    work = scratch / 'portable-resources' / args.configuration / args.product
    work.mkdir(parents=True, exist_ok=True)
    replacements = {}
    receipts = []
    remove = {'-whole-module-optimization', '-no-whole-module-optimization',
              '-enable-batch-mode', '-parseable-output', '-serialize-diagnostics',
              '-emit-objc-header'}
    remove_pairs = {'-num-threads', '-driver-batch-count', '-emit-objc-header-path'}
    pattern = 'Bundle.main.bundleURL.appendingPathComponent('
    for command in description['swiftCommands'].values():
        sources = [Path(p) for p in command['sources'] if p.endswith('/resource_bundle_accessor.swift')]
        original_objects = [Path(p) for p in command['objects'] if p in objects and p.endswith('/resource_bundle_accessor.swift.o')]
        if not original_objects:
            # WMO combines all SDK code into one object: never replace that object.
            if sources and any(p in objects for p in command['objects']):
                raise RuntimeError('Resource SDK requires the maintained non-WMO build flags: ' + command['moduleName'])
            continue
        assert len(sources) == len(original_objects) == 1
        source, original_object = sources[0], original_objects[0]
        original = source.read_text()
        assert original.count(pattern) == 1, 'Unknown SwiftPM resource template: ' + str(source)
        fixed = original.replace(pattern, '(Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent(')
        folder = work / command['moduleName']
        folder.mkdir(exist_ok=True)
        corrected = folder / 'resource_bundle_accessor.swift'
        corrected.write_text(fixed)
        output = folder / 'resource_bundle_accessor.swift.o'
        flags = []
        skip = False
        for flag in command['otherArguments']:
            if skip:
                skip = False
            elif flag in remove_pairs:
                skip = True
            elif flag not in remove and not flag.startswith('-j'):
                flags.append(flag)
        compile_command = [command['executable'], '-module-name', command['moduleName'],
                           '-I', command['importPath'], '-c', str(corrected), '-o', str(output), *flags]
        with (folder / 'compile.log').open('w') as log:
            subprocess.run(compile_command, check=True, stdout=log, stderr=log)
        original_symbols, fixed_symbols = module_symbols(original_object), module_symbols(output)
        assert original_symbols and original_symbols == fixed_symbols, 'Resource accessor ABI changed'
        assert source.read_text() == original, 'Generated SDK source was unexpectedly changed'
        replacements[str(original_object)] = str(output)
        receipts.append(dict(module=command['moduleName'], original_source_sha256=digest(source),
                             fixed_source_sha256=digest(corrected), original_object_sha256=digest(original_object),
                             fixed_object_sha256=digest(output), module_symbols=sorted(fixed_symbols)))
    assert replacements, 'No supported resource accessors found in this product'
    overridden_list = work / 'Objects.LinkFileList'
    overridden_list.write_text('\n'.join(json.dumps(replacements.get(p, p)) for p in objects) + '\n')
    output = binary.with_suffix('.portable.partial')
    relink = [('@' + str(overridden_list)) if a == '@' + str(lists[0]) else a for a in link]
    relink[relink.index('-o')+1] = str(output)
    with (work / 'link.log').open('w') as log:
        subprocess.run(relink, check=True, stdout=log, stderr=log)
    result = dict(product=args.product, original_binary_sha256=digest(binary),
                  portable_binary_sha256=digest(output), accessors=receipts,
                  original_sdk_objects_unchanged=all(digest(Path(p)) == r['original_object_sha256']
                    for p, r in zip(replacements, receipts)))
    assert result['original_sdk_objects_unchanged']
    output.replace(binary)
    (work / 'receipt.json').write_text(json.dumps(result, indent=2)+'\n')
    print('PORTABLE_RESOURCE_ACCESSORS_OK: ' + str(len(receipts)), flush=True)


if __name__ == '__main__':
    main()
