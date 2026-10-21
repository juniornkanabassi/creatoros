#!/usr/bin/env python3
"""Run every control command on synthetic data in the supplied build, with no input events."""
import instances
import base64, concurrent.futures, json, os, pathlib, signal, socket, subprocess, sys, tempfile, time, uuid
app = pathlib.Path(sys.argv[1]).resolve()
cli = app / 'Contents/MacOS/creatoros' if app.suffix == '.app' else app.parent / 'creatoros'
exe = app / 'Contents/MacOS/ProjectTemplates' if app.suffix == '.app' else app
shim = app / 'Contents/Resources/mcp/creatoros-mcp.mjs' if app.suffix == '.app' else pathlib.Path('mcp/creatoros-mcp.mjs').resolve()
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-ai-', dir='/private/tmp'))
checks = 0
roots = [root]  # every data directory this run launches an app for; all are swept at the end

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
    linked_cli = root / 'creatoros'
    linked_cli.symlink_to(cli)
    os.environ["PATH"] = str(root) + os.pathsep + os.environ["PATH"]
    cli = pathlib.Path("creatoros")
    check(command('library','stats')['templates'] == 1, 'stopped built app launches through CLI symlink')
    pid = command('status')['pid']
else:
    proc = subprocess.Popen([str(exe), '--background','--data-directory',str(root)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pid = proc.pid
try:
    for _ in range(100):
        if (root / 'control.sock').exists(): break
        assert proc is None or proc.poll() is None, 'test app exited'; time.sleep(.1)
    check(command('status')['pid'] == pid, 'status targets disposable built app')
    check(instances.pids(root) == [pid], 'exactly one test instance is alive')
    check(instances.activation_type(pid) in ('UIElement', 'BackgroundOnly'), 'the isolated test instance has no Dock tile (activation type %s)' % instances.activation_type(pid))
    if app.suffix == '.app':
        other_root = pathlib.Path(tempfile.mkdtemp(prefix='cos-ai-second-', dir='/private/tmp'))
        def other_command(*args):
            result = subprocess.run([str(cli), *args, '--json', '--data-directory', str(other_root)], capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, (args, result.stdout, result.stderr)
            return json.loads(result.stdout)
        other_command('library','stats')
        other_state = other_command('status')
        check(other_state['isolated'] and other_state['dataRoot'] == str(other_root) and other_state['pid'] != pid, 'separate isolated launch starts beside existing instance')
        roots.append(other_root)
        instances.quit_all(other_root)  # the deliberate second instance goes at once
        check(not instances.pids(other_root) and len(instances.pids(root)) == 1, 'the second isolated instance is gone and exactly one test instance is alive')
    check(command('library','stats')['templates'] == 1, 'library stats')
    check(command('project','list')['total'] == 0, 'project list empty')
    check(command('project','list','--limit','0',code=2)['error']['code'] == 'usage', 'CLI usage exit 2')
    created = command('project','create','--format','Short','--title','Socket test','--campaign','Temporary campaign','--request-id','create-1')
    check(pathlib.Path(created['path']).is_dir(), 'project create writes folder and durable record')
    check(command('project','create','--format','Short','--title','Socket test','--campaign','Temporary campaign','--request-id','create-1')['id'] == created['id'], 'create session idempotency')
    check(command('project','create','--format','Short','--title','Different','--request-id','create-1',code=1)['error']['code'] == 'invalid_params', 'reused create id rejects changed parameters')
    next_created = command('project','create','--format','Short','--title','Next socket test')
    check(next_created['number'] == '002', 'CLI create advances saved automatic number in same format')
    ref = created['id']
    check(command('project','list','--format','Short','--search','Socket','--limit','1')['returned'] == 1, 'project list filters and pagination')
    check(command('project','list','--offset','2')['returned'] == 0, 'project list offset')
    check(command('project','status',ref)['available'], 'project status resolves UUID and availability')
    check(command('project','status',created['number'],'--format','Short')['id'] == ref, 'project status resolves number')
    check(command('project','status',created['name'])['id'] == ref, 'project status resolves exact name')
    check(command('project','open',ref)['selected'], 'project open selects GUI store')
    state = command('status')
    check(state['selectedProject']['id'] == ref and state['page'] == 'Projects', 'CLI create selection is visible in main-actor GUI state')
    check(command('project','reveal','missing',code=1)['error']['code'] == 'not_found', 'project reveal error route without opening Finder')
    manifest = json.loads(subprocess.check_output([str(cli),'mcp-manifest']))
    check(isinstance(manifest.get('version'), str), 'mcp-manifest carries the app version for the shim')
    if app.suffix == '.app':
        import plistlib
        check(manifest['version'] == plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'], 'the shim reports the bundle version, not a hard-coded one')
    preview = command('project','rename',ref,'--title','Renamed test','--dry-run','--request-id','rename-1')
    check(preview['dryRun'] and pathlib.Path(created['path']).exists(), 'rename dry-run changes nothing')
    renamed = command('project','rename',ref,'--title','Renamed test','--request-id','rename-1')
    check(pathlib.Path(renamed['newPath']).is_dir() and not pathlib.Path(created['path']).exists(), 'rename updates disk and record')
    check(command('project','rename',ref,'--title','Renamed test','--request-id','rename-1')['newPath'] == renamed['newPath'], 'rename session idempotency')
    check(command('project','rename',ref,'--title','Different','--request-id','rename-1',code=1)['error']['code'] == 'invalid_params', 'reused rename id rejects changed parameters')
    check(command('status')['selectedProject']['name'] == renamed['newName'], 'CLI rename updates GUI selection name')
    for tool in manifest['tools']:
        words = tool['_meta']['creatoros']['words']
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
        {'jsonrpc':'2.0','id':7,'method':'tools/call','params':{'name':'project_rename','arguments':{'project':ref,'campaign':''}}},
    ]
    mcp = subprocess.run(['node',str(shim)], input=''.join(json.dumps(r)+'\n' for r in requests), capture_output=True,text=True,env=env,timeout=30)
    check(mcp.returncode == 0, 'MCP starts with packaged manifest')
    replies = {r['id']:r for r in map(json.loads,mcp.stdout.splitlines())}
    check(replies[1]['result']['protocolVersion'] == '2025-06-18' and replies[2]['result']['tools'] == manifest['tools'] and replies[3]['result'] == {}, 'MCP initialize/list/ping')
    check(json.loads(replies[4]['result']['content'][0]['text'])['pid'] == pid, 'MCP forwards tools/call to built CLI')
    check(replies[5]['error']['code'] == -32601 and replies[6]['result']['isError'], 'MCP unknown methods and action failures')
    check(not replies[7]['result'].get('isError') and command('project','status',ref)['campaign'] is None, 'MCP rename clears an existing campaign')
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
    # ---- 1.5.0 CLI/MCP parity: every command, on synthetic data only ------------------------------------------------------
    import hashlib, re, shutil
    def lib():
        return json.loads((root / 'library.json').read_text())
    def digest():
        return hashlib.sha256((root / 'library.json').read_bytes()).hexdigest()
    def tree(path):
        found = {}
        for p in sorted(pathlib.Path(path).rglob('*')):
            if p.name == 'control.sock': continue
            found[str(p)] = p.stat().st_size if p.is_file() else -1
        return found
    def world():
        return (digest(), tree(root))
    def error(*args, code=1):
        result = command(*args, code=code)
        assert 'error' in result, (args, result)
        return result['error']
    def xattr_hex(path, name='com.apple.FinderInfo'):
        out = subprocess.run(['/usr/bin/xattr', '-px', name, str(path)], capture_output=True, text=True)
        return None if out.returncode else bytes.fromhex(out.stdout.replace('\n', '').replace(' ', ''))
    def has_icon_flag(path):
        info = xattr_hex(path)
        return bool(info and len(info) > 8 and info[8] & 4)
    def tag_names(path):
        raw = subprocess.run(['/usr/bin/xattr', '-px', 'com.apple.metadata:_kMDItemUserTags', str(path)], capture_output=True, text=True)
        if raw.returncode: return []
        import plistlib
        return [t.split('\n')[0] for t in plistlib.loads(bytes.fromhex(raw.stdout.replace('\n', '').replace(' ', '')))]
    def P(path):
        return str(path).replace('/private/tmp', '/tmp')  # the engine reports /tmp spellings of the same folders
    def record_on_disk(ref):
        return next(p for p in lib()['projects'] if p['id'].lower() == ref.lower())

    # -- contract: manifest, routing, booleans, arrays ------------------------------------------------------------------
    names = [t['name'] for t in manifest['tools']]
    check(len(names) == len(set(names)) and all(re.fullmatch(r'[A-Za-z0-9_-]{1,64}', n) for n in names), 'every MCP tool name is unique and valid')
    check({'status','library_stats','project_list','project_status','project_open','project_reveal','project_create','project_rename'} <= set(names), 'the eight shipped tools are still present')
    by_name = {t['name']: t for t in manifest['tools']}
    check(by_name['project_set_stage']['_meta']['creatoros']['words'] == ['project', 'set-stage'] and by_name['project_set_stage']['_meta']['creatoros']['action'] == 'project.set-stage', 'manifest carries the exact CLI words for hyphenated commands')
    check(by_name['stage_set']['inputSchema']['properties']['stages']['type'] == 'array' and by_name['project_create']['inputSchema']['properties']['extra']['type'] == 'object', 'manifest declares array and object parameters')
    check(len(names) >= 59, 'manifest lists every GUI action as a tool (%d tools)' % len(names))
    check(subprocess.check_output([str(cli), '--version'], text=True).strip() != '', 'creatoros --version prints a version')
    anywhere = subprocess.run([str(cli), 'status', '--version', '--json', '--data-directory', str(root)], capture_output=True, text=True)
    check(anywhere.returncode == 0 and json.loads(anywhere.stdout)['version'] == subprocess.check_output([str(cli), '--version'], text=True).strip(), '--version works as a global flag after other words')
    check(command('project', 'status', 'nothing-here', code=1)['error']['code'] == 'not_found', 'positional reference routes through the declared parameter')
    check(command('stage', 'list', 'extra-word', code=2)['error']['code'] == 'usage', 'a bare word is refused where no positional is declared')
    check(command('stage', 'set', '--board', 'recordings', '--stages', 'not json', code=2)['error']['code'] == 'usage', 'an array flag must be JSON')
    check(command('project', 'create', '--format', 'Short', code=2)['error']['code'] == 'usage', 'conditional validation: format without title is a usage error')

    # -- ideas, pipeline fields, stages, pins ---------------------------------------------------------------------------
    before = world()
    idea = command('idea', 'add', '--title', 'Parity idea', '--format', 'Short', '--campaign', 'Euro', '--notes', 'First note', '--request-id', 'idea-1')
    check(idea['idea'] and idea['campaign'] == 'Euro' and idea['notes'] == 'First note' and idea['stage'] == 'Idea', 'idea add returns the new record read back')
    check(record_on_disk(idea['id'])['planned'] and record_on_disk(idea['id'])['name'] == 'Parity idea', 'idea add is on disk when the CLI returns')
    count = len(lib()['projects'])
    check(command('idea', 'add', '--title', 'Parity idea', '--format', 'Short', '--campaign', 'Euro', '--notes', 'First note', '--request-id', 'idea-1')['id'] == idea['id'] and len(lib()['projects']) == count, 'idea add retry with the same request id acts once')
    check(error('idea', 'add', '--title', 'Live idea', '--format', 'Livestream')['code'] == 'invalid_params', 'idea add refuses a live stream')
    check(error('idea', 'add', '--title', 'Bad', '--format', 'Nope')['code'] == 'invalid_params', 'idea add refuses an unknown format')
    ideas = command('project', 'list', '--include-ideas', '--search', 'Parity idea')
    check(ideas['returned'] == 1 and ideas['projects'][0]['idea'], 'idea appears in project list with idea flag')

    alpha = command('project', 'create', '--format', 'Short', '--title', 'Alpha parity', '--request-id', 'alpha-1')
    beta = command('project', 'create', '--format', 'Short', '--title', 'Beta parity', '--request-id', 'beta-1')
    check(command('project', 'pin', alpha['id'])['pinned'] and record_on_disk(alpha['id']).get('pinned') is True, 'project pin is read back and on disk')
    check(command('project', 'pin', alpha['id'])['pinned'], 'project pin is idempotent')
    check(not command('project', 'unpin', alpha['id'])['pinned'] and not record_on_disk(alpha['id']).get('pinned'), 'project unpin is read back and on disk')
    check(not command('project', 'unpin', alpha['id'])['pinned'], 'project unpin is idempotent')
    check(error('project', 'pin', 'missing-project')['code'] == 'not_found', 'project pin validation error')

    moved = command('project', 'set-stage', alpha['id'], '--stage', 'Editing')
    check(moved['stage'] == 'Editing' and moved['finderTag'] == 'skipped' and record_on_disk(alpha['id'])['stage'] == 'Editing', 'set-stage is read back and on disk (tags off: skipped)')
    check(error('project', 'set-stage', alpha['id'], '--stage', 'Streamed')['code'] == 'invalid_stage', 'set-stage refuses a stage from the live board')
    check(command('project', 'status', alpha['id'])['stage'] == 'Editing', 'a refused stage change leaves the stage alone')
    idea_moved = command('project', 'set-stage', idea['id'], '--stage', 'Writing')
    check(idea_moved['idea'] and idea_moved['stage'] == 'Writing', 'set-stage works for ideas')
    check(command('settings', 'finder-tags', '--enabled')['finderTags'] is True and lib()['finderTags'] is True, 'finder-tags --enabled is on disk')
    born = command('project', 'create', '--format', 'Short', '--title', 'Tagged at birth')
    check(born['finderTag'] == 'applied' and tag_names(born['path']) == [born['stage']], 'project create waits for its Finder tag and reports finderTag')
    tagged = command('project', 'set-stage', alpha['id'], '--stage', 'Published')
    check(tagged['finderTag'] == 'applied' and tag_names(alpha['path']) == ['Published'], 'set-stage writes the Finder tag before replying')
    for stage in ['Writing', 'Editing', 'Filming', 'Published', 'Writing']: command('project', 'set-stage', alpha['id'], '--stage', stage)
    check(tag_names(alpha['path']) == ['Writing'], 'rapid stage changes leave the last stage as the Finder tag')
    live = command('project', 'create', '--format', 'Livestream', '--title', 'Parity stream')
    check(live['stage'] == 'Scheduled' and error('project', 'set-stage', live['id'], '--stage', 'Editing')['code'] == 'invalid_stage', 'a live stream refuses a recordings stage')
    check(command('project', 'set-stage', live['id'], '--stage', 'Streamed')['stage'] == 'Streamed', 'a live stream takes a live stage')
    check(command('settings', 'finder-tags', '--no-enabled')['finderTags'] is False and lib()['finderTags'] is False, 'finder-tags --no-enabled turns tags off (explicit false)')
    check(command('project', 'create', '--format', 'Short', '--title', 'Untagged at birth')['finderTag'] == 'skipped', 'project create reports finderTag skipped while tags are off')

    updated = command('project', 'update', alpha['id'], '--campaign', 'Cup', '--editor', 'Jon', '--notes', 'Cut the intro', '--series', 'Euro 2026, Finals')
    check((updated['campaign'], updated['editor'], updated['notes'], updated['series']) == ('Cup', 'Jon', 'Cut the intro', ['Euro 2026', 'Finals']), 'project update is read back')
    disk = record_on_disk(alpha['id'])
    check((disk['campaign'], disk['editor'], disk['notes'], disk['series']) == ('Cup', 'Jon', 'Cut the intro', ['Euro 2026', 'Finals']), 'project update is on disk when the CLI returns')
    cleared = command('project', 'update', alpha['id'], '--editor', '', '--series', '')
    check(cleared['editor'] is None and cleared['series'] == [] and cleared['campaign'] == 'Cup' and 'editor' not in record_on_disk(alpha['id']), 'an empty value clears one field and leaves the others')
    check(error('project', 'update', alpha['id'])['code'] == 'invalid_params', 'project update with nothing to change is refused')
    check(command('project', 'status', alpha['id'])['notes'] == 'Cut the intro', 'project status shows editor, series and notes fields')

    listing = command('stage', 'list')
    recordings = next(b for b in listing['boards'] if b['board'] == 'recordings')
    check([s['name'] for s in recordings['stages']] == ['Idea', 'Writing', 'Filming', 'Editing', 'Published', 'Abandoned'] and any(s['colour'] == 'green' for s in recordings['stages']), 'stage list shows both boards with colours')
    check(sum(s['count'] for s in recordings['stages']) >= 3, 'stage list counts records')
    before = world()
    dry = command('stage', 'set', '--board', 'recordings', '--stages', json.dumps(['Idea', 'Plan, draft', 'Editing', 'Published', 'Abandoned']), '--dry-run')
    check(dry['dryRun'] and any(o['stage'] == 'Writing' for o in dry['orphaned']) and world() == before, 'stage set dry-run reports records left on orphaned stages and changes nothing')
    check(error('stage', 'set', '--board', 'recordings', '--stages', json.dumps(['Only']))['code'] == 'invalid_params', 'stage set refuses fewer than two stages')
    check(error('stage', 'set', '--board', 'nowhere', '--stages', json.dumps(['A', 'B']))['code'] == 'invalid_params', 'stage set refuses an unknown board')
    done = command('stage', 'set', '--board', 'recordings', '--stages', json.dumps(['Idea', 'Plan, draft', 'Writing', 'Filming', 'Editing', 'Published', 'Abandoned']))
    check('Plan, draft' in done['stages'] and 'Plan, draft' in lib()['stages'], 'stage set keeps a stage name that contains a comma, on disk')
    check(command('project', 'set-stage', beta['id'], '--stage', 'Plan, draft')['stage'] == 'Plan, draft', 'a comma stage name works end to end')
    command('stage', 'set', '--board', 'recordings', '--stages', json.dumps(['Idea', 'Writing', 'Filming', 'Editing', 'Published', 'Abandoned']))
    check(command('project', 'status', beta['id'])['stage'] == 'Plan, draft', 'a record on a removed stage keeps it (orphan preserved)')
    check(command('stage', 'set-colour', '--stage', 'Editing', '--colour', 'purple')['colour'] == 'purple' and lib()['stageColours']['Editing'] == 'purple', 'stage set-colour is on disk')
    check(error('stage', 'set-colour', '--stage', 'Editing', '--colour', 'mauve')['code'] == 'invalid_params', 'stage set-colour validates the colour')
    check(error('stage', 'set-colour', '--stage', 'Nowhere', '--colour', 'red')['code'] == 'invalid_stage', 'stage set-colour validates the stage')
    command('project', 'set-stage', beta['id'], '--stage', 'Editing'); command('project', 'set-stage', alpha['id'], '--stage', 'Editing')
    before = world()
    preview = command('stage', 'move-all', '--from', 'Editing', '--to', 'Published', '--board', 'recordings', '--dry-run')
    check(preview['dryRun'] and preview['count'] == 2 and world() == before, 'move-all dry-run counts the records and changes nothing')
    moved_all = command('stage', 'move-all', '--from', 'Editing', '--to', 'Published', '--board', 'recordings')
    check(moved_all['moved'] == 2 and record_on_disk(alpha['id'])['stage'] == 'Published' and record_on_disk(beta['id'])['stage'] == 'Published', 'move-all is on disk')
    check(error('stage', 'move-all', '--from', 'Published', '--to', 'Streamed', '--board', 'recordings')['code'] == 'invalid_stage', 'move-all refuses a stage from the other board')
    check(error('stage', 'move-all', '--from', 'Abandoned', '--to', 'Idea')['code'] == 'ambiguous_board', 'move-all asks for --board when a stage is on both boards')

    # -- fields and formats ---------------------------------------------------------------------------------------------
    field = command('field', 'add', '--name', 'Sponsor', '--exclude-from-name', '--request-id', 'field-1')
    check(field['name'] == 'Sponsor' and field['includeInName'] is False and lib()['customFields'][0]['name'] == 'Sponsor', 'field add is read back and on disk')
    count = len(lib()['customFields'])
    check(command('field', 'add', '--name', 'Sponsor', '--exclude-from-name', '--request-id', 'field-1')['id'] == field['id'] and len(lib()['customFields']) == count, 'field add retry acts once')
    check(error('field', 'add', '--name', 'sponsor')['code'] == 'invalid_params', 'field add refuses a duplicate name')
    check(command('field', 'list')['fields'][0]['id'] == field['id'], 'field list')
    check(command('field', 'update', 'Sponsor', '--name', 'Client', '--include-in-name')['includeInName'] is True, 'field update renames and sets in-name')
    check(command('field', 'update', field['id'], '--no-include-in-name')['includeInName'] is False, 'field update accepts --no-include-in-name')
    check(error('field', 'update', 'Nothing', '--name', 'X')['code'] == 'not_found', 'field update validation error')
    extra = command('project', 'create', '--format', 'Short', '--title', 'Extra parity', '--extra', json.dumps({'Client': 'Acme'}), '--dry-run')
    check(extra['dryRun'] and extra['ready'] and extra['folderName'].endswith('Extra parity') and 'compatibility' in extra, 'create dry-run returns the rendered name, readiness and compatibility')
    check(error('project', 'create', '--format', 'Short', '--title', 'Extra', '--extra', json.dumps({'Nope': 'x'}))['code'] == 'invalid_params', 'create --extra validates field names')
    before = world()
    removed_dry = command('field', 'remove', 'Client', '--dry-run')
    check(removed_dry['dryRun'] and world() == before, 'field remove dry-run changes nothing')
    command('field', 'remove', 'Client')
    check(lib().get('customFields') == [] and command('field', 'list')['fields'] == [], 'field remove is on disk')

    formats_list = command('format', 'list')['formats']
    check([f['format'] for f in formats_list] == formats and all('hasIcon' in f and 'ready' in f for f in formats_list), 'format list')
    dest = root / 'NewDest' / 'Short'; dest.mkdir(parents=True)
    set_dest = command('format', 'set-destination', '--format', 'Short', '--path', str(dest))
    check(set_dest['destination'] == str(dest) and next(p for p in lib()['presets'] if p['format'] == 'Short')['destination'] == str(dest), 'format set-destination is on disk')
    stat_before = digest()
    check(error('format', 'set-destination', '--format', 'Short', '--path', '/private/tmp')['code'] == 'not_allowed' and digest() == stat_before, 'format set-destination refuses a folder outside the isolated root')
    check(error('format', 'set-destination', '--format', 'Short', '--path', 'relative')['code'] == 'invalid_params', 'format set-destination wants an absolute path')
    one_off = root / 'OneOff'; one_off.mkdir()
    off = command('project', 'create', '--format', 'Short', '--title', 'Elsewhere', '--destination', str(one_off))
    check(P(pathlib.Path(off['path']).parent) == P(one_off) and next(p for p in lib()['presets'] if p['format'] == 'Short')['destination'] == str(dest), 'create --destination is one-off and does not change the saved destination')
    command('format', 'set-destination', '--format', 'Short', '--path', str(root / 'Projects' / 'Short'))
    import struct, zlib
    def png():
        def chunk(kind, data): return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
        return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 8, 8, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b''.join(b'\x00' + b'\x7f\x20\xc0' * 8 for _ in range(8)))) + chunk(b'IEND', b'')
    (root / 'icon.png').write_bytes(png())
    icon_set = command('format', 'set-icon', '--format', 'Short', '--image', str(root / 'icon.png'))
    check(icon_set['hasIcon'] and icon_set['iconSource'] == str(root / 'icon.png') and next(p for p in lib()['presets'] if p['format'] == 'Short').get('icon'), 'format set-icon from an image is on disk')
    check(command('format', 'set-icon', '--format', 'Long', '--from-folder', str(root / 'Projects'))['hasIcon'], 'format set-icon from a folder icon')
    check(error('format', 'set-icon', '--format', 'Short', '--image', str(root / 'Projects'), code=1)['code'] in ('invalid_params',), 'format set-icon refuses a folder given as an image')
    check(command('format', 'set-icon', '--format', 'Short', code=2)['error']['code'] == 'usage', 'format set-icon needs an image or a folder')

    # -- templates and sets ---------------------------------------------------------------------------------------------
    tpl = root / 'Src' / 'IconTpl'
    (tpl / '03 Media').mkdir(parents=True); (tpl / '01 Documents').mkdir()
    (tpl / '01 Documents' / 'Template.md').write_text('# Template\n')
    (tpl / '03 Media' / 'Icon\r').write_bytes(b'icon-data')
    flag_hex = '00' * 8 + '04' + '00' * 23
    subprocess.run(['/usr/bin/xattr', '-wx', 'com.apple.FinderInfo', flag_hex, str(tpl / '03 Media')], check=True)
    before = world()
    scan = command('template', 'import', '--path', str(tpl), '--name', 'IconTpl', '--mode', 'full', '--dry-run')
    check(scan['dryRun'] and scan['entries'] >= 4 and scan['iconFiles'] == 1 and world() == before, 'template import dry-run returns the scan and changes nothing')
    check(error('template', 'import', '--path', str(tpl), '--name', 'Bad|name', '--mode', 'full')['code'] == 'invalid_params', 'template import validates the name')
    check(error('template', 'import', '--path', str(tpl), '--name', 'X', '--mode', 'full', '--set', 'Nope', '--format', 'Short')['code'] == 'not_found', 'template import validates the set')
    imported = command('template', 'import', '--path', str(tpl), '--name', 'IconTpl', '--mode', 'full', '--request-id', 'tpl-1')
    check(pathlib.Path(imported['payload']).is_dir() and any(t['id'] == imported['id'] for t in lib()['templates']), 'template import registers the payload and is on disk')
    templates_before = len(lib()['templates'])
    check(command('template', 'import', '--path', str(tpl), '--name', 'IconTpl', '--mode', 'full', '--request-id', 'tpl-1')['id'] == imported['id'] and len(lib()['templates']) == templates_before, 'template import retry acts once')
    listed = command('template', 'list')
    check(any(t['name'] == 'IconTpl' for t in listed['templates']) and listed['sets'] == [], 'template list')
    files = command('template', 'files', 'IconTpl')
    check([i['name'] for i in files['items']] == ['01 Documents', '03 Media'], 'template files lists the payload without Icon files')
    check(command('template', 'files', 'IconTpl', '--path', '03 Media')['total'] == 0, 'template files hides the Icon file inside folders')
    check(error('template', 'files', 'Nope')['code'] == 'not_found', 'template files validation error')
    made = command('set', 'create', '--name', 'IconSet', '--from-template', 'IconTpl', '--request-id', 'set-1')
    check(set(made['variants']) == set(formats) and any(s['name'] == 'IconSet' for s in lib()['templateSets']), 'set create maps every format and is on disk')
    sets_before = len(lib()['templateSets'])
    check(command('set', 'create', '--name', 'IconSet', '--from-template', 'IconTpl', '--request-id', 'set-1')['id'] == made['id'] and len(lib()['templateSets']) == sets_before, 'set create retry acts once')
    check(error('set', 'create', '--name', 'iconset')['code'] == 'invalid_params', 'set create refuses a duplicate name')
    check(command('set', 'rename', 'IconSet', '--name', 'Icons')['name'] == 'Icons', 'set rename')
    check('Short' not in command('set', 'unassign', 'Icons', '--format', 'Short')['variants'], 'set unassign')
    check(command('set', 'assign', 'Icons', '--format', 'Short', '--template', 'IconTpl')['variants']['Short']['template'] == 'IconTpl', 'set assign')
    check(error('set', 'assign', 'Icons', '--format', 'Nope', '--template', 'IconTpl')['code'] == 'invalid_params', 'set assign validates the format')
    check(error('set', 'rename', 'Missing', '--name', 'X')['code'] == 'not_found', 'set rename validation error')
    extra_set = command('set', 'create', '--name', 'Spare')
    before = world()
    check(command('set', 'remove', 'Spare', '--dry-run')['dryRun'] and world() == before, 'set remove dry-run changes nothing')
    check(command('set', 'remove', 'Spare')['templatesKept'] and all(s['name'] != 'Spare' for s in lib()['templateSets']), 'set remove is on disk and keeps templates')

    # -- icons: strip, restore, inheritance, partial failure -------------------------------------------------------------
    iconic = command('project', 'create', '--format', 'Short', '--title', 'Iconic', '--template', 'Icons')
    iproj = pathlib.Path(iconic['path'])
    check((iproj / '03 Media' / 'Icon\r').exists() and has_icon_flag(iproj / '03 Media'), 'fixture project carries the template folder icon')
    (iproj / '06 Media Revised').mkdir(); (iproj / '06 Media Revised' / 'take.mov').write_bytes(b'clip')
    (iproj / '07 Unrelated').mkdir()
    before = world()
    strip_dry = command('project', 'icons-strip', iconic['id'], '--dry-run')
    check(strip_dry['dryRun'] and strip_dry['iconFiles'] == 2 and (iproj / '03 Media' / 'Icon\r').exists() and world() == before and has_icon_flag(iproj / '03 Media'), 'icons-strip dry-run lists the icon files and touches nothing')
    stripped = command('project', 'icons-strip', iconic['id'])
    check(stripped['iconFilesRemoved'] == 2 and not (iproj / '03 Media' / 'Icon\r').exists() and not has_icon_flag(iproj / '03 Media') and not stripped['failed'], 'icons-strip removes the icon file and the folder flag')
    before = world()
    restore_dry = command('project', 'icons-restore', iconic['id'], '--dry-run')
    check(restore_dry['dryRun'] and restore_dry['folders'] == ['03 Media'] and restore_dry['inherited'] == ['06 Media Revised'] and world() == before, 'icons-restore dry-run lists exact and inherited folders')
    check(restore_dry['candidates'][0]['available'] is True, 'icons-restore dry-run lists every candidate set with availability')
    restored = command('project', 'icons-restore', iconic['id'])
    check(restored['restored'] == ['03 Media'] and restored['inherited'] == ['06 Media Revised'] and not restored['failed'], 'icons-restore reports restored and inherited folders')
    check((iproj / '06 Media Revised' / 'Icon\r').exists() and has_icon_flag(iproj / '06 Media Revised') and has_icon_flag(iproj / '03 Media'), 'the inherited folder received the icon on disk')
    check((iproj / '06 Media Revised' / 'take.mov').read_bytes() == b'clip' and not (iproj / '07 Unrelated' / 'Icon\r').exists() and not has_icon_flag(iproj / '07 Unrelated'), 'inheriting touches no files and leaves unrelated folders alone')
    check(error('project', 'icons-restore', iconic['id'], '--set', 'Nope')['code'] == 'not_found', 'icons-restore validates the set name')
    command('set', 'create', '--name', 'Second', '--from-template', 'IconTpl')
    check(error('project', 'icons-restore', iconic['id'])['code'] == 'ambiguous_set', 'icons-restore with several sets asks for --set')
    check(command('project', 'icons-restore', iconic['id'], '--set', 'Icons', '--format-as', 'Short')['restored'] == ['03 Media'], 'icons-restore with --set and --format-as')
    # A stuck icon file: strip reports it and still clears the rest.
    stuck = iproj / '06 Media Revised' / 'Icon\r'
    subprocess.run(['/usr/bin/chflags', 'uchg', str(stuck)], check=True)
    try:
        partial = command('project', 'icons-strip', iconic['id'])
        check(partial['iconFilesRemoved'] == 2 and any('06 Media Revised' in f for f in partial['failed']) and not (iproj / '03 Media' / 'Icon\r').exists() and stuck.exists(), 'icons-strip reports a file it could not remove and still strips the rest')
    finally:
        subprocess.run(['/usr/bin/chflags', 'nouchg', str(stuck)])

    # -- relocate, find-moved, find-missing, remove ----------------------------------------------------------------------
    nomad = command('project', 'create', '--format', 'Short', '--title', 'Nomad')
    old_path = pathlib.Path(nomad['path'])
    new_home = root / 'Projects' / 'Short' / 'Archive'; new_home.mkdir()
    new_path = new_home / old_path.name
    shutil.move(str(old_path), str(new_path))
    check(command('project', 'status', nomad['id'])['available'] is False, 'a moved folder reads as unavailable')
    before = world()
    found_dry = command('project', 'find-moved', nomad['id'], '--dry-run')
    check(found_dry['dryRun'] and found_dry['result'] == 'wouldRelink' and P(found_dry['path']) == P(new_path) and world() == before, 'find-moved dry-run says what it would relink and changes nothing')
    found = command('project', 'find-moved', nomad['id'])
    check(found['result'] == 'relinked' and P(found['path']) == P(new_path) and found['available'] and P(record_on_disk(nomad['id'])['path']) == P(new_path), 'find-moved relinks the one safe match and is on disk')
    check(P(old_path) in [P(x) for x in record_on_disk(nomad['id'])['previousPaths']], 'find-moved keeps the old path in previousPaths')
    opener = command('project', 'create', '--format', 'Short', '--title', 'Opener')
    opener_old = pathlib.Path(opener['path']); opener_new_dir = root / 'Projects' / 'Short' / 'Archive4'; opener_new_dir.mkdir()
    shutil.move(str(opener_old), str(opener_new_dir / opener_old.name))
    opened = command('project', 'open', opener['id'])
    check(P(opened['path']) == P(opener_new_dir / opener_old.name) and P(record_on_disk(opener['id'])['path']) == P(opener_new_dir / opener_old.name), 'project open reports an automatic relink only once it is on disk')
    relo_target = root / 'Projects' / 'Short' / 'Relocated folder'; relo_target.mkdir()
    before = world()
    relo_dry = command('project', 'relocate', nomad['id'], '--path', str(relo_target), '--dry-run')
    check(relo_dry['dryRun'] and relo_dry['to'] == str(relo_target) and relo_dry['newName'] == 'Relocated folder' and relo_dry['warnings'] and world() == before, 'relocate dry-run shows from/to and the rename warning, and changes nothing')
    relo = command('project', 'relocate', nomad['id'], '--path', str(relo_target))
    check(relo['path'] == str(relo_target) and relo['name'] == 'Relocated folder' and record_on_disk(nomad['id'])['path'] == str(relo_target) and P(new_path) in [P(x) for x in relo['previousPaths']], 'relocate is read back and on disk')
    check(error('project', 'relocate', nomad['id'], '--path', str(root / 'missing'))['code'] == 'not_found', 'relocate refuses a folder that does not exist')
    check(error('project', 'relocate', nomad['id'], '--path', 'relative')['code'] == 'invalid_params', 'relocate wants an absolute path')
    check(error('project', 'relocate', nomad['id'], '--path', '/private/tmp')['code'] == 'not_allowed', 'relocate refuses a folder outside the isolated root')
    gone = command('project', 'create', '--format', 'Short', '--title', 'Gone missing')
    hidden_dir = root / 'Projects' / 'Short' / 'Archive2'; hidden_dir.mkdir()
    shutil.move(gone['path'], str(hidden_dir / pathlib.Path(gone['path']).name))
    before = world()
    missing_dry = command('library', 'find-missing', '--dry-run')
    check(missing_dry['dryRun'] and missing_dry['missing'] >= 1 and any(o['result'] == 'wouldRelink' and o['id'] == gone['id'] for o in missing_dry['outcomes']) and world() == before, 'find-missing dry-run reports candidates and changes nothing')
    missing = command('library', 'find-missing')
    check(any(o['result'] == 'relinked' and o['id'] == gone['id'] for o in missing['outcomes']) and P(record_on_disk(gone['id'])['path']) == P(hidden_dir / pathlib.Path(gone['path']).name), 'find-missing relinks and is on disk')
    check(command('project', 'refresh', gone['id'])['available'], 'project refresh re-reads the folder state')
    doomed = command('project', 'create', '--format', 'Short', '--title', 'Doomed')
    before = world()
    check(command('project', 'remove', doomed['id'], '--dry-run')['dryRun'] and world() == before, 'project remove dry-run changes nothing')
    check(command('project', 'remove', doomed['id'])['folderUntouched'] and pathlib.Path(doomed['path']).is_dir() and all(p['id'] != doomed['id'] for p in lib()['projects']), 'project remove forgets the record and leaves the folder')

    # -- idea workspaces, start from idea, merge --------------------------------------------------------------------------
    wsidea = command('idea', 'add', '--title', 'Workspace idea', '--format', 'Short', '--campaign', 'Kept', '--notes', 'Workspace notes')
    before = world()
    ws = command('idea', 'create-workspace', wsidea['id'], '--request-id', 'ws-1')
    check(ws['workspace']['state'] == 'ok' and pathlib.Path(ws['workspace']['path']).is_dir() and record_on_disk(wsidea['id'])['ideaWorkspace']['path'] == ws['workspace']['path'], 'idea create-workspace is read back and on disk')
    check(command('idea', 'create-workspace', wsidea['id'], '--request-id', 'ws-1')['workspace']['path'] == ws['workspace']['path'], 'idea create-workspace retry acts once')
    check(error('idea', 'create-workspace', wsidea['id'])['code'] == 'invalid_params', 'a second workspace for the same idea is refused')
    check(error('idea', 'remove', wsidea['id'])['code'] == 'workspace_review', 'idea remove with a workspace needs --trash-workspace')
    check(error('idea', 'merge', wsidea['id'], '--into', alpha['id'])['code'] == 'workspace_review', 'idea merge refuses an idea with a workspace')
    check(error('project', 'remove', wsidea['id'])['code'] == 'workspace_review', 'project remove refuses a record with a workspace')
    ws_dry = command('idea', 'remove', wsidea['id'], '--trash-workspace', '--dry-run')
    check(ws_dry['dryRun'] and ws_dry['wouldMoveToBin'] and pathlib.Path(ws['workspace']['path']).is_dir(), 'idea remove dry-run leaves the workspace')
    started = command('project', 'create', '--from-idea', wsidea['id'])
    check(started['id'] == wsidea['id'] and not started['idea'] and started['campaign'] == 'Kept' and started['notes'] == 'Workspace notes' and started['name'].endswith('Workspace idea'), 'create --from-idea keeps the idea identity, metadata and title')
    check(started['workspace'] and started['workspace']['state'] == 'ok' and pathlib.Path(started['path']).is_dir(), 'the promoted project still links its workspace')
    check(error('project', 'workspace-bin', started['id'])['code'] == 'confirmation_required', 'workspace-bin needs --confirm')
    before = world()
    bin_dry = command('project', 'workspace-bin', started['id'], '--confirm', '--dry-run')
    check(bin_dry['dryRun'] and pathlib.Path(ws['workspace']['path']).is_dir() and world() == before, 'workspace-bin dry-run changes nothing')
    detached = command('project', 'workspace-detach', started['id'])
    check(detached['workspace'] is None and pathlib.Path(ws['workspace']['path']).is_dir() and 'ideaWorkspace' not in record_on_disk(started['id']), 'workspace-detach keeps the folder and unlinks it, on disk')
    check(error('project', 'workspace-detach', started['id'])['code'] == 'invalid_params', 'workspace-detach with no workspace is refused')
    bin_idea = command('idea', 'add', '--title', 'Binned idea', '--format', 'Short')
    bin_ws = command('idea', 'create-workspace', bin_idea['id'])
    promoted = command('project', 'create', '--from-idea', bin_idea['id'], '--title', 'Binned project')
    check(promoted['id'] == bin_idea['id'] and promoted['name'].endswith('Binned project'), 'create --from-idea accepts a different title')
    binned = command('project', 'workspace-bin', promoted['id'], '--confirm')
    check(binned['workspace'] is None and not pathlib.Path(bin_ws['workspace']['path']).exists() and binned['binPath'], 'workspace-bin moves the workspace to the Bin, never deletes it')
    check(error('project', 'create', '--from-idea', started['id'])['code'] == 'invalid_params', 'create --from-idea refuses a record that is already a project')
    check(error('project', 'create', '--from-idea', 'Parity idea', '--format', 'Long')['code'] == 'invalid_params', 'create --from-idea refuses a mismatched --format')
    plain_idea = command('idea', 'add', '--title', 'Plain idea', '--format', 'Short')
    plain_started = command('project', 'create', '--from-idea', plain_idea['id'], '--plain-folders')
    check(plain_started['id'] == plain_idea['id'] and plain_started['workspace'] is None, 'create --from-idea without a workspace')
    with_icons = command('project', 'create', '--format', 'Short', '--title', 'Plain override', '--template', 'Icons', '--plain-folders')
    check(not (pathlib.Path(with_icons['path']) / '03 Media' / 'Icon\r').exists(), 'create --plain-folders leaves the icon files out')
    explicit_false = command('project', 'create', '--format', 'Short', '--title', 'Icons forced', '--template', 'Icons', '--no-plain-folders')
    check((pathlib.Path(explicit_false['path']) / '03 Media' / 'Icon\r').exists(), 'create --no-plain-folders sends an explicit false and keeps the icons')

    files_idea = command('idea', 'add', '--title', 'Files idea', '--format', 'Short')
    check(error('project', 'files', files_idea['id'])['code'] == 'invalid_params' and error('project', 'reveal', files_idea['id'])['code'] == 'invalid_params', 'an idea without a workspace is refused with a clear code, not location_hidden')
    files_ws = pathlib.Path(command('idea', 'create-workspace', files_idea['id'])['workspace']['path'])
    (files_ws / 'Notes.md').write_text('notes')
    ws_listing = command('project', 'files', files_idea['id'])
    check([i['name'] for i in ws_listing['items']] == ['Notes.md'], 'project files lists an idea workspace through the browser engine (marker hidden)')
    (root / 'IdeaDonor.txt').write_text('donor')
    command('project', 'add-files', files_idea['id'], '--from', str(root / 'IdeaDonor.txt'), '--copy')
    check((files_ws / 'IdeaDonor.txt').read_text() == 'donor' and (root / 'IdeaDonor.txt').exists(), 'add-files drops a file into an idea workspace')
    check(error('project', 'open-file', files_idea['id'], '--path', 'missing.md')['code'] != 'location_hidden', 'open-file reaches an idea workspace')
    check(error('project', 'files', files_idea['id'], '--path', '../x')['code'] == 'invalid_params', 'an idea workspace listing refuses a path that leaves it')
    merge_idea = command('idea', 'add', '--title', 'Merge me', '--format', 'Short', '--campaign', 'FromIdea', '--notes', 'Idea notes')
    command('project', 'update', beta['id'], '--notes', 'Project notes', '--campaign', '')
    before = world()
    merge_dry = command('idea', 'merge', merge_idea['id'], '--into', beta['id'], '--dry-run')
    check(merge_dry['dryRun'] and {c['field'] for c in merge_dry['changes']} == {'campaign', 'notes'} and world() == before, 'idea merge dry-run lists the field changes and changes nothing')
    merged = command('idea', 'merge', merge_idea['id'], '--into', beta['id'])
    check(merged['campaign'] == 'FromIdea' and merged['notes'] == 'Project notes\n\nIdea notes' and all(p['id'] != merge_idea['id'] for p in lib()['projects']), 'idea merge fills empty fields, joins notes and removes the idea, on disk')
    check(error('idea', 'merge', alpha['id'], '--into', beta['id'])['code'] == 'invalid_params', 'idea merge needs an idea as the source')
    check(error('idea', 'merge', idea['id'], '--into', 'Parity idea')['code'] == 'invalid_params', 'idea merge needs a project as the target')
    before = world()
    check(command('idea', 'remove', idea['id'], '--dry-run')['dryRun'] and world() == before, 'idea remove dry-run changes nothing')
    check(command('idea', 'remove', idea['id'])['removed']['id'] == idea['id'] and all(p['id'] != idea['id'] for p in lib()['projects']), 'idea remove is on disk')

    # -- project files, documents, add-files -----------------------------------------------------------------------------
    (iproj / '01 Documents' / 'Script.md').write_text('# Script\n')
    (iproj / '02 Project Files').mkdir(exist_ok=True); (iproj / '02 Project Files' / 'cut.prproj').write_bytes(b'prproj')
    listing = command('project', 'files', iconic['id'])
    check('01 Documents' in [i['name'] for i in listing['items']] and all(i['name'] != 'Icon\r' for i in listing['items']), 'project files lists the root without icon files')
    sub = command('project', 'files', iconic['id'], '--path', '01 Documents')
    check([i['name'] for i in sub['items']] == [i['name'] for i in sub['items']] and any(i['name'] == 'Script.md' for i in sub['items']), 'project files lists a sub folder')
    check(error('project', 'files', iconic['id'], '--path', '../etc')['code'] == 'invalid_params', 'project files refuses a path that leaves the project')
    check(error('project', 'open-file', iconic['id'], '--path', '01 Documents/missing.md')['code'] in ('invalid_params', 'action_failed', 'not_found'), 'project open-file validates the path')
    check(error('project', 'open-file', iconic['id'], '--path', '01 Documents/missing.md', '--show')['code'] != 'usage' and command('stage', 'list', '--show')['boards'], '--show is accepted globally: declared where something opens, ignored elsewhere')
    check(command('stage', 'list', '--no-show')['boards'] and command('status', '--no-show')['pid'] == pid, '--no-show is accepted globally and ignored where nothing shows')
    check(by_name['project_open_file']['inputSchema']['properties']['show']['type'] == 'boolean' and by_name['project_open_premiere']['inputSchema']['properties']['show']['type'] == 'boolean', 'open-file and open-premiere declare show in their MCP schema')
    candidates = command('project', 'open-premiere', iconic['id'])
    check(candidates['candidates'] == ['02 Project Files/cut.prproj'], 'project open-premiere returns the candidates')
    check(error('project', 'open-premiere', iconic['id'], '--file', '01 Documents/Script.md')['code'] == 'invalid_params', 'project open-premiere refuses a document that is not a Premiere project')
    donor = root / 'Donor'; donor.mkdir(); (donor / 'clip.mov').write_bytes(b'moov')
    before = world()
    add_dry = command('project', 'add-files', iconic['id'], '--from', str(donor / 'clip.mov'), '--to', '03 Media', '--copy', '--dry-run')
    check(add_dry['dryRun'] and add_dry['valid'] and world() == before, 'add-files dry-run validates and changes nothing')
    added = command('project', 'add-files', iconic['id'], '--from', str(donor / 'clip.mov'), '--to', '03 Media', '--copy')
    check((iproj / '03 Media' / 'clip.mov').read_bytes() == b'moov' and (donor / 'clip.mov').exists() and not added['movedFromSource'], 'add-files --copy copies into the project and keeps the original')
    check(error('project', 'add-files', iconic['id'], '--from', str(donor / 'clip.mov'), '--to', '03 Media', '--copy')['code'] in ('action_failed', 'invalid_params'), 'add-files never overwrites an existing name')
    (donor / 'move.mov').write_bytes(b'move')
    moved_in = command('project', 'add-files', iconic['id'], '--from', str(donor / 'move.mov'), '--to', '03 Media')
    check((iproj / '03 Media' / 'move.mov').exists() and not (donor / 'move.mov').exists() and moved_in['movedFromSource'], 'add-files moves on the same volume')
    check(error('project', 'add-files', iconic['id'], '--from', str(donor / 'missing.mov'))['code'] == 'not_found', 'add-files validates the source')

    # -- locations, discovery, duplicates, compatibility, tags --------------------------------------------------------------
    locs = command('location', 'list')
    check(any(l['key'] == 'local' and l['projects'] > 5 and l['hidden'] is False for l in locs['locations']) and locs['saved'] == [], 'location list shows keys, counts and hidden state')
    check(command('location', 'set', 'local', '--colour', 'orange')['colour'] == 'orange', 'location set colour')
    check(error('location', 'set', 'local', '--colour', 'mauve')['code'] == 'invalid_params', 'location set validates the colour')
    check(error('location', 'set', 'volume:Nope', '--hidden')['code'] == 'not_found', 'location set validates the key')
    hidden_before = digest()
    hid_idea = command('idea', 'add', '--title', 'Hidden workspace idea', '--format', 'Short')
    hid_ws = command('idea', 'create-workspace', hid_idea['id'], '--request-id', 'ws-hidden')
    cached_dir = root / 'Stray3' / '710 — Short — Cached'; cached_dir.mkdir(parents=True)
    cached = command('project', 'register', '--path', str(cached_dir), '--request-id', 'reg-hidden')
    hidden_before = digest()
    check(command('location', 'set', 'local', '--hidden')['hidden'] is True and digest() == hidden_before, 'location set --hidden hides a location (GUI state, not the library)')
    check(command('project', 'list')['total'] == 0, 'a hidden location disappears from project list')
    refusals = [('project', 'status', 'pin', 'unpin', 'open', 'refresh', 'set-stage', 'update', 'relocate', 'find-moved', 'icons-strip', 'icons-restore', 'remove', 'workspace-detach', 'workspace-bin', 'files', 'open-file', 'add-files', 'open-premiere')]
    extras = {'set-stage': ['--stage', 'Editing'], 'update': ['--notes', 'x'], 'relocate': ['--path', str(root)], 'open-file': ['--path', 'a'], 'add-files': ['--from', str(donor)], 'workspace-bin': ['--confirm']}
    for verb in refusals[0][1:]:
        res = command('project', verb, iconic['id'], *extras.get(verb, []), code=1)
        check(res['error']['code'] == 'location_hidden', 'hidden location refuses project ' + verb)
    check(error('project', 'create', '--from-idea', iconic['id'])['code'] in ('location_hidden', 'invalid_params'), 'hidden location refuses create --from-idea')
    check(error('compat', 'check', '--project', iconic['id'])['code'] == 'location_hidden', 'hidden location refuses compat check')
    check(error('project', 'register', '--path', str(root / 'Projects' / 'Short'))['code'] == 'location_hidden', 'hidden location refuses project register')
    check(error('location', 'scan', '--path', str(root))['code'] == 'location_hidden', 'hidden location refuses location scan')
    check(error('project', 'create', '--format', 'Short', '--title', 'Hidden destination')['code'] == 'location_hidden', 'hidden location refuses create into it')
    check(error('project', 'register', '--path', str(cached_dir), '--request-id', 'reg-hidden')['code'] == 'location_hidden', 'a cached request id result is refused once its location is hidden')
    check(all(error('project', verb, hid_idea['id'], *extra_)['code'] == 'location_hidden' for verb, extra_ in [('files', []), ('status', []), ('reveal', []), ('open-premiere', []), ('add-files', ['--from', str(root)])]), 'an idea whose workspace is on a hidden location is refused like a project')
    check(error('idea', 'create-workspace', hid_idea['id'], '--request-id', 'ws-hidden')['code'] == 'location_hidden', 'a cached workspace result is refused once its location is hidden')
    check(command('location', 'set', 'local', '--visible')['hidden'] is False and command('project', 'list')['total'] > 5, 'location set --visible shows it again')

    scan_root = root / 'ScanMe'
    for name in ['900 — Short — Scanned A', '901 — Short — Scanned B']:
        (scan_root / name / '01 Documents').mkdir(parents=True); (scan_root / name / '02 Project Files').mkdir()
    before = world()
    scan_dry = command('location', 'scan', '--path', str(scan_root), '--dry-run')
    check(scan_dry['dryRun'] and scan_dry['discovered'] == 2 and not any(p['alreadyRegistered'] for p in scan_dry['projects']) and world() == before, 'location scan dry-run lists the discovered projects and changes nothing')
    subset = [p['path'] for p in scan_dry['projects'] if p['name'].endswith('Scanned A')]
    check(error('location', 'scan', '--path', str(scan_root), '--only', json.dumps(['/not/found']))['code'] == 'invalid_params', 'location scan --only validates the paths')
    applied = command('location', 'scan', '--path', str(scan_root), '--only', json.dumps(subset))
    names_on_disk = {p['name'] for p in lib()['projects']}
    check(applied['registered'] == 1 and '900 — Short — Scanned A' in names_on_disk and '901 — Short — Scanned B' not in names_on_disk, 'location scan --only registers just the chosen subset, on disk')
    saved_locations = command('location', 'list')['saved']
    check(len(saved_locations) == 1 and saved_locations[0]['path'].endswith('ScanMe'), 'location scan saves the scanned location')
    rescan = command('location', 'scan', '--location', saved_locations[0]['id'], '--dry-run')
    check(rescan['discovered'] == 2 and sum(p['alreadyRegistered'] for p in rescan['projects']) == 1, 'location scan --location re-scans and flags registered projects')
    command('location', 'scan', '--location', 'ScanMe')
    check('901 — Short — Scanned B' in {p['name'] for p in lib()['projects']}, 'location scan applies a saved location, registering all of it')
    before = world()
    check(command('location', 'remove', 'ScanMe', '--dry-run')['dryRun'] and world() == before, 'location remove dry-run changes nothing')
    command('location', 'remove', 'ScanMe')
    check(lib().get('locations') == [] and '900 — Short — Scanned A' in {p['name'] for p in lib()['projects']}, 'location remove forgets the location and keeps its projects, on disk')
    check(error('location', 'remove', 'ScanMe')['code'] == 'not_found', 'location remove validation error')

    stray = root / 'Stray' / '700 — Short — Registered'; stray.mkdir(parents=True)
    reg = command('project', 'register', '--path', str(stray), '--format', 'Short', '--request-id', 'reg-1')
    check(reg['path'] == str(stray) and reg['format'] == 'Short' and record_on_disk(reg['id'])['path'] == str(stray), 'project register is read back and on disk')
    total = len(lib()['projects'])
    check(command('project', 'register', '--path', str(stray), '--format', 'Short', '--request-id', 'reg-1')['id'] == reg['id'] and len(lib()['projects']) == total, 'project register retry acts once')
    check(command('project', 'register', '--path', str(stray))['id'] == reg['id'] and len(lib()['projects']) == total, 'registering a folder already registered refreshes it, not duplicates it')
    check(error('project', 'register', '--path', str(root / 'nowhere'))['code'] == 'not_found', 'project register validation error')
    check(error('project', 'register', '--path', str(stray), '--format', 'Nope')['code'] == 'invalid_params', 'project register validates the format')

    copy = root / 'Stray2' / '700 — Short — Registered'; shutil.copytree(stray, copy)
    shutil.copytree(stray, root / 'Stray2' / 'sibling')
    command('project', 'register', '--path', str(copy), '--format', 'Short')
    dupes = command('library', 'duplicates')
    check(any(g['name'] == '700 — Short — Registered' and len(g['projects']) == 2 and sum(p['likelyLive'] for p in g['projects']) == 1 for g in dupes['groups']), 'library duplicates groups same-name projects and marks the likely live one')

    bad = root / 'CompatSrc'; bad.mkdir()
    (bad / 'bad|name.txt').write_text('x'); (bad / 'fine.txt').write_text('y')
    compat = command('compat', 'check', '--path', str(bad))
    check(compat['findings'] >= 1 and any('bad|name' in i['path'] for i in compat['items']), 'compat check finds an incompatible name')
    check(command('compat', 'check', '--project', iconic['id'])['complete'], 'compat check by project')
    out_dir = root / 'Out'; out_dir.mkdir()
    before = world()
    compat_dry = command('compat', 'check', '--path', str(bad), '--copy-to', str(out_dir), '--dry-run')
    check(compat_dry['dryRun'] and any('bad' in r['from'] for r in compat_dry['renames']) and world() == before, 'compat --copy-to dry-run returns the exact rename proposal and changes nothing')
    copied = command('compat', 'check', '--path', str(bad), '--copy-to', str(out_dir), '--request-id', 'compat-1')
    check(pathlib.Path(copied['copy']).is_dir() and (bad / 'bad|name.txt').exists() and not (pathlib.Path(copied['copy']) / 'bad|name.txt').exists(), 'compat --copy-to writes a corrected copy and leaves the original')
    check(command('compat', 'check', '--path', str(bad), '--copy-to', str(out_dir), '--request-id', 'compat-1')['copy'] == copied['copy'] and len(list(out_dir.iterdir())) == 1, 'compat --copy-to retry acts once')
    check(error('compat', 'check', '--path', str(bad), '--copy-to', '/private/tmp')['code'] == 'not_allowed', 'compat --copy-to refuses a destination outside the isolated root')

    tagged_before = tag_names(alpha['path'])
    check(error('library', 'tag-folders')['code'] == 'tags_disabled', 'tag-folders refuses while Finder tags are off')
    command('settings', 'finder-tags', '--enabled')
    tag_dry = command('library', 'tag-folders', '--dry-run')
    check(tag_dry['dryRun'] and tag_dry['candidates'] >= 3, 'tag-folders dry-run counts the folders')
    subprocess.run(['/usr/bin/xattr', '-d', 'com.apple.metadata:_kMDItemUserTags', alpha['path']])
    done = command('library', 'tag-folders')
    check(done['tagged'] >= 3 and tag_names(alpha['path']) == ['Published'], 'tag-folders writes the stage tags')
    command('location', 'set', 'local', '--hidden')
    check(command('library', 'tag-folders', '--dry-run')['candidates'] == 0, 'tag-folders skips hidden locations')
    command('location', 'set', 'local', '--visible')
    command('settings', 'finder-tags', '--no-enabled')
    check(error('app', 'cancel', '--request-id', 'nothing')['code'] == 'not_running', 'app cancel with nothing running')

    # -- cancellation of a long import, started by a request id --------------------------------------------------------------
    big = root / 'Src' / 'Big'; big.mkdir(parents=True)
    with open(big / 'blob.bin', 'wb') as handle:
        block = os.urandom(1 << 20)
        for _ in range(2600): handle.write(block)
    import threading
    outcome = {}
    def long_import():
        result = subprocess.run([str(cli), 'template', 'import', '--path', str(big), '--name', 'BigTpl', '--mode', 'full', '--request-id', 'big-1', '--json', '--data-directory', str(root)], capture_output=True, text=True, timeout=120)
        outcome['code'] = result.returncode; outcome['body'] = json.loads(result.stdout)
    worker = threading.Thread(target=long_import); worker.start()
    time.sleep(0.6)
    stopped = subprocess.run([str(cli), 'app', 'cancel', '--request-id', 'someone-else', '--json', '--data-directory', str(root)], capture_output=True, text=True, timeout=30)
    owner_code = json.loads(stopped.stdout).get('error', {}).get('code')
    cancel = subprocess.run([str(cli), 'app', 'cancel', '--request-id', 'big-1', '--json', '--data-directory', str(root)], capture_output=True, text=True, timeout=30)
    worker.join(timeout=120)
    cancel_body = json.loads(cancel.stdout)
    if cancel.returncode == 0:
        check(owner_code == 'not_owner' and outcome['code'] == 1 and outcome['body']['error']['code'] == 'cancelled' and all(t['name'] != 'BigTpl' for t in lib()['templates']), 'app cancel stops the operation its request id started and nothing is registered')
    else:
        check(cancel_body['error']['code'] == 'not_running' and outcome['code'] == 0, 'app cancel after the import finished reports not_running')
    shutil.rmtree(big)
    for leftover in (root / 'Templates').iterdir():
        pass

    # -- every MCP tool through the shim, and explicit false / array / object over MCP ----------------------------------------
    sweep_state = world()
    overrides = {'field_add': {'name': '[x]'}, 'set_create': {'name': ' '}, 'project_create': {'format': 'x', 'title': 'x'}}
    calls = []
    for i, tool in enumerate(manifest['tools']):
        props = tool['inputSchema']['properties']
        args = dict(overrides.get(tool['name'], {}))
        for key in tool['inputSchema']['required']:
            if key in args: continue
            kind = props[key]['type']
            args[key] = False if kind == 'boolean' else ([] if kind == 'array' else ({} if kind == 'object' else 'x'))
        calls.append({'jsonrpc': '2.0', 'id': 1000 + i, 'method': 'tools/call', 'params': {'name': tool['name'], 'arguments': args}})
    answers = {}
    for start in range(0, len(calls), 6):  # a few at a time, like a real client; never a flood of launches
        batch = calls[start:start + 6]
        sweep = subprocess.run(['node', str(shim)], input=''.join(json.dumps(c) + '\n' for c in batch), capture_output=True, text=True, env=env, timeout=300)
        answers.update({r['id']: r for r in map(json.loads, sweep.stdout.splitlines())})
    routed = 0
    for c in calls:
        answer = answers[c['id']]
        text = answer.get('result', {}).get('content', [{}])[0].get('text', '')
        assert 'error' not in answer, (c['params']['name'], answer)
        assert 'Unknown command' not in text and 'Unknown or invalid' not in text, (c['params']['name'], text)
        routed += 1
    check(routed == len(manifest['tools']), 'every MCP tool name is routed through the shim to its command (%d invoked, hyphenated ones included)' % routed)
    check(world() == sweep_state, 'the MCP sweep with invalid arguments changed nothing')
    def mcp_call(name, arguments):
        request = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': name, 'arguments': arguments}}
        out = subprocess.run(['node', str(shim)], input=json.dumps(request) + '\n', capture_output=True, text=True, env=env, timeout=60)
        reply = json.loads(out.stdout.splitlines()[0])
        return reply if 'error' in reply else json.loads(reply['result']['content'][0]['text'])
    check(mcp_call('settings_finder_tags', {'enabled': True})['finderTags'] is True and mcp_call('settings_finder_tags', {'enabled': False})['finderTags'] is False and lib()['finderTags'] is False, 'MCP passes an explicit false through (enabled false turns tags off)')
    arr = mcp_call('stage_set', {'board': 'live', 'stages': ['Soon, maybe', 'Done'], 'dryRun': True})
    check(arr['dryRun'] and arr['stages'] == ['Soon, maybe', 'Done'], 'MCP passes an array of stage names with a comma intact')
    check(mcp_call('project_set_stage', {'project': alpha['id'], 'stage': 'Editing'})['stage'] == 'Editing' and record_on_disk(alpha['id'])['stage'] == 'Editing', 'MCP routes a hyphenated tool (project_set_stage) to its command')
    obj = mcp_call('project_create', {'format': 'Short', 'title': 'MCP preview', 'extra': {}, 'plainFolders': False, 'dryRun': True})
    check(obj['dryRun'] and obj['plainFolders'] is False, 'MCP passes an object and a false boolean to create')
    check(mcp_call('project_update', {'project': alpha['id'], 'notes': '--starts with dashes'})['notes'] == '--starts with dashes', 'MCP passes a value that starts with dashes')
    check('error' in mcp_call('stage_set', {'board': 'live', 'stages': 'not-an-array'}), 'MCP refuses a string where an array is declared')

    # -- two callers at once ------------------------------------------------------------------------------------------------
    def stage_call(stage):
        res = subprocess.run([str(cli), 'project', 'set-stage', alpha['id'], '--stage', stage, '--json', '--data-directory', str(root)], capture_output=True, text=True, timeout=60)
        body_ = json.loads(res.stdout)
        assert (res.returncode == 0 and body_['stage'] == stage) or (res.returncode == 1 and body_['error']['code'] == 'busy'), (stage, body_)
        return stage if res.returncode == 0 else None
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        wins = [w for w in pool.map(stage_call, ['Writing', 'Filming', 'Editing', 'Published', 'Writing', 'Filming']) if w]
    check(wins and command('project', 'status', alpha['id'])['stage'] in wins and record_on_disk(alpha['id'])['stage'] in wins, 'concurrent stage changes serialize or report busy; no update is lost or invented')
    def field_call(args):
        res = subprocess.run([str(cli), 'project', 'update', alpha['id'], *args, '--json', '--data-directory', str(root)], capture_output=True, text=True, timeout=60)
        return res.returncode, json.loads(res.stdout)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        first, second = pool.map(field_call, [['--editor', 'Racer A'], ['--campaign', 'Racer B']])
    final = record_on_disk(alpha['id'])
    check(all(code_ in (0, 1) for code_, _ in (first, second)) and ((first[0] != 0) or final.get('editor') == 'Racer A') and ((second[0] != 0) or final.get('campaign') == 'Racer B'), 'two concurrent updates to different fields both land or one reports busy')

    check(command('project', 'status', hid_idea['id'])['workspace']['state'] == 'ok', 'the idea workspace reads again when its location is ticked')
    check(command('project', 'register', '--path', str(cached_dir), '--request-id', 'reg-hidden')['id'] == cached['id'], 'the cached result is served again when the location is ticked')
    check(command('project', 'open', alpha['id'], '--page', 'pipeline')['page'] == 'Pipeline' and command('status')['page'] == 'Pipeline', 'project open --page pipeline shows the project on the board')
    check(command('project', 'open', alpha['id'])['page'] == 'Projects' and command('status')['page'] == 'Projects', 'project open defaults to the Projects page')
    check(error('project', 'open', alpha['id'], '--page', 'nowhere')['code'] == 'invalid_params', 'project open validates the page')
    deep_doc = pathlib.Path(alpha['path']) / '01 Documents' / 'Plan.md'; deep_doc.parent.mkdir(exist_ok=True); deep_doc.write_text('The zebra crossing moment\n')
    check(command('project', 'list', '--search', 'zebra')['total'] == 0 and command('project', 'list', '--search', 'zebra', '--deep')['total'] == 1, 'project list --deep finds text inside documents')

    # Block only this synthetic library's durable save: disk rename must roll back.
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
    check(len(instances.pids(root)) == 1, 'still exactly one test instance after the whole run')
    if app.suffix != '.app':
        # A bare CLI (not inside an app) starts the ProjectTemplates beside it, never the installed app. One instance at a time:
        # the main test instance goes first.
        proc.terminate(); proc.wait(timeout=10)
        check(not instances.pids(root), 'the main test instance has quit before the cold-start checks')
        cold = pathlib.Path(tempfile.mkdtemp(prefix='cos-ai-cold-', dir='/private/tmp')); roots.append(cold)
        started = subprocess.run([str(cli), 'library', 'stats', '--json', '--data-directory', str(cold)], capture_output=True, text=True, timeout=60)
        alive = instances.pids(cold)
        started_from = subprocess.run(['/bin/ps', '-o', 'args=', '-p', str(alive[0])], capture_output=True, text=True).stdout.strip() if alive else ''
        check(started.returncode == 0 and 'templates' in json.loads(started.stdout) and len(alive) == 1 and os.path.realpath(started_from.split(' ')[0]) == os.path.realpath(str(exe)), 'a bare CLI cold-start launches the ProjectTemplates beside it')
        instances.quit_all(cold)
        check(not instances.pids(cold), 'the cold-started instance is gone and nothing is left behind')
        lone = pathlib.Path(tempfile.mkdtemp(prefix='cos-ai-lone-', dir='/private/tmp')); roots.append(lone)
        shutil.copy(cli, lone / 'creatoros')
        refused = subprocess.run([str(lone / 'creatoros'), 'library', 'stats', '--json', '--data-directory', str(lone)], capture_output=True, text=True, timeout=60)
        check(refused.returncode == 1 and json.loads(refused.stdout)['error']['code'] == 'no_app' and not instances.pids(lone), 'a bare CLI with no sibling app and a data directory refuses with an actionable error and launches nothing')
    result_line = ('RESULT', checks + 1, 'AI control checks passed; fixture', root)
finally:
    # Quit what this run launched, wait for it to exit, then sweep anything left on its own data directories.
    if proc is not None:
        proc.terminate()
        try: proc.wait(timeout=10)
        except subprocess.TimeoutExpired: pass
    instances.quit_all(*roots)
    instances.assert_none_alive(*roots)
print(*result_line)
print('PASS no test instance with a data directory of this run is still running', flush=True)
