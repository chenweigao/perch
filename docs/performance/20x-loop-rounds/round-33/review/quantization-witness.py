import json
import pathlib
import statistics

out = pathlib.Path(__file__).resolve().parent
raw = pathlib.Path('<worktree>/.local/round33/macos-ab-v1-summary.json')
metric = json.loads(raw.read_text())['find_bar_reopen_query']
b = metric['baseline_samples']
c = metric['candidate_samples']
latent_b = [0.0951] * 5 + [0.1149]
assert [f'{x:.2f}' for x in latent_b] == [f'{x:.2f}' for x in b]

def stats(b, c):
    change = (statistics.median(c) / statistics.median(b) - 1) * 100
    spread = max((max(x) - min(x)) / min(x) * 100 for x in (b, c))
    worst = max((ci / bi - 1) * 100 for bi, ci in zip(b, c))
    return {'baseline_median': statistics.median(b), 'candidate_median': statistics.median(c), 'change_percent': change, 'max_spread_percent': spread, 'worst_pair_percent': worst, 'passes_benefit_classifier': abs(round(change, 2)) > round(spread, 2) and round(worst, 2) < 0, 'ranges_separated': max(c) < min(b)}

result = {'printed_baseline': b, 'candidate': c, 'printed_stats': stats(b, c), 'consistent_latent_baseline_witness': latent_b, 'witness_stats': stats(latent_b, c)}
assert result['printed_stats']['passes_benefit_classifier']
assert not result['witness_stats']['passes_benefit_classifier']
assert result['witness_stats']['ranges_separated']
(out / 'quantization-witness.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
print('PASS: same 2dp baseline receipts permit a 4dp sample set failing the required beyond-spread classifier, despite six separated improvements')
