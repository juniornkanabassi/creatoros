#!/usr/bin/env python3
"""Run every control command on synthetic data in the supplied build, with no input events."""
import base64, concurrent.futures, json, os, pathlib, signal, socket, subprocess, sys, tempfile, time, uuid
app = pathlib.Path(sys.argv[1]).resolve()
cli = app / 'Contents/MacOS/creatoros' if app.suffix == '.app' else app.parent / 'creatoros'
exe = app / 'Contents/MacOS/ProjectTemplates' if app.suffix == '.app' else app
shim = app / 'Contents/Resources/mcp/creatoros-mcp.mjs' if app.suffix == '.app' else pathlib.Path('mcp/creatoros-mcp.mjs').resolve()
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-ai-', dir='/private/tmp'))
checks = 0

def check(condition, label):
    global checks
    assert condition, label
    checks += 1; print('PASS', label, flush=True)

def command(*args, code=0):
    result = subprocess.run([str(cli), *args, '--json', '--data-directory', str(root)], capture_output=True, text=True, timeout=30)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    return json.loads(result.stdout)

check(command('status') == {'running':False}, 'status works while stopped without launching')
formats = ['Long','Short','Podcast','Livestream']
template = str(uuid.uuid4()).upper()
payload = root / 'Templates' / template
(payload / '01 Documents').mkdir(parents=True)
(payload / '05 Other').mkdir()
(payload / '03 Media').mkdir()
(payload / '01 Documents/Template.md').write_text('# Template\nUnchanged body\n')
(payload / 'Template.txt').write_bytes(b'opaque payload')
for fmt in formats: (root / 'Projects' / fmt).mkdir(parents=True)
library = {'schema':6, 'projects':[], 'templates':[{'id':template,'name':'Fixture','imported':0,'source':str(payload),'mode':'full'}],
           'presets':[{'format':fmt,'destination':str(root / 'Projects' / fmt)} for fmt in formats], 'templateSets':[], 'finderTags':False}
(root / 'library.json').write_text(json.dumps(library))
proc = None
if app.suffix == '.app':
    check(command('library','stats')['templates'] == 1, 'stopped built app launches via background CLI')
    pid = command('status')['pid']
else:
    proc = subprocess.Popen([str(exe), '--background','--data-directory',str(root)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pid = proc.pid
try:
    for _ in range(100):
        if (root / 'control.sock').exists(): break
        assert proc is None or proc.poll() is None, 'test app exited'; time.sleep(.1)
    check(command('status')['pid'] == pid, 'status targets disposable built app')
    check(command('library','stats')['templates'] == 1, 'library stats')
    check(command('project','list')['total'] == 0, 'project list empty')
    check(command('project','list','--limit','0',code=2)['error']['code'] == 'usage', 'CLI usage exit 2')
    created = command('project','create','--format','Short','--title','Socket test','--request-id','create-1')
    check(pathlib.Path(created['path']).is_dir(), 'project create writes folder and durable record')
    check(command('project','create','--format','Short','--title','Socket test','--request-id','create-1')['id'] == created['id'], 'create session idempotency')
    ref = created['id']
    check(command('project','list','--format','Short','--search','Socket','--limit','1')['returned'] == 1, 'project list filters and pagination')
    check(command('project','list','--offset','1')['returned'] == 0, 'project list offset')
    check(command('project','status',ref)['available'], 'project status resolves UUID and availability')
    check(command('project','status',created['number'],'--format','Short')['id'] == ref, 'project status resolves number')
    check(command('project','status',created['name'])['id'] == ref, 'project status resolves exact name')
    check(command('project','open',ref)['selected'], 'project open selects GUI store')
    state = command('status')
    check(state['selectedProject']['id'] == ref and state['page'] == 'Projects', 'CLI create selection is visible in main-actor GUI state')
    check(command('project','reveal','missing',code=1)['error']['code'] == 'not_found', 'project reveal error route without opening Finder')
    if any(tool['name'] == 'project_rename' for tool in json.loads(subprocess.check_output([str(cli),'mcp-manifest']))['tools']):
        preview = command('project','rename',ref,'--title','Renamed test','--dry-run')
        check(preview['dryRun'] and pathlib.Path(created['path']).exists(), 'rename dry-run changes nothing')
        renamed = command('project','rename',ref,'--title','Renamed test','--request-id','rename-1')
        check(pathlib.Path(renamed['newPath']).is_dir() and not pathlib.Path(created['path']).exists(), 'rename updates disk and record')
        check(command('project','rename',ref,'--title','Renamed test','--request-id','rename-1')['newPath'] == renamed['newPath'], 'rename session idempotency')
        check(command('status')['selectedProject']['name'] == renamed['newName'], 'CLI rename updates GUI selection name')
    manifest = json.loads(subprocess.check_output([str(cli),'mcp-manifest']))
    check(len(manifest['tools']) >= 7, 'mcp-manifest from command table')
    for tool in manifest['tools']:
        words = tool['name'].split('_')
        text = subprocess.check_output([str(cli), *words, '--help'], text=True)
        check('Example:' in text and 'request-id' in text, 'complete help for '+tool['name'])
    env = dict(os.environ, MCP_CLI=str(cli), CREATOROS_DATA_DIRECTORY=str(root))
    requests = [
        {'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-06-18'}},
        {'jsonrpc':'2.0','method':'notifications/initialized'},
        {'jsonrpc':'2.0','id':2,'method':'tools/list'},
        {'jsonrpc':'2.0','id':3,'method':'ping'},
        {'jsonrpc':'2.0','id':4,'method':'tools/call','params':{'name':'status','arguments':{}}},
        {'jsonrpc':'2.0','id':5,'method':'unknown'},
        {'jsonrpc':'2.0','id':6,'method':'tools/call','params':{'name':'project_status','arguments':{'project':'missing'}}},
    ]
    mcp = subprocess.run(['node',str(shim)], input=''.join(json.dumps(r)+'\n' for r in requests), capture_output=True,text=True,env=env,timeout=30)
    check(mcp.returncode == 0, 'MCP starts with packaged manifest')
    replies = {r['id']:r for r in map(json.loads,mcp.stdout.splitlines())}
    check(replies[1]['result']['protocolVersion'] == '2025-06-18' and replies[2]['result']['tools'] == manifest['tools'] and replies[3]['result'] == {}, 'MCP initialize/list/ping')
    check(json.loads(replies[4]['result']['content'][0]['text'])['pid'] == pid, 'MCP forwards tools/call to built CLI')
    check(replies[5]['error']['code'] == -32601 and replies[6]['result']['isError'], 'MCP unknown methods and action failures')
    suite = 'local.creatoros.alpha.' + base64.b64encode(str(root).encode()).decode()
    format_before = subprocess.check_output(['/usr/bin/defaults','read',suite,'format'],text=True).strip()
    command('project','create','--format','Long','--title','Form preservation','--campaign','')
    check(subprocess.check_output(['/usr/bin/defaults','read',suite,'format'],text=True).strip() == format_before, 'CLI create restores saved New Project format')
    check(command('project','status',created['number'],code=1)['error']['code'] == 'ambiguous_project', 'project number ambiguity requires format or UUID')
    # Simultaneous create requests must never borrow each other's form values.
    def concurrent_create(title):
        response = subprocess.run([str(cli),'project','create','--format','Short','--title',title,'--request-id',title,'--json','--data-directory',str(root)],capture_output=True,text=True,timeout=30)
        result = json.loads(response.stdout)
        assert (response.returncode == 0 and result['name'].endswith(title)) or (response.returncode == 1 and result['error']['code'] == 'busy'), (title,result)
        return response.returncode
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(concurrent_create, ['Concurrent A','Concurrent B']))
    check(0 in results, 'concurrent create preserves each request or reports busy')
    # Block only this synthetic library's durable save: disk rename must roll back.
    if any(tool['name'] == 'project_rename' for tool in manifest['tools']):
        before = command('project','status',ref)
        selected_before = command('status')['selectedProject']
        saved_library = (root / 'library.json').read_bytes()
        (root / 'library.json').unlink(); (root / 'library.json').mkdir()
        try:
            failure = command('project','rename',ref,'--title','Save failure rollback',code=1)
            check('error' in failure and pathlib.Path(before['path']).is_dir(), 'rename library-save failure restores disk names')
            check(command('status')['selectedProject'] == selected_before, 'rename save failure retains GUI record')
        finally:
            (root / 'library.json').rmdir(); (root / 'library.json').write_bytes(saved_library)
    print('RESULT', checks, 'AI control checks passed; fixture',root)
finally:
    if proc is not None:
        proc.terminate(); proc.wait(timeout=10)
    else:
        state = command('status')
        assert state['pid'] == pid and state['dataRoot'] == str(root), state
        os.kill(pid, signal.SIGTERM)
