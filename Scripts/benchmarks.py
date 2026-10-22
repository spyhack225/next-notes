#!/usr/bin/env python3
"""One benchmark catalog. Standard library only; never executes a benchmark or reads owner stores."""
import argparse
import datetime as dt
import hashlib
import gzip
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
CATEGORIES = ('asr', 'dictation', 'meetings', 'agent', 'voice', 'tts', 'workflows', 'models', 'other')
STATUSES = ('measured', 'partial', 'failed', 'blocked', 'unrun')
EVIDENCE_ROOTS = ('Tests/Reports/', 'bench/', 'docs/', 'roadmap/')
TEXT_TYPES = ('.md', '.json', '.jsonl', '.csv', '.tsv', '.txt', '.log')


def git(*args, cwd=None):
    return subprocess.check_output(['git', '-C', str(cwd or ROOT), *args], text=True, stderr=subprocess.DEVNULL)


def atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text() == text:
        return
    with tempfile.NamedTemporaryFile('w', dir=path.parent, delete=False, encoding='utf-8') as f:
        f.write(text)
        name = f.name
    os.replace(name, path)


def dump(value):
    return json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False) + '\n'


def category(path):
    p = path.lower()
    for needle, cat in [('asr', 'asr'), ('dictation', 'dictation'), ('cleanup', 'dictation'),
                        ('meeting', 'meetings'), ('tts', 'tts'), ('voice', 'voice'),
                        ('acoustic', 'voice'), ('toolloop', 'agent'), ('agent', 'agent'),
                        ('durable', 'workflows'), ('imessage', 'workflows'), ('computer', 'workflows'),
                        ('decision-gate', 'models'), ('model', 'models')]:
        if needle in p:
            return cat
    return 'other'


def evidence_path(path):
    return path.startswith(EVIDENCE_ROOTS) and path.endswith(TEXT_TYPES) and not path.startswith('roadmap/references/') and '/node_modules/' not in path and '/assets/' not in path


def relative_source(value):
    p = Path(value)
    assert not p.is_absolute() and '..' not in p.parts and str(p) != '.', 'source must be repository-relative'
    full = ROOT / p
    assert full.resolve().is_relative_to(ROOT.resolve()), 'source escapes repository'
    assert full.is_file(), f'missing evidence: {value}'
    return full


def validate(run):
    required = {'schema_version', 'id', 'title', 'date', 'category', 'status', 'scope', 'summary',
                'environment', 'provenance', 'metrics', 'limitations', 'sources', 'publication'}
    assert required <= run.keys(), f'missing fields: {required - run.keys()}'
    assert run['schema_version'] == 1
    assert re.fullmatch(r'[a-z0-9][a-z0-9-]{2,100}', run['id'])
    dt.date.fromisoformat(run['date'])
    assert run['category'] in CATEGORIES and run['status'] in STATUSES
    for key in ('title', 'scope', 'summary'):
        assert isinstance(run[key], str) and run[key].strip(), key
    assert isinstance(run['environment'], dict) and isinstance(run['provenance'], dict)
    assert all(isinstance(k, str) and isinstance(v, str) for k, v in run['environment'].items()), 'environment values must be display text'
    assert isinstance(run['limitations'], list) and all(isinstance(x, str) for x in run['limitations'])
    assert run['sources'] and all(isinstance(x, str) for x in run['sources'])
    for source in run['sources']:
        relative_source(source)
    assert isinstance(run['metrics'], list)
    for m in run['metrics']:
        assert {'name', 'value', 'unit', 'boundary', 'samples', 'aggregation'} <= m.keys()
        assert isinstance(m['value'], (int, float)) and not isinstance(m['value'], bool) and math.isfinite(m['value'])
        assert m['samples'] is None or (isinstance(m['samples'], int) and not isinstance(m['samples'], bool) and m['samples'] > 0)
        assert all(isinstance(m[k], str) and m[k] for k in ('name', 'unit', 'boundary', 'aggregation'))
    assert run['status'] != 'unrun' or not run['metrics'], 'unrun cannot contain measured metrics'
    pub = run['publication']
    assert set(pub) == {'approved', 'reviewed_by', 'reviewed_on'}
    assert isinstance(pub['approved'], bool)
    if pub['approved']:
        assert isinstance(pub['reviewed_by'], str) and pub['reviewed_by'].strip() and isinstance(pub['reviewed_on'], str) and pub['reviewed_on'], 'publication requires explicit review'
        dt.date.fromisoformat(pub['reviewed_on'])
    return run


def load_runs():
    runs = [validate(json.loads(p.read_text())) for p in sorted((ROOT / 'Benchmarks/runs').glob('*.json'))]
    assert len({r['id'] for r in runs}) == len(runs), 'duplicate run id'
    for p, run in zip(sorted((ROOT / 'Benchmarks/runs').glob('*.json')), runs):
        assert p.stem == run['id'], 'filename must match run id'
    return sorted(runs, key=lambda r: (r['date'], r['id']), reverse=True)


def scan():
    # Generate repository links from the Git index, which includes staged evidence
    # but excludes another agent's unfinished, uncommitted report. A clean checkout
    # must reproduce this inventory. Registered runs are still discovered directly.
    names = git('ls-files', '--cached', '--', 'Tests/Reports', 'bench', 'docs', 'roadmap').splitlines()
    rows = []
    for name in sorted(set(names)):
        if not evidence_path(name):
            continue
        p = ROOT / name
        if p.is_symlink() or not p.is_file():
            continue
        # Membership is stable while active agents append logs. Sizes/hashes belong
        # to the explicitly dated audit, not a website build's reproducibility check.
        rows.append({'path': name, 'category': category(name)})
    return rows


def md_link(path, prefix='../'):
    return f'[{path}]({prefix}{quote(path, safe="/")})'


def outputs():
    runs = load_runs()
    inventory = scan()
    public = {'schema_version': 1, 'runs': [{k: r[k] for k in (
        'id', 'title', 'date', 'category', 'status', 'scope', 'summary', 'environment', 'metrics', 'limitations')}
        for r in runs if r['publication']['approved']]}
    # Explicit field projection: never serialize sources, paths, provenance, raw output or branch data to the site.
    result = {
        ROOT / 'Benchmarks/inventory/files.json': dump({'schema_version': 1, 'files': inventory}),
        ROOT / 'site/src/generated/benchmarks.json': dump(public),
    }
    lines = ['# Benchmark results', '',
             'One catalog for model comparisons and complete workflows. Original evidence stays at its linked path.', '',
             '[How to save a result](FORMAT.md) · [All evidence](EVIDENCE.md) · [Branch/worktree audit](inventory/README.md) · [Website](https://next-notes.com/?page=benchmarks)', '',
             'Status describes the stated scope only. A measured component is not production acceptance. Targets are not results; missing measurements stay missing.', '',
             '| Date | Area | Benchmark | Status | Result and limits |', '|---|---|---|---|---|']
    for r in runs:
        summary = r['summary'].replace('|', '\\|').replace('\n', ' ')
        lines.append(f"| {r['date']} | {r['category']} | [{r['title']}](runs/{r['id']}.json) | {r['status']} | {summary} |")
    lines += ['', '## Evidence by area', '']
    for cat in CATEGORIES:
        subset = [x for x in inventory if x['category'] == cat]
        lines.append(f'- [{cat.title()}](inventory/{cat}.md): {len(subset)} evidence files.')
        page = [f'# {cat.title()} evidence', '',
                'Discovery inventory, not a claim that every file is a benchmark or that its checks passed. Roadmap location does not establish acceptance.', '',
                '| Evidence |', '|---|']
        page += [f"| {md_link(x['path'], '../../')} |" for x in subset]
        result[ROOT / f'Benchmarks/inventory/{cat}.md'] = '\n'.join(page) + '\n'
    lines += ['', '## Operating rules', '',
              '- Keep cold, warm, load, generated PCM, audible output and complete delivery separate.',
              '- Compare only matching fixtures, metric boundaries, hardware, workload and grading rules.',
              '- Keep failures, partial coverage, blocked runs and unrun checks visible.',
              '- New models run one at a time: save, exit/unload, delete owned temporary assets, then continue.',
              '- Website summaries require explicit publication review. Owner audio, transcripts and raw outputs stay private.',
              '- No benchmark runs on app startup, dictation, meeting capture or voice paths.', '']
    result[ROOT / 'Benchmarks/README.md'] = '\n'.join(lines)
    evidence = ['# Evidence discovery', '', f'{len(inventory)} current evidence files discovered under Tests/Reports, bench, docs and roadmaps.', '',
                'Imported third-party reference trees and website assets are excluded. Files are catalogued without moving them or extracting private payloads. Legacy files remain unclassified until a reviewed run manifest records their scope and verdict.', '',
                '[Machine-readable inventory](inventory/files.json) · [Git/worktree audit](inventory/README.md)', '', '## Reviewed run sources', '']
    for r in runs:
        evidence += [f"### {r['title']}", '', f"{r['scope']} **{r['status']}**", '']
        evidence += [f'- {md_link(s)}' for s in r['sources']]
        evidence += ['']
    evidence += ['## Roadmaps', '', 'These links cover completed, active and planned work. Completion labels do not override later failing evidence.', '']
    evidence += [f"- {md_link(x['path'])}" for x in inventory if x['path'].startswith('roadmap/')]
    result[ROOT / 'Benchmarks/EVIDENCE.md'] = '\n'.join(evidence) + '\n'
    return result


def render(check=False):
    generated = outputs()
    stale = []
    for path, value in generated.items():
        if check:
            if not path.exists() or path.read_text() != value:
                stale.append(str(path.relative_to(ROOT)))
        else:
            atomic(path, value)
    assert not stale, 'stale generated files; run python3 Scripts/benchmarks.py render: ' + ', '.join(stale)
    print(f'BENCHMARK_CATALOG_OK: {len(load_runs())} runs, {len(generated)} generated files')


def audit():
    """Retain pins and evidence identities from every local/remote ref and checked-out tree."""
    stamp = dt.datetime.now(dt.timezone.utc).isoformat()
    refs = []
    def evidence_tree(commit):
        rows = []
        for entry in git('ls-tree', '-r', commit).splitlines():
            meta, path = entry.split('\t', 1)
            if evidence_path(path):
                rows.append({'path': path, 'git_blob': meta.split()[2], 'category': category(path)})
        return rows
    for line in git('for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads', 'refs/remotes').splitlines():
        ref, commit = line.split()
        refs.append({'ref': ref, 'kind': 'git_ref', 'commit': commit, 'evidence': evidence_tree(commit)})
    # Retired checkouts remain benchmark sources through immutable, main-reachable snapshots.
    for manifest in sorted((ROOT / 'Benchmarks/inventory').glob('worktree-repair-*/snapshots.json')):
        for snapshot in json.loads(manifest.read_text()):
            commit = snapshot['snapshot_commit']
            assert re.fullmatch(r'[0-9a-f]{40}', commit), 'invalid recovery commit'
            git('merge-base', '--is-ancestor', commit, 'HEAD')
            rows = evidence_tree(commit)
            container = '.worktree-preservation/ignored.tar.gz'
            for path in snapshot.get('ignored_paths', []):
                if evidence_path(path):
                    rows.append({'path': path, 'git_blob': snapshot['ignored_archive_git_blob'],
                                 'container': container, 'archive_member': path, 'category': category(path)})
            refs.append({'ref': 'preserved/' + snapshot['name'], 'kind': 'preserved_snapshot',
                         'commit': commit, 'evidence': rows})
    trees = []
    for block in git('worktree', 'list', '--porcelain').strip().split('\n\n'):
        fields = dict(line.split(' ', 1) if ' ' in line else (line, True) for line in block.splitlines())
        base = Path(fields['worktree'])
        item = {'path': str(base), 'commit': fields.get('HEAD'), 'branch': fields.get('branch'), 'evidence': []}
        if not base.is_dir():
            item['error'] = 'worktree unavailable'
        else:
            try:
                if shutil.which('rg'):
                    names = subprocess.check_output(['rg', '--files', '--hidden', '-g', '!.git'], cwd=base, text=True).splitlines()
                else:
                    names = git('ls-files', '--cached', '--others', '--exclude-standard', cwd=base).splitlines()
                names += git('ls-files', '--cached', cwd=base).splitlines()
                for name in sorted(set(names)):
                    if not evidence_path(name):
                        continue
                    p = base / name
                    if p.is_symlink() or not p.is_file():
                        continue
                    row = {'path': name, 'category': category(name), 'bytes': p.stat().st_size}
                    if row['bytes'] <= 4 * 1024 * 1024:
                        row['sha256'] = hashlib.sha256(p.read_bytes()).hexdigest()
                        current = ROOT / name
                        row['differs_from_canonical'] = not current.is_file() or current.is_symlink() or current.stat().st_size != row['bytes'] or hashlib.sha256(current.read_bytes()).hexdigest() != row['sha256']
                    item['evidence'].append(row)
            except (OSError, subprocess.CalledProcessError) as error:
                item['error'] = str(error)
        trees.append(item)
    payload = dump({'schema_version': 1, 'audited_at': stamp, 'refs': refs, 'worktrees': trees})
    # Historical copies compress well. Retain identities without 20+ MB of repeated paths.
    archive = ROOT / 'Benchmarks/inventory/git-audit.json.gz'
    archive.write_bytes(gzip.compress(payload.encode(), mtime=0))
    atomic(ROOT / 'Benchmarks/inventory/git-audit-summary.json', dump({
        'audited_at': stamp, 'refs': [{k: v for k, v in r.items() if k != 'evidence'} | {'evidence_files': len(r['evidence'])} for r in refs],
        'worktrees': [{k: v for k, v in r.items() if k != 'evidence'} | {'evidence_files': len(r['evidence']), 'different_files': sum(x.get('differs_from_canonical', False) for x in r['evidence'])} for r in trees]}))
    lines = ['# Branch and worktree evidence audit', '', f'Audited {stamp}. Read-only snapshot; no branch was merged or worktree removed.', '',
             '[Full pinned inventory, compressed JSON](git-audit.json.gz) · [Compact summary](git-audit-summary.json) · [Conversation audit](../CONVERSATIONS.md)', '',
             'Git blobs preserve committed versions. Uncommitted differences are pointers to their owning worktree, not backed-up content; retain those worktrees until their owners integrate the evidence. Counts include historical copies, not independent measurements.', '',
             '| Git ref or preserved snapshot | Pinned commit | Evidence files |', '|---|---|---:|']
    for r in refs:
        lines.append(f"| {r['ref']} | `{r['commit']}` | {len(r['evidence'])} |")
    lines += ['', '| Worktree | Branch / detached | Evidence files | Different or absent in canonical |', '|---|---|---:|---:|']
    for tree in trees:
        count = sum(x.get('differs_from_canonical', False) for x in tree['evidence'])
        lines.append(f"| [{Path(tree['path']).name}]({quote(tree['path'], safe='/')}) | {tree['branch'] or 'detached'} | {len(tree['evidence'])} | {count} |")
    lines += ['', '## Retrieve a historical result', '',
              'Use the exact commit and path in the JSON with `git show <commit>:<path>`. Do not substitute a branch tip after it moves. A historical result does not qualify the current build.', '',
              'This scans current local/remote refs and worktrees plus main-reachable recovery snapshots from retired checkouts. Preserved snapshots are evidence sources, not additional branches or worktrees. It does not claim recovery of deleted/unreachable commits, ignored temporary files, inaccessible chats, or external owner recordings.', '']
    current_paths = {r['path'] for r in scan()}
    missing = {}
    for ref in refs:
        for row in ref['evidence']:
            if row['path'] not in current_paths:
                missing.setdefault(row['path'], (ref['commit'], row))
    locations = {}
    for tree in trees:
        for row in tree['evidence']:
            locations.setdefault(row['path'], str(Path(tree['path']) / row['path']))
    historical = ['# Historical evidence absent from the canonical checkout', '',
                  f'{len(missing)} unique paths retained in the audited refs. These are historical artifacts, not additional independent runs.', '',
                  'The local worktree links open the current file there; it can differ from the pinned version. The exact committed bytes are recoverable with the git command beside each item. No report was moved or worktree deleted.', '',
                  '| Evidence | Available local copy | Exact historical retrieval |', '|---|---|---|']
    for name, (commit, row) in sorted(missing.items()):
        location = locations.get(name)
        link = f'[Open worktree copy]({quote(location, safe="/")})' if location else 'Retained in Git only'
        retrieval = f'git show {commit}:{name}'
        if row.get('container'):
            retrieval = f"git show {commit}:{row['container']} | tar -xzOf - {name}"
        historical.append(f'| {name} | {link} | `{retrieval}` |')
    atomic(ROOT / 'Benchmarks/inventory/historical.md', '\n'.join(historical) + '\n')
    lines += ['', '[Browse historical-only evidence](historical.md). Files above 4 MiB are listed without a working-file content hash; committed Git blob identities remain in the archive.', '']
    atomic(ROOT / 'Benchmarks/inventory/README.md', '\n'.join(lines))
    print(f"BENCHMARK_AUDIT_OK: {sum(x['kind'] == 'git_ref' for x in refs)} Git refs, {sum(x['kind'] == 'preserved_snapshot' for x in refs)} preserved snapshots, {len(trees)} worktrees")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['render', 'check', 'add', 'audit'])
    parser.add_argument('manifest', nargs='?')
    args = parser.parse_args()
    if args.command == 'audit':
        audit()
    elif args.command == 'add':
        assert args.manifest, 'provide a run manifest'
        run = validate(json.loads(Path(args.manifest).read_text()))
        path = ROOT / 'Benchmarks/runs' / (run['id'] + '.json')
        # Atomic exclusive create: concurrent agents cannot overwrite the same run.
        with path.open('x') as f:
            f.write(dump(run))
        render()
    else:
        render(args.command == 'check')


if __name__ == '__main__':
    try:
        main()
    except (AssertionError, ValueError, OSError, TypeError, KeyError) as error:
        raise SystemExit(f'BENCHMARK_CATALOG_FAILED: {error}')
