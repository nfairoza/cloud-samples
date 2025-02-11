#!/bin/bash

aws s3 cp s3://noortestdata/perfspect/perfspect-amd.tgz .
sudo apt install python3-pip python3-dev build-essential python3-full python3-venv -y
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt black flake8
export PATH=$PATH:$HOME/.local/bin
black perf-postprocess.py
make
cd build
