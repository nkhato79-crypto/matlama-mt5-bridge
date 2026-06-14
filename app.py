"""
Matlama MT5 Bridge - Flask API
Gold (XAUUSD) trading bridge between external signals and MetaTrader 5
"""

import os
import logging
from datetime import datetime
from functools import wraps

from flask import Flask, request, jsonify
from dotenv import load_dotenv
import requests as http_requests

load_dotenv()

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

app = Flask(__name__)

", "hMT5_VPS_URL  = os.getenv("MT5_VPS_URL", "http://173.225.110.145:5000")
