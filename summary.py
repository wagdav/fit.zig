#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p "python3.withPackages(ps: [ps.fitparse])"
"""Summarize a FIT activity read from stdin, using the fitparse library.

A Python equivalent of src/main.zig. Note that fitparse applies the profile
scale/offset for us (so total_distance comes back in metres, elapsed time in
seconds), but positions stay in semicircles, so we convert those by hand.

    python3 summary.py < activity.fit
"""

import io
import sys

from fitparse import FitFile


def degrees(semicircles):
    return semicircles * (180.0 / 2**31)


def main():
    fit = FitFile(io.BytesIO(sys.stdin.buffer.read()))

    # Activity summary — from the single `session` message.
    summary = None
    track = []
    for msg in fit.get_messages():
        if msg.mesg_type is None:
            continue

        if msg.mesg_type.name == "session":
            summary = {
                "sport": msg.get_value("sport"),
                "total_distance": msg.get_value("total_distance"),          # metres
                "total_elapsed_time": msg.get_value("total_elapsed_time"),  # seconds
            }

        if msg.mesg_type.name == "record":
            track.append( {
                "position_lat": msg.get_value("position_lat"),   # semicircles
                "position_long": msg.get_value("position_long"),
                "altitude": msg.get_value("altitude"),
                "heart_rate": msg.get_value("heart_rate"),
            })

    if summary is not None:
        sport = summary["sport"] if summary["sport"] is not None else "?"
        print(f"sport:      {sport}")
        if summary["total_distance"] is not None:
            print(f"distance:   {summary['total_distance'] / 1000.0:.2f} km")
        if summary["total_elapsed_time"] is not None:
            print(f"elapsed:    {summary['total_elapsed_time']:.0f} s")
    else:
        print("(no session message)")

    with_gps = 0
    first = None
    last = None
    for p in track:
        if p["position_lat"] is not None and p["position_long"] is not None:
            with_gps += 1
            if first is None:
                first = p
            last = p

    print(f"records:    {len(track)} ({with_gps} with GPS)")
    if first is not None:
        print(f"start:      {degrees(first['position_lat']):.5f}, {degrees(first['position_long']):.5f}")
    if last is not None:
        print(f"end:        {degrees(last['position_lat']):.5f}, {degrees(last['position_long']):.5f}")


if __name__ == "__main__":
    main()
