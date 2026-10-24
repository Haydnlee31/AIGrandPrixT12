"""Isolated combined HTTP/browser validation; never uses the user's Library DB."""
import argparse
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
parser = argparse.ArgumentParser()
parser.add_argument('--directory', required=True)
parser.add_argument('--port', type=int, default=8767)
parser.add_argument('--live', action='store_true')
args = parser.parse_args()
directory = Path(args.directory).resolve()
directory.mkdir(parents=True, exist_ok=True)
from scripts.run_local import configure
configure(ROOT / '.env')
os.environ.update(DATABASE_URL=f'sqlite:///{directory / "validation.db"}',
    API_TOKENS=json.dumps({'browser-fixture-token': 'browser-fixture-user'}),
    DEMO_MODE='false', EMBEDDED_WORKER='true', MULTIMODAL_ENABLED='true',
    ANNOTATION_PROVIDER='demo', MYMAH_PRICE_DIRECTORY=str(directory / 'prices'),
    CORS_ORIGINS='[]')
os.environ.pop('VERCEL', None)
from alembic.config import Config
from alembic import command
command.upgrade(Config(str(ROOT / 'alembic.ini')), 'head')
from backend.app.combined import create_app
from backend.app.intelligence import DemoAnnotationProvider
from backend.app.catalog.service import import_dataset
from scripts.validate_multimodal_live import audio_fixture, BudgetedProvider, MeasuredProvider
from backend.tests.test_multimodal_pipeline import FakeMultimodal
provider = BudgetedProvider(MeasuredProvider()) if args.live else FakeMultimodal()
app = create_app(main_options={'annotation_provider': DemoAnnotationProvider(),
    'multimodal_provider': provider, 'multimodal_enabled': True},
    relay_options={'price_background': False})
if not args.live:
    import_dataset(app.state.main.state.factory, 'abo', [{
        'source_id':'abo', 'source_record_id':'synthetic-validation-watch', 'data_kind':'open_dataset',
        'title':'Synthetic validation digital wristwatch', 'category':'Accessories > Watches > Digital watches',
        'brand':None, 'description':'Synthetic rectangular digital wristwatch for browser validation.',
        'attributes':{'shape':'Rectangular'}, 'merchant':{'id':None,'name':None,'platform':'abo'},
        'offer':{'id':'synthetic-validation-watch','environment':'local'},
        'provenance':{'source_url':'https://catalog.example.org/synthetic-validation-watch'}
    }], version='synthetic-browser-fixture', checksum='a'*64)
audio_fixture(directory)
(directory / 'ready.json').write_text(json.dumps({'mode':'live' if args.live else 'fixture','port':args.port}))
import uvicorn
try:
    uvicorn.run(app, host='127.0.0.1', port=args.port, access_log=False, log_level='warning')
finally:
    counts = provider.counts() if args.live else {'analysis_invocations':len(provider.snapshots), 'transcription_invocations':len(provider.recordings)}
    (directory / 'provider-counts.json').write_text(json.dumps(counts))
