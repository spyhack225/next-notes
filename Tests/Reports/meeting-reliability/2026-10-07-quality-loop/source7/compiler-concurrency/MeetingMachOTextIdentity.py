"""Bounded thin arm64 Mach-O code-section identity for owned candidate packaging."""
import struct,hashlib
from pathlib import Path
def text_identity(path):
 path=Path(path);size=path.stat().st_size;sections={};uuid=None
 with path.open('rb') as stream:
  header=stream.read(32)
  assert len(header)==32,'truncated Mach-O header'
  magic,cpu,subtype,kind,ncmds,sizeofcmds,flags,reserved=struct.unpack('<8I',header)
  assert magic==0xfeedfacf and cpu==0x100000c and kind==2,'expected thin arm64 executable'
  assert 0<ncmds<=10000 and sizeofcmds<=2*1024*1024 and 32+sizeofcmds<=size,'invalid load-command bounds'
  commands=stream.read(sizeofcmds);position=0
  for _ in range(ncmds):
   assert position+8<=len(commands),'truncated command'
   command,length=struct.unpack_from('<II',commands,position)
   assert length>=8 and position+length<=len(commands),'invalid command length'
   if command==0x1b:
    assert length==24 and uuid is None,'invalid or duplicate UUID'
    uuid=commands[position+8:position+24].hex()
   if command==0x19:
    assert length>=72,'short segment64'
    segment=commands[position+8:position+24].split(b'\0')[0]
    count=struct.unpack_from('<I',commands,position+64)[0]
    assert 72+80*count<=length,'invalid section bounds'
    if segment==b'__TEXT':
     for index in range(count):
      start=position+72+80*index
      name=commands[start:start+16].split(b'\0')[0].decode('ascii')
      assert commands[start+16:start+32].split(b'\0')[0]==b'__TEXT','section segment mismatch'
      lengthBytes=struct.unpack_from('<Q',commands,start+40)[0]
      offset=struct.unpack_from('<I',commands,start+48)[0]
      assert name not in sections and offset+lengthBytes<=size,'duplicate or out-of-file section'
      digest=hashlib.sha256();stream.seek(offset);remaining=lengthBytes
      while remaining:
       chunk=stream.read(min(1024*1024,remaining));assert chunk,'truncated section payload'
       digest.update(chunk);remaining-=len(chunk)
      sections[name]={'bytes':lengthBytes,'sha256':digest.hexdigest()}
   position+=length
  assert position==sizeofcmds and uuid and sections.get('__text',{}).get('bytes',0)>0,'incomplete executable identity'
 return {'uuid':uuid,'cpu':cpu,'textSections':sections}
