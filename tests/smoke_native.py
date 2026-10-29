#!/usr/bin/env python3
"""Verified official binaries; loopback TCP target, no external traffic."""
import pathlib,subprocess,socket,tempfile,os,time,hashlib
ROOT=pathlib.Path(__file__).resolve().parents[1]
def port():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
with tempfile.TemporaryDirectory() as tmp:
 d=pathlib.Path(tmp)
 subprocess.run(['openssl','req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:prime256v1','-nodes','-days','1','-subj','/CN=localhost','-keyout',str(d/'key.pem'),'-out',str(d/'cert.pem')],check=True,capture_output=True)
 der=subprocess.check_output(['openssl','x509','-in',str(d/'cert.pem'),'-outform','DER']);pin=hashlib.sha256(der).hexdigest()
 with socket.socket() as target:
  target.bind(('127.0.0.1',0));target.listen(20);target_port=target.getsockname()[1]
  for server,client,policy in [('v3.1.0','v3.1.0','full8'),('v3.1.0','v3.1.0','fade'),('v3.1.0','v3.0.1','full8'),('v3.0.1','v3.1.0','fade')]:
   p=port();key='a'*32;url=f'portal://{key}@127.0.0.1/tcp:{p}?tls=2&crt={d}/cert.pem&key={d}/key.pem&morph=1'
   env=dict(os.environ,NOW_MORPH_TCP_PRELUDE=policy,TMPDIR=tmp)
   proc=subprocess.Popen([str(ROOT/'upstream'/server/'nowhere'),url],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   try:
    ready=False
    for _ in range(50):
     if proc.poll() is not None:raise RuntimeError('Portal exited during startup')
     try:
      with socket.create_connection(('127.0.0.1',p),timeout=.1):ready=True;break
     except OSError:time.sleep(.1)
    if not ready:raise RuntimeError('Portal did not listen')
    url=f'vector://{key}@127.0.0.1/tcp:{p}?pin={pin}&morph=1'
    r=subprocess.run([str(ROOT/'upstream'/client/'nowhere'),'probe',url,f'127.0.0.1:{target_port}'],env=env,capture_output=True,text=True,timeout=15)
    if r.returncode:raise RuntimeError(f'Probe failed: Portal {server}, Vector {client}, policy {policy}, exit {r.returncode}')
    print(f'PASS Portal {server} / Vector probe {client} / Morph TCP {policy}',flush=True)
   finally:
    proc.terminate()
    try:proc.wait(timeout=5)
    except subprocess.TimeoutExpired:proc.kill();proc.wait()
print('4 native loopback flow checks passed; not production/systemd/ACME acceptance')
