"""Numeric classifier for an explicit optimized batch diagnostic; no OS/product access."""
def classify_frontend(command, expected_start, current_usage):
    tokens = command.split()
    if not tokens or tokens[0].rsplit('/', 1)[-1] != 'swift-frontend':
        return None, None
    names = [tokens[i + 1] for i, token in enumerate(tokens[:-1]) if token == '-module-name']
    valid = bool(current_usage and current_usage.get('processStart') == expected_start)
    primary_count = tokens.count('-primary-file')
    compile_job = '-c' in tokens
    scope = ('main-compile' if compile_job else 'main-metadata') if names == ['NextNotes'] else ('dependency' if len(names) == 1 else 'unknown')
    optimized = '-O' in tokens
    whole = '-whole-module-optimization' in tokens or '-wmo' in tokens
    proof = scope == 'main-compile' and valid and optimized and not whole and 1 <= primary_count <= 32
    data = {'scope':scope, 'moduleKnown':len(names)==1, 'identityValid':valid, 'primaryFileCount':primary_count, 'optimized':optimized, 'wholeModuleFlagPresent':whole, 'mainCompileBatchProof':proof}
    if not valid:
        return data, 'owned frontend argv identity unavailable or changed'
    if scope == 'main-compile' and not proof:
        return data, 'owned NextNotes optimized primary-file batch proof refused'
    if compile_job and (primary_count < 1 or primary_count > 32 or whole or not optimized):
        return data, 'owned dependency optimized batch proof refused'
    return data, None


def classify_driver(command, expected_start, current_usage):
    tokens = command.split()
    if not tokens or tokens[0].rsplit('/', 1)[-1] not in ('swiftc', 'swift-driver'):
        return None, None
    names = [tokens[i + 1] for i, token in enumerate(tokens[:-1]) if token == '-module-name']
    if len(names) != 1:
        return None, None
    valid = bool(current_usage and current_usage.get('processStart') == expected_start)
    jobs = []
    modes = []
    for i, token in enumerate(tokens):
        if token == '-j' and i + 1 < len(tokens):
            jobs.append(tokens[i + 1])
        elif token.startswith('-j') and token[2:].isdigit():
            jobs.append(token[2:])
        if token in ('-whole-module-optimization','-wmo','-no-whole-module-optimization'):
            modes.append(token)
    proof = valid and bool(jobs) and jobs[-1] == '1' and bool(modes) and modes[-1] == '-no-whole-module-optimization'
    data = {'scope':'main-driver' if names == ['NextNotes'] else 'dependency-driver', 'identityValid':valid, 'singleJobBatchDriverProof':proof, 'lastJobs':int(jobs[-1]) if jobs and jobs[-1].isdigit() else None}
    return data, None if proof else 'owned single-job non-WMO driver proof refused'
