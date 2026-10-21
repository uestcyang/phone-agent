"""Generate standard SDK wrapper files without copying a personal build directory."""
from pathlib import Path
import shutil,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
app=root/'app'
with tempfile.TemporaryDirectory(prefix='phoneagent-sdk-') as td:
    tmp=Path(td)/'template'
    subprocess.run(['flutter','create','--no-pub','--platforms=android','--org','org.phoneagent','--project-name','phone_agent_app',str(tmp)],check=True)
    for name in ['gradlew','gradlew.bat','gradle/wrapper/gradle-wrapper.jar','local.properties']:
        src=tmp/'android'/name;dst=app/'android'/name
        if dst.exists():continue
        dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst)
print('Local SDK wrapper files generated. Do not commit local.properties or build output.')
