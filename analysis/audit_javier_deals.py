#!/usr/bin/env python3
"""Forensic audit of Javier Gold Scalper deal exports.

Reads a deals CSV exported from MT5 (like Analysis-and-Python/javier-deals.csv
inside Javier-logs-*.zip) and reconstructs what the compiled EA actually did:
concurrency, same-direction stacking, win/loss asymmetry, stop-outs.

Usage:
    python3 audit_javier_deals.py path/to/javier-deals.csv
"""
import argparse
import collections
import csv
import datetime
import itertools
import sys


def load(path):
    with open(path, encoding='utf-8-sig') as fh:
        return list(csv.DictReader(fh))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('csv', help='deals CSV export')
    args = ap.parse_args()

    rows = load(args.csv)
    if not rows:
        sys.exit('empty CSV')

    pos = collections.defaultdict(list)
    for r in rows:
        pos[r['position_id']].append(r)

    events = []
    for pid, ds in pos.items():
        entries = [d for d in ds if d['entry'] == '0']
        exits = [d for d in ds if d['entry'] == '1']
        if not entries or not exits:
            continue
        t0 = min(int(d['time']) for d in entries)
        t1 = max(int(d['time']) for d in exits)
        vol = sum(float(d['volume']) for d in entries)
        net = sum(float(d['profit']) + float(d['commission']) + float(d['swap']) + float(d['fee'])
                  for d in ds)
        reasons = collections.Counter(d['reason'] for d in exits)
        events.append(dict(t0=t0, t1=t1, vol=vol, net=net, pid=pid,
                           typ=entries[0]['type'], deals=len(entries), reasons=reasons))
    events.sort(key=lambda e: e['t0'])

    # concurrency sweep
    pts = []
    for e in events:
        pts.append((e['t0'], 1, e['vol']))
        pts.append((e['t1'], -1, -e['vol']))
    pts.sort()
    cur = curvol = maxc = 0
    maxvol = 0.0
    peak_t = None
    for t, s, v in pts:
        cur += s
        curvol += v
        if cur > maxc:
            maxc, peak_t = cur, t
        maxvol = max(maxvol, curvol)

    def overlap(a, b):
        return a['t0'] < b['t1'] and b['t0'] < a['t1']

    same_dir_pairs = collections.Counter()
    for a, b in itertools.combinations(events, 2):
        if overlap(a, b) and a['typ'] == b['typ']:
            same_dir_pairs['SELL' if a['typ'] == '1' else 'BUY'] += 1

    nets = [e['net'] for e in events]
    wins = [n for n in nets if n > 0]
    losses = [n for n in nets if n < 0]
    so = [e for e in events if e['reasons'].get('6')]

    print(f"positions reconstructed : {len(events)}")
    print(f"win / loss / flat     : {len(wins)} / {len(losses)} / {len(nets) - len(wins) - len(losses)}")
    if nets:
        print(f"winrate               : {100 * len(wins) / len(nets):.1f}%")
    print(f"net closed result     : {sum(nets):.2f}")
    if wins:
        print(f"avg win               : {sum(wins) / len(wins):.2f}")
    if losses:
        print(f"avg loss              : {sum(losses) / len(losses):.2f}")
    if wins and losses:
        pf = sum(wins) / abs(sum(losses))
        ratio = (sum(losses) / len(losses)) / (sum(wins) / len(wins))
        print(f"profit factor         : {pf:.3f}   (avg loss / avg win = {ratio:.2f})")
    print(f"max concurrency       : {maxc} positions"
          + (f" at {datetime.datetime.utcfromtimestamp(peak_t)} UTC" if peak_t else ""))
    print(f"max concurrent volume : {maxvol:.2f} lots")
    print(f"same-direction overlapping pairs: {dict(same_dir_pairs)}")
    print(f"stop-out exits (reason=6): {len(so)}")
    durs = sorted((e['t1'] - e['t0']) // 60 for e in events)
    if durs:
        print(f"hold minutes p10/med/p90/max: "
              f"{durs[len(durs)//10]} / {durs[len(durs)//2]} / {durs[9*len(durs)//10]} / {durs[-1]}")
    print("worst positions:")
    for e in sorted(events, key=lambda x: x['net'])[:10]:
        ts = datetime.datetime.utcfromtimestamp(e['t0']).strftime('%m-%d %H:%M')
        side = 'SELL' if e['typ'] == '1' else 'BUY'
        print(f"  {ts} UTC {side} vol={e['vol']:.2f} net={e['net']:.2f} "
              f"held={(e['t1']-e['t0'])//60}m reasons={dict(e['reasons'])}")

    # stacking bursts: entries within a 10-minute window, same direction
    print("same-direction entry bursts (>=4 entries within 10 min):")
    entries = []
    for r in rows:
        if r['entry'] == '0':
            entries.append((int(r['time']), r['type'], float(r['volume'])))
    entries.sort()
    i = 0
    bursts = 0
    while i < len(entries):
        j = i
        while (j + 1 < len(entries) and entries[j + 1][0] - entries[i][0] <= 600
               and entries[j + 1][1] == entries[i][1]):
            j += 1
        if j - i + 1 >= 4:
            ts = datetime.datetime.utcfromtimestamp(entries[i][0]).strftime('%m-%d %H:%M')
            side = 'SELL' if entries[i][1] == '1' else 'BUY'
            print(f"  {ts} UTC {side}: {j - i + 1} entries in "
                  f"{(entries[j][0] - entries[i][0]) // 60} min")
            bursts += 1
            i = j + 1
        else:
            i += 1
    if bursts == 0:
        print("  none")


if __name__ == '__main__':
    main()
