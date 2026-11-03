#!/usr/bin/env python3
"""Provision the pinned OpenCV resource and build source-bound native artifacts."""
import argparse
from pathlib import Path
import shutil
import subprocess
ROOT=Path(__file__).resolve().parents[1]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--opencv-source',type=Path)
    args=parser.parse_args()
    native=ROOT/'.build/native';native.mkdir(parents=True,exist_ok=True)
    opencv=native/'opencv2.xcframework'
    verify=['python3',str(ROOT/'scripts/verify_capture_opencv.py')]
    if args.opencv_source:
        supplied=args.opencv_source.resolve(strict=True)
        subprocess.run([*verify,str(supplied)],check=True)
        if not opencv.exists():shutil.copytree(supplied,opencv,symlinks=True)
    if not opencv.exists():subprocess.run(['bash',str(ROOT/'scripts/install_opencv.sh')],check=True)
    subprocess.run(verify,check=True)
    artifact=native/'DocumentOpenCVBridge.xcframework'
    if not artifact.exists():subprocess.run(['python3',str(ROOT/'scripts/build_capture_bridge.py')],check=True)
    subprocess.run(['python3',str(ROOT/'scripts/verify_capture_bridge.py')],check=True)

if __name__=='__main__':main()
