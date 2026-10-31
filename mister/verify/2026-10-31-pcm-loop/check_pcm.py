from pathlib import Path
import struct,hashlib
for name in ('before-stream.raw','stream.raw'):
 b=Path(__file__).with_name(name).read_bytes();assert len(b)==262144
 v=struct.unpack('>131072h',b)
 print(name,'sha256',hashlib.sha256(b).hexdigest(),'frames',len(v)//2,'zerosL',sum(x==0 for x in v[::2]),'LRmismatch',sum(v[i]!=v[i+1] for i in range(0,len(v),2)),'range',min(v),max(v))
