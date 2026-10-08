"""Cache-only diagnostic classifier; no product code or OS access."""
def classify_frontend(command, expected_start, current_usage):
    tokens = command.split()
    if not tokens or 'swift-frontend' not in tokens[0]:
        return None, None
    names = [tokens[i + 1] for i, token in enumerate(tokens[:-1]) if token == '-module-name']
    valid_identity = bool(current_usage and current_usage.get('processStart') == expected_start)
    raw_counts = [tokens[i + 1] for i, token in enumerate(tokens[:-1]) if token == '-num-threads']
    last_count = int(raw_counts[-1]) if raw_counts and raw_counts[-1].isdigit() else None
    scope = 'main' if names == ['NextNotes'] else ('dependency' if len(names) == 1 else 'unknown')
    metadata = {'scope': scope, 'moduleKnown': len(names) == 1, 'identityValid': valid_identity,
                'lastThreadCount': last_count, 'countOccurrences': len(raw_counts),
                'mainThreadProof': scope == 'main' and valid_identity and last_count == 1}
    if not valid_identity:
        return metadata, 'owned frontend argv identity unavailable or changed'
    if scope == 'main' and last_count != 1:
        return metadata, 'effective owned NextNotes frontend thread count is not1'
    return metadata, None
