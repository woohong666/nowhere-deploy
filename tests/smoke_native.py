#!/usr/bin/env python3
"""Real official core on loopback only; no service manager or external target."""
import pathlib,subprocess,socket,tempfile,os,time,hashlib
ROOT=pathlib.Path(__file__).resolve().parents[1];BIN=ROOT/'upstream/v3.3.0/nowhere'
def port():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
with tempfile.TemporaryDirectory() as tmp:
 d=pathlib.Path(tmp)
 subprocess.run(['openssl','req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:prime256v1','-nodes','-days','1','-subj','/CN=localhost','-keyout',str(d/'key.pem'),'-out',str(d/'cert.pem')],check=True,capture_output=True)
 pin=hashlib.sha256(subprocess.check_output(['openssl','x509','-in',str(d/'cert.pem'),'-outform','DER'])).hexdigest()
 with socket.socket() as target:
  target.bind(('127.0.0.1',0));target.listen(100);target_port=target.getsockname()[1]
  for carrier,egress in [('tcp',None),('udp',None),('tcp','tcp'),('udp','tcp'),('tcp','udp'),('udp','udp')]:
   p=port();key='a'*32;procs=[]
   env=dict(os.environ,NOW_MORPH_TCP_PRELUDE='full8',NOW_MORPH_UDP_PRELUDE='fade',TMPDIR=tmp,NOW_HANDSHAKE_TIMEOUT='3s',NOW_FLOW_SETUP_TIMEOUT='8s')
   url=f'portal://{key}@127.0.0.1/tcp:{p}/udp:{p}?tls=2&crt={d}/cert.pem&key={d}/key.pem&morph=1'+('&out=egress' if egress else '')
   try:
    portal=subprocess.Popen([str(BIN),url],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);procs.append(portal)
    for _ in range(60):
     if portal.poll() is not None:raise RuntimeError('Portal startup failed')
     try:
      with socket.create_connection(('127.0.0.1',p),timeout=.1):break
     except OSError:time.sleep(.05)
    else:raise RuntimeError('Portal did not listen')
    if egress:
     url=f'egress://{key}@127.0.0.1/{egress}:{p}?pin={pin}&morph=1'
     procs.append(subprocess.Popen([str(BIN),url],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL))
    url=f'vector://{key}@127.0.0.1/{carrier}:{p}?pin={pin}&morph=1'
    r=subprocess.run([str(BIN),'probe',url,f'127.0.0.1:{target_port}'],env=env,capture_output=True,text=True,timeout=12)
    if r.returncode:raise RuntimeError(f'probe failed: carrier={carrier} egress={egress} exit={r.returncode}')
    print(f'PASS v3.3.0 Vector probe {carrier} -> Portal -> '+(f'Egress {egress}' if egress else 'direct')+' -> local target',flush=True)
   finally:
    for proc in reversed(procs):
     proc.terminate()
     try:proc.wait(timeout=4)
     except subprocess.TimeoutExpired:proc.kill();proc.wait()
print('6 native loopback TCP-flow checks passed; no production/ACME/third-party acceptance')
