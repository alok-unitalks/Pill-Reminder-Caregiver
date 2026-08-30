import re
import subprocess
import shutil

file_path = "lib/main.dart"

try:
    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Match version pattern
    match = re.search(r'const String appVersion = "Beta v1\.1\.2\+(\d+)";', content)
    if match:
        current_build = int(match.group(1))
        new_build = current_build + 1
        old_line = match.group(0)
        new_line = f'const String appVersion = "Beta v1.1.2+{new_build}";'
        
        content = content.replace(old_line, new_line)
        with open(file_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
            
        print(f"🚀 Version incremented: Beta v1.1.2+{current_build} -> Beta v1.1.2+{new_build}")
        version_str = f"Beta v1.1.2+{new_build}"
    else:
        print("⚠️ Pattern not matched. Using manual version.")
        version_str = "Manual Build"

    # Run flutter compile
    print("📦 Compiling Flutter Web Application...")
    res = subprocess.run("flutter build web --release --base-href \"/\"", shell=True)

    if res.returncode == 0:
        print("🚚 Copying built output to root...")
        shutil.copytree("build/web", ".", dirs_exist_ok=True)
        
        print("📤 Pushing release to GitHub...")
        subprocess.run("git add .", shell=True)
        subprocess.run(f"git commit -m \"Deploy Build: {version_str}\"", shell=True)
        subprocess.run("git push", shell=True)
        print("✨ Build and Deployment complete!")
    else:
        print("❌ Flutter compilation failed. Build aborted.")

except Exception as e:
    print(f"❌ Error occurred during build: {e}")
