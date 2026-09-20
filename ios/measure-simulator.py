#!/usr/bin/env python3
"""Read-only macOS measurements for explicit running Simulator PIDs.
CPU is process CPU-time delta / wall-time, not ps's smoothed percentage.
"""
import argparse
import csv
import datetime
import json
import pathlib
import subprocess
import time


def cpu_seconds(value):
    days, clock = (value.split('-', 1) if '-' in value else ('0', value))
    parts = [float(part) for part in clock.split(':')]
    seconds = 0.0
    for part in parts:
        seconds = seconds * 60 + part
    return int(days) * 86400 + seconds


def snapshot(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'pid=,time=,rss=,etime=,command='], capture_output=True, text=True)
    fields = result.stdout.strip().split(None, 4)
    if result.returncode or len(fields) < 5:
        return None
    if '/CoreSimulator/Devices/' not in fields[4] or '/openttd.app/openttd' not in fields[4]:
        raise ValueError(f'{pid} is not an OpenTTD Simulator process')
    return {'pid': int(fields[0]), 'cpu_seconds': cpu_seconds(fields[1]), 'rss_kib': int(fields[2]),
            'process_elapsed': fields[3], 'command': fields[4]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pids', type=int, nargs='+')
    parser.add_argument('--seconds', type=int, default=10, choices=range(2, 61), metavar='2..60')
    parser.add_argument('--sample', action='store_true', help='After counters, take a 3-second stack sample of each live PID')
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    output = root / 'build' / 'validation' / ('performance-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    output.mkdir(parents=True, exist_ok=False)
    rows = []
    started = time.monotonic()
    for index in range(args.seconds + 1):
        for pid in args.pids:
            snap = snapshot(pid)
            if snap is not None:
                rows.append({'elapsed_seconds': round(time.monotonic() - started, 3), **snap})
        if index != args.seconds:
            time.sleep(max(0, started + index + 1 - time.monotonic()))
    with (output / 'samples.csv').open('w', newline='') as file:
        writer = csv.DictWriter(file, fieldnames=['elapsed_seconds', 'pid', 'cpu_seconds', 'rss_kib', 'process_elapsed', 'command'])
        writer.writeheader()
        writer.writerows(rows)
    summary = {'warning': 'Simulator debug-build measurements; not physical-device CPU, battery or memory budget.', 'processes': []}
    for pid in args.pids:
        measurements = [row for row in rows if row['pid'] == pid]
        if len(measurements) < 2:
            summary['processes'].append({'pid': pid, 'status': 'insufficient measurements/process exited'})
            continue
        first, last = measurements[0], measurements[-1]
        if last['command'] != first['command'] or last['cpu_seconds'] < first['cpu_seconds']:
            summary['processes'].append({'pid': pid, 'status': 'process identity changed; measurement rejected'})
            continue
        elapsed = last['elapsed_seconds'] - first['elapsed_seconds']
        summary['processes'].append({'pid': pid, 'command': first['command'], 'wall_seconds': round(elapsed, 3),
            'cpu_percent_one_core': round(100 * (last['cpu_seconds'] - first['cpu_seconds']) / elapsed, 2),
            'rss_mib_min': round(min(row['rss_kib'] for row in measurements) / 1024, 2),
            'rss_mib_max': round(max(row['rss_kib'] for row in measurements) / 1024, 2),
            'observations': len(measurements)})
        if args.sample and snapshot(pid) is not None:
            result = subprocess.run(['sample', str(pid), '3', '10', '-file', str(output / f'stacks-{pid}.txt')], capture_output=True, text=True)
            (output / f'sample-command-{pid}.log').write_text(result.stdout + result.stderr)
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    print(f'Evidence: {output}')


if __name__ == '__main__':
    main()
