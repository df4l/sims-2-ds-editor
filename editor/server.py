"""Sims 2 DS map editor: local HTTP server + browser UI (phase 5). Runs the same on Windows and Linux.

  python editor/server.py              # http://127.0.0.1:8765, opens the browser
  python editor/server.py --port 9000 --no-browser

API (JSON unless noted):
  GET /api/locations                   the 33 locations
  GET /api/location/<id>?lang=en       layout: entry points, blocks (groups of items, scripts as text)
  GET /api/bsp/<id>                    collision brushes (vertices + faces, layout units)
  GET /api/model/<entry>.glb           BMD0 entry as GLB (model/gltf-binary)
  GET /api/edits                       saved edits [kind, entry], undo depth
  POST /api/edit {op, loc, ...}        op: item (b, g, i, x?, y?, z?, angle_deg?, raw?), duplicate (b, g, i),
                                       delete (b, g, i), entry (k, x?, y?, z?, angle_rad?), bsp_delete (p),
                                       bsp_move (p, delta), bsp_box (lo, hi),
                                       furniture (i, prop?, x?, z?, rot?) = default hotel room furniture, revert, undo
                                       -> 200 {ok, ...} or 400 {error} (edit refused, nothing changed)
  POST /api/build                      build/editor_rom/sims2_edited.nds from the saved edits
"""
import argparse
import json
import re
import sys
import traceback
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, str(Path(__file__).resolve().parent))
import backend  # noqa: E402
import project  # noqa: E402

STATIC = Path(__file__).resolve().parent / 'static'
TYPES = {'.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
         '.css': 'text/css; charset=utf-8', '.png': 'image/png', '.json': 'application/json'}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, ctype='application/json'):
        if isinstance(body, str):
            body = body.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store' if ctype.startswith('application/json') else 'max-age=60')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        p = u.path
        try:
            if p == '/api/locations':
                return self._send(200, json.dumps({'locations': backend.locations_json(), 'langs': backend.LANGS}))
            if m := re.fullmatch(r'/api/location/(\d+)', p):
                lang = q.get('lang', ['en'])[0]
                return self._send(200, json.dumps(backend.location_json(int(m[1]), lang)))
            if m := re.fullmatch(r'/api/bsp/(\d+)', p):
                return self._send(200, backend.bsp_json(int(m[1])))
            if p == '/api/edits':
                return self._send(200, json.dumps({'edits': project.edited(), 'undo': len(project._undo)}))
            if m := re.fullmatch(r'/api/model/(\d+)\.glb', p):
                glb = backend.model_glb(int(m[1]))
                return self._send(200, glb, 'model/gltf-binary') if glb else self._send(404, '{"error":"no model"}')
            f = (STATIC / ('index.html' if p == '/' else p.lstrip('/'))).resolve()
            if STATIC in f.parents and f.is_file():
                return self._send(200, f.read_bytes(), TYPES.get(f.suffix, 'application/octet-stream'))
            self._send(404, '{"error":"not found"}')
        except Exception as e:  # noqa: BLE001 -- report to the UI instead of dropping the connection
            traceback.print_exc()
            self._send(500, json.dumps({'error': f'{type(e).__name__}: {e}'}))

    def do_POST(self):
        p = urlparse(self.path).path
        try:
            n = int(self.headers.get('Content-Length') or 0)
            a = json.loads(self.rfile.read(n) or b'{}')
            if p == '/api/edit':
                return self._send(200, json.dumps({'ok': True, **(edit(a) or {})}))
            if p == '/api/build':
                return self._send(200, json.dumps({'ok': True, **project.build_rom()}))
            self._send(404, '{"error":"not found"}')
        except (project.EditError, KeyError, TypeError, ValueError) as e:
            self._send(400, json.dumps({'error': str(e) if isinstance(e, project.EditError) else f'{type(e).__name__}: {e}'}))
        except Exception as e:  # noqa: BLE001
            traceback.print_exc()
            self._send(500, json.dumps({'error': f'{type(e).__name__}: {e}'}))


def edit(a: dict):
    op, loc = a['op'], a.get('loc')
    pos = {k: a[k] for k in ('x', 'y', 'z') if a.get(k) is not None}
    if op == 'item':
        project.edit_item(loc, a['b'], a['g'], a['i'], angle_deg=a.get('angle_deg'), raw=a.get('raw'), **pos)
    elif op == 'duplicate':
        return {'index': project.duplicate_item(loc, a['b'], a['g'], a['i'])}
    elif op == 'delete':
        project.delete_item(loc, a['b'], a['g'], a['i'])
    elif op == 'entry':
        project.edit_entry(loc, a['k'], angle_rad=a.get('angle_rad'), **pos)
    elif op == 'bsp_delete':
        project.bsp_delete(loc, a['p'])
    elif op == 'bsp_move':
        project.bsp_move(loc, a['p'], a['delta'])
    elif op == 'bsp_box':
        project.bsp_box(loc, a['lo'], a['hi'])
    elif op == 'furniture':
        project.edit_furniture(loc, a['i'], prop=a.get('prop'), x=a.get('x'), z=a.get('z'), rot=a.get('rot'))
    elif op == 'revert':
        nav, b = project.entries_of(loc)
        for kind, e in (('layout', nav), ('bsp', b), ('furniture', project.furniture_slot(loc))):
            if e is not None:
                project.revert(kind, e)
    elif op == 'undo':
        kind, e = project.undo()
        return {'undone': [kind, e]}
    else:
        raise project.EditError(f'unknown op {op}')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--port', type=int, default=8765)
    ap.add_argument('--no-browser', action='store_true')
    a = ap.parse_args()
    srv = ThreadingHTTPServer(('127.0.0.1', a.port), Handler)
    url = f'http://127.0.0.1:{a.port}/'
    print(f'Sims 2 DS editor on {url}  (Ctrl+C to stop)')
    backend.db()
    if not a.no_browser:
        webbrowser.open(url)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
