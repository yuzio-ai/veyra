#!/usr/bin/env python3
"""Opt-in signed credential integration: independent Keychain, fake key, local HTTP only."""
import argparse, hashlib, http.server, json, os, pathlib, plistlib, shutil, subprocess, tempfile, threading, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
FAKE = 'veyra-fixture-only-key'

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--app',type=pathlib.Path,required=True)
    parser.add_argument('--codex',type=pathlib.Path,default=pathlib.Path.home()/'.local/bin/codex')
    args=parser.parse_args()
    app=args.app.resolve(); binary=app/'Contents/MacOS/Veyra'
    subprocess.run(['/usr/bin/codesign','--verify','--strict',str(app)],check=True,capture_output=True)
    info=subprocess.run(['/usr/bin/codesign','-dv',str(app)],check=True,capture_output=True,text=True).stderr
    if 'Signature=adhoc' in info or 'TeamIdentifier=not set' in info: raise RuntimeError('A stable signing identity is required')
    output=ROOT/'build/provider-credentials'/time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())
    output.mkdir(parents=True,exist_ok=False)
    codex_version=subprocess.check_output([str(args.codex),'--version'],text=True,timeout=10).strip()
    search_before=subprocess.check_output(['/usr/bin/security','list-keychains','-d','user'])
    requests=[]
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self,*args): pass
        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length','0')))
            authorized=self.headers.get('Authorization')=='Bearer '+FAKE
            requests.append({'path':self.path,'authenticated':authorized})
            if not authorized:
                self.send_response(401);self.end_headers();return
            message={'id':'msg_fixture','type':'message','role':'assistant','status':'completed','content':[{'type':'output_text','text':'OK','annotations':[]}]}
            response={'id':'resp_fixture','object':'response','created_at':1,'status':'completed','model':'veyra-fixture','output':[message],'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2}}
            events=[('response.created',{'response':dict(response,status='in_progress',output=[])}),
                    ('response.output_item.added',{'output_index':0,'item':dict(message,status='in_progress',content=[])}),
                    ('response.output_text.delta',{'item_id':'msg_fixture','output_index':0,'content_index':0,'delta':'OK'}),
                    ('response.output_item.done',{'output_index':0,'item':message}),
                    ('response.completed',{'response':response})]
            self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
            for i,(name,data) in enumerate(events):
                data.update(type=name,sequence_number=i)
                self.wfile.write(('event: '+name+'\ndata: '+json.dumps(data)+'\n\n').encode())
            self.wfile.flush()
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    with tempfile.TemporaryDirectory(prefix='veyra-credential-',dir='/private/tmp') as temp:
        directory=pathlib.Path(temp); keychain=directory/'veyra-fixture.keychain-db'
        denied_keychain=directory/'denied'/'veyra-fixture.keychain-db'
        try:
            created=subprocess.run([str(binary),'--create-credential-fixture',str(directory)],capture_output=True,text=True,timeout=20)
            if created.returncode: raise RuntimeError('Independent Keychain fixture creation failed: '+created.stderr)
            ref=json.loads((directory/'credential-reference.json').read_text())['id'].lower()
            helper=[str(binary),'--provider-credential-fixture',ref,str(keychain)]
            read=subprocess.run(helper,capture_output=True,text=True,timeout=10)
            if read.returncode or read.stdout.strip()!=FAKE: raise RuntimeError('Signed headless Keychain read failed')
            home=directory/'codex';home.mkdir()
            config='\n'.join(['model="veyra-fixture"','model_provider="veyra-fixture"','web_search="disabled"','cli_auth_credentials_store="file"',
                '[model_providers.veyra-fixture]','name="Fixture"','wire_api="responses"',
                'base_url='+json.dumps(f'http://127.0.0.1:{server.server_port}/v1'),
                '[model_providers.veyra-fixture.auth]','command='+json.dumps(str(binary)),
                'args='+json.dumps(helper[1:]),'timeout_ms=5000','refresh_interval_ms=0',''])
            (home/'config.toml').write_text(config)
            env={k:v for k,v in os.environ.items() if k in ('PATH','HOME','USER','LOGNAME','TMPDIR','LANG')}
            env['CODEX_HOME']=str(home)
            result=subprocess.run([str(args.codex),'exec','--skip-git-repo-check','--sandbox','read-only','--json','-C',str(directory),'Reply OK. Do not use tools.'],env=env,capture_output=True,text=True,timeout=45)
            # Canary values must never enter persisted diagnostics or metadata.
            if FAKE in config or FAKE in result.stdout or FAKE in result.stderr: raise RuntimeError('Credential leaked into configuration or Codex diagnostics')
            if result.returncode or not requests or not all(x['authenticated'] for x in requests):
                (output/'codex-diagnostic.txt').write_text((result.stdout+'\n'+result.stderr).replace(FAKE,'[REDACTED]'))
                raise RuntimeError('Codex credential helper integration failed; see sanitized diagnostic')
            # Exercise the same signed executable after a bundle move and command-only repair.
            moved=directory/'Moved Veyra.app'
            shutil.copytree(app,moved)
            moved_binary=moved/'Contents/MacOS/Veyra'
            moved_read=subprocess.run([str(moved_binary),'--provider-credential-fixture',ref,str(keychain)],capture_output=True,text=True,timeout=10)
            if moved_read.returncode or moved_read.stdout.strip()!=FAKE:
                raise RuntimeError('Moved signed bundle could not read the fixture Keychain')
            repaired=config.replace(json.dumps(str(binary)),json.dumps(str(moved_binary)))
            (home/'config.toml').write_text(repaired)
            prior=len(requests)
            moved_run=subprocess.run([str(args.codex),'exec','--skip-git-repo-check','--sandbox','read-only','--json','-C',str(directory),'Reply OK. Do not use tools.'],env=env,capture_output=True,text=True,timeout=45)
            if moved_run.returncode or len(requests)<=prior or FAKE in moved_run.stdout or FAKE in moved_run.stderr:
                raise RuntimeError('Independent Codex failed after helper path repair')
            (home/'config.toml').write_text(config)
            catalogs_checked=[]
            for provider in ('deepseek','kimi','glm','minimax','mimo'):
                discovery=directory/'model-catalog-fixture'; discovery.mkdir(exist_ok=True)
                identifier='fixture-dynamic-'+provider+'-future'
                row={'id':identifier}
                if provider=='deepseek': row.update(context_window=123456,effort={'supported_levels':['max','future-effort'],'default_level':'future-effort'},input_modalities=['text'])
                if provider=='kimi': row.update(context_length=234567,supports_image_in=True)
                response={'data':[row]}
                if provider=='glm': response={'models':[{'slug':identifier,'context_window':345678,'model_messages':{'instructions_template':'MUST_NOT_IMPORT'}}]}
                (discovery/'models-response.json').write_text(json.dumps(response))
                generated=subprocess.run([str(binary),'--create-model-catalog-fixture',provider,str(discovery)],capture_output=True,text=True,timeout=10)
                if generated.returncode: raise RuntimeError('Signed dynamic catalog generation failed: '+provider)
                catalog=discovery/(provider+'.json')
                catalog_data=catalog.read_text()
                if 'MUST_NOT_IMPORT' in catalog_data: raise RuntimeError('Untrusted instructions entered the dynamic catalog')
                model=json.loads(catalog_data)['models'][0]
                if model['slug']!=identifier: raise RuntimeError('Dynamic model identifier was changed')
                if provider in ('minimax','mimo') and model.get('context_window') is not None: raise RuntimeError('Missing model context was invented')
                configured=config.replace('model="veyra-fixture"','model='+json.dumps(model['slug']))
                configured='\n'.join(['model_catalog_json='+json.dumps(str(catalog)),
                    'preferred_auth_method="apikey"','forced_login_method="api"',configured])
                (home/'config.toml').write_text(configured)
                prior=len(requests)
                run=subprocess.run([str(args.codex),'exec','--skip-git-repo-check','--sandbox','read-only','--json','-C',str(directory),'Reply OK. Do not use tools.'],env=env,capture_output=True,text=True,timeout=45)
                if FAKE in run.stdout or FAKE in run.stderr: raise RuntimeError('Credential leaked into provider catalog diagnostics')
                if run.returncode or len(requests)<=prior or not all(x['authenticated'] for x in requests[prior:]):
                    (output/(provider+'-diagnostic.txt')).write_text((run.stdout+'\n'+run.stderr).replace(FAKE,'[REDACTED]'))
                    raise RuntimeError('Local Codex capability catalog validation failed: '+provider)
                catalogs_checked.append({'provider':provider,'model':model['slug']})
            # A later independent process must still retrieve the key, without a running GUI.
            again=subprocess.run(helper,capture_output=True,text=True,timeout=10)
            if again.returncode or again.stdout.strip()!=FAKE: raise RuntimeError('Credential did not survive process restart')
            missing=subprocess.run([str(binary),'--provider-credential-fixture','00000000-0000-0000-0000-000000000000',str(keychain)],capture_output=True,text=True,timeout=10)
            if missing.returncode==0 or missing.stdout or FAKE in missing.stderr: raise RuntimeError('Missing credential did not fail safely')
            subprocess.run([str(binary),'--lock-credential-fixture',str(keychain)],check=True,capture_output=True,timeout=10)
            locked=subprocess.run(helper,capture_output=True,text=True,timeout=10)
            if locked.returncode==0 or locked.stdout or FAKE in locked.stderr: raise RuntimeError('Locked Keychain did not fail closed')
            denied_keychain.parent.mkdir()
            subprocess.run([str(binary),'--create-denied-credential-fixture',str(denied_keychain.parent)],check=True,capture_output=True,timeout=20)
            denied_ref=json.loads((denied_keychain.parent/'credential-reference.json').read_text())['id'].lower()
            denied=subprocess.run([str(binary),'--provider-credential-fixture',denied_ref,str(denied_keychain)],capture_output=True,text=True,timeout=10)
            if denied.returncode==0 or denied.stdout or FAKE in denied.stderr:
                raise RuntimeError('Denied Keychain ACL did not fail closed')
            scanned=0
            for persisted in home.rglob('*'):
                if persisted.is_file() and not persisted.is_symlink():
                    scanned+=1
                    if FAKE.encode() in persisted.read_bytes(): raise RuntimeError('Fixture Key leaked into persisted Codex data')
            (output/'result.json').write_text(json.dumps({'status':'passed','codexVersion':codex_version,'stableSignature':True,'independentKeychain':True,'headlessRead':True,'movedBundleRead':True,'repairedPathIndependentCodex':True,'codexAuthenticatedLocalRequests':len(requests),'restartRead':True,'missingFailsClosed':True,'lockedFailsClosed':True,'deniedACLFailsClosed':True,'catalogsChecked':catalogs_checked,'dynamicCatalogs':True,'realProviderRequests':0,'persistedFilesScanned':scanned,'persistedSecretScan':True,'appSHA256':hashlib.sha256(binary.read_bytes()).hexdigest()},indent=2))
        finally:
            server.shutdown()
            for fixture_keychain in (keychain,denied_keychain):
                if fixture_keychain.exists(): subprocess.run([str(binary),'--delete-credential-fixture',str(fixture_keychain)],check=True,capture_output=True,timeout=15)
    search_after=subprocess.check_output(['/usr/bin/security','list-keychains','-d','user'])
    if search_before!=search_after: raise RuntimeError('Keychain search list changed')
    print('PASS signed credential integration:',output)
if __name__=='__main__': main()
