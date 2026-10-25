#!/usr/bin/env python3
# Native closure regression tests with OS/API substitutes; requires Swift.
import subprocess,sys,tempfile
from pathlib import Path
fork=Path(__file__).resolve().parent.parent
def closure(source,name):
 start=source.index('Function("'+name+'")')
 start=source.rfind('Async',0,start) if name=='cancelAlarm' else start
 brace=source.index('{',start);depth=1;i=brace+1
 while depth:
  if source[i]=='{':depth+=1
  elif source[i]=='}':depth-=1
  i+=1
 return source[start:i]
def program(source):
 return r'''
import Foundation
struct Alarm { let id: UUID }
enum Failure: Error { case read, cancel }
class AlarmManager {
 static let shared = AlarmManager()
 var list: [Alarm] = []; var readFails = false; var cancelFails = false
 var alarms: [Alarm] { get throws { if readFails { throw Failure.read }; return list } }
 func cancel(id: UUID) throws { if cancelFails { throw Failure.cancel }; list.removeAll { $0.id == id } }
}
class ExpoAlarmKitStorage {
 static var ids: [String] = []
 static func getAllAlarmIds() -> [String] { ids }
 static func removeAlarm(id: String) { ids.removeAll { $0 == id } }
 static func removeLaunchAppOnDismiss(alarmId: String) {}
}
var query: (() throws -> [String])!
var cancel: ((String) -> Bool)!
func Function(_ name: String, _ body: @escaping () throws -> [String]) { query=body }
func AsyncFunction(_ name: String, _ body: @escaping (String) -> Bool) { cancel=body }
''' + closure(source,'getAllAlarms')+'\n'+closure(source,'cancelAlarm')+r'''
let a="11111111-1111-4111-8111-111111111111", b="abcdefab-abcd-4abc-8abc-abcdefabcdef"
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
 if try !condition() { fputs("FAIL: "+message+"\n",stderr); exit(1) }
 print("PASS: "+message)
}
ExpoAlarmKitStorage.ids=[a]; AlarmManager.shared.list=[Alarm(id:UUID(uuidString:b)!)]
try require(query()==[b],"OS-only reservation is returned; stale metadata is excluded")
let uppercase=b.uppercased();ExpoAlarmKitStorage.ids=[uppercase]
try require(query()==[uppercase],"original UUID spelling is preserved")
AlarmManager.shared.readFails=true
var propagated=false;do {_=try query()}catch{propagated=true}
try require(propagated,"OS lookup failure propagates")
ExpoAlarmKitStorage.ids=[a]
try require(!cancel(a) && ExpoAlarmKitStorage.ids==[a],"lookup failure retains cancellation records")
AlarmManager.shared.readFails=false;AlarmManager.shared.list=[]
try require(cancel(a) && ExpoAlarmKitStorage.ids.isEmpty,"already absent cancellation succeeds and cleans records")
ExpoAlarmKitStorage.ids=[a];AlarmManager.shared.list=[Alarm(id:UUID(uuidString:a)!)];AlarmManager.shared.cancelFails=true
try require(!cancel(a) && ExpoAlarmKitStorage.ids==[a],"cancellation failure retains records")
AlarmManager.shared.cancelFails=false
try require(cancel(a) && ExpoAlarmKitStorage.ids.isEmpty && AlarmManager.shared.list.isEmpty,"successful cancellation clears OS and records")
'''
changed=(fork/'ios/ExpoAlarmKitModule.swift').read_text()
cases=[('after',changed)]
if len(sys.argv)>1:
 baseline=subprocess.check_output(['git','show',sys.argv[1]+':ios/ExpoAlarmKitModule.swift'],cwd=fork,text=True)
 cases.insert(0,('before',baseline))
with tempfile.TemporaryDirectory(prefix='anshin-393-fork-tests-') as tmp:
 for label,source in cases:
  file=Path(tmp)/(label+'.swift');file.write_text(program(source));binary=Path(tmp)/label
  subprocess.run(['swiftc',str(file),'-o',str(binary)],check=True)
  result=subprocess.run([str(binary)],capture_output=True,text=True)
  print(label+':',result.stdout+result.stderr)
  if (label=='before' and result.returncode==0) or (label=='after' and result.returncode!=0):sys.exit(1)
