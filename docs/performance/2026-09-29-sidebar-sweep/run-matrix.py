"""Run the 17 configuration matrix serially against one fixed acceptance app.
Run from repository root; output must be a new directory.
"""
import argparse,json,pathlib,subprocess,sys
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app',type=pathlib.Path,required=True)
parser.add_argument('--output',type=pathlib.Path,required=True)
args=parser.parse_args();out=args.output;app=args.app
out.mkdir(parents=True,exist_ok=False)
cases=[('baseline',k) for k in ['noop','content','order','header','membership','pins-fixed-members','pins','height','height-fixed']]+[('flat',k) for k in ['content','pins-fixed-members','pins','height']]+[('keep-header',k) for k in ['pins-fixed-members','pins']]+[('persistent-subtitle',k) for k in ['height','height-fixed']]
for n in range(1,4):
 order=cases if n==1 else list(reversed(cases)) if n==2 else cases[8:]+cases[:8]
 for variant,kind in order:
  dest=out/f'{variant}-{kind}-r{n}'
  r=subprocess.run(['python3','scripts/run-native-acceptance.py','--app',str(app),'--mode','sidebar-layout-'+kind,'--sidebar-variant',variant,'--output',str(dest)],capture_output=True,text=True)
  data=json.loads((dest/'result.json').read_text()) if (dest/'result.json').exists() else {}
  if r.returncode:
   print(dest.name,'FAIL',data.get('error'),r.stderr[-1200:],flush=True);sys.exit(r.returncode)
  print(dest.name,'PASS',data.get('layout_step_ms'),'CPU',round(data['layout_process_cpu_seconds'],3),'lifecycle',data['native_row_lifecycle'],flush=True)
