#!/usr/bin/env python3
"""Check a real Simulator switch's final motion against its settled pixels.

Supply an interval containing the final 80px of motion and a settled frame.
Uses original presentation timestamps, without resampling or speeding up video.
This measures recorded visual holds and jumps, not device display FPS.
"""
import argparse
import json
import subprocess
import sys


def check(video, start, end):
    metadata = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-fflags", "+igndts", "-select_streams", "v:0", "-show_entries",
        "stream=width,height:frame=pts_time", "-of", "json", video]))
    width = metadata["streams"][0]["width"]
    height = metadata["streams"][0]["height"]
    times = [float(frame["pts_time"]) for frame in metadata["frames"]
             if start <= float(frame["pts_time"]) <= end]
    # Average a broad unchanged body band into a horizontal text signature.
    # Excludes navigation/status controls and doesn't depend on OCR accuracy.
    band_y, band_h = int(height * .316), int(height * .474)
    raw = subprocess.check_output([
        "ffmpeg", "-v", "fatal", "-fflags", "+igndts", "-i", video, "-vf",
        f"select=between(t\\,{start}\\,{end}),crop={width}:{band_h}:0:{band_y},"
        f"scale={width}:1,format=gray", "-fps_mode", "passthrough",
        "-f", "rawvideo", "-"])
    assert len(raw) == len(times) * width, "Frame/timestamp count differs"
    assert len(times) >= 3, "Interval needs motion and settled frames"
    frames = [raw[i:i + width] for i in range(0, len(raw), width)]
    target = frames[-1]
    vertical = subprocess.check_output([
        "ffmpeg", "-v", "fatal", "-fflags", "+igndts", "-i", video, "-vf",
        f"select=between(t\\,{start}\\,{end}),crop={width}:{band_h}:0:{band_y},"
        f"scale=1:{band_h},format=gray", "-fps_mode", "passthrough",
        "-f", "rawvideo", "-"])
    assert len(vertical) == len(times) * band_h, "Vertical frame count differs"
    vertical_target = vertical[-band_h:]
    margin = max(110, int(width * .094))
    samples = range(margin, width - margin)
    trace = []
    failures = []
    for index, (time, pixels) in enumerate(zip(times, frames)):
        error, x = min((sum(abs(pixels[i + shift] - target[i]) for i in samples), shift)
                       for shift in range(-80, 11))
        if error > len(samples) * 3:
            failures.append({"kind": "body_content_or_layout_mismatch", "time": time,
                             "match_error": error})
        vertical_pixels = vertical[index * band_h:(index + 1) * band_h]
        vertical_error, y = min((sum(abs(vertical_pixels[i + shift] - vertical_target[i])
                                    for i in range(60, band_h - 60)), shift)
                                for shift in range(-50, 51))
        trace.append({"time": time, "x_from_settled_px": x, "y_from_settled_px": y,
                      "match_error": error, "vertical_match_error": vertical_error})
    for frame in trace:
        if -40 <= frame["x_from_settled_px"] <= 2 and abs(frame["y_from_settled_px"]) > 3:
            failures.append({"kind": "vertical_tail_displacement", "frame": frame})
    for previous, current in zip(trace, trace[1:]):
        residual = previous["x_from_settled_px"]
        if -40 <= residual <= -3 and current["time"] - previous["time"] > .09:
            failures.append({"kind": "unfinished_tail_hold", "from": previous,
                             "to": current, "seconds": current["time"] - previous["time"]})
        if -40 <= residual <= 0 and current["x_from_settled_px"] < residual - 3:
            failures.append({"kind": "tail_moves_backwards", "from": previous, "to": current})
    motion_observed = any(-40 <= frame["x_from_settled_px"] <= -3 for frame in trace)
    assert motion_observed or failures, "No measurable motion or handoff failure in interval"
    assert all(abs(frame["x_from_settled_px"]) <= 2 for frame in trace[-3:]), "End is not settled"
    return {"video": video, "start": start, "end": end, "trace": trace,
            "motion_observed": motion_observed, "failures": failures, "passed": not failures}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video")
    parser.add_argument("start", type=float)
    parser.add_argument("end", type=float)
    args = parser.parse_args()
    result = check(args.video, args.start, args.end)
    print(json.dumps(result, indent=2))
    sys.exit(0 if result["passed"] else 1)
