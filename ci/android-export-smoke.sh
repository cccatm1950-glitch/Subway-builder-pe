#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$RUNNER_TEMP/godot-smoke/scenes" "$GITHUB_WORKSPACE/build/android"

cat > "$RUNNER_TEMP/godot-smoke/project.godot" <<'EOF'
config_version=5
[application]
config/name="Android Export Smoke Test"
run/main_scene="res://scenes/main.tscn"
[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
EOF

cat > "$RUNNER_TEMP/godot-smoke/scenes/main.tscn" <<'EOF'
[gd_scene format=3]
[node name="Main" type="Node2D"]
EOF

cat > "$RUNNER_TEMP/godot-smoke/export_presets.cfg" <<'EOF'
[preset.0]
name="Android"
platform="Android"
runnable=true
export_filter="all_resources"
include_filter=""
exclude_filter=""
export_path="/workspace/build/android/SmokeTest.apk"
patches=PackedStringArray()
[preset.0.options]
custom_template/debug=""
custom_template/release=""
gradle_build/use_gradle_build=false
architectures/armeabi-v7a=false
architectures/arm64-v8a=true
architectures/x86=false
architectures/x86_64=false
version/code=1
version/name="1.0"
package/unique_name="com.example.godotexportsmoke"
package/name="Godot Export Smoke Test"
package/signed=false
package/app_category=2
package/retain_data_on_uninstall=false
package/exclude_from_recents=false
package/show_in_android_tv=false
package/show_in_app_library=true
package/show_as_launcher_app=false
screen/immersive_mode=false
screen/support_small=true
screen/support_normal=true
screen/support_large=true
screen/support_xlarge=true
permissions/custom_permissions=PackedStringArray()
permissions/internet=false
EOF

docker run --rm \
  -v "$RUNNER_TEMP/godot-smoke:/smoke" \
  -v "$GITHUB_WORKSPACE/build:/workspace/build" \
  -w /smoke \
  barichello/godot-ci:4.4.1 \
  bash -lc 'godot --headless --path . --editor --quit && godot --headless --path . --export-debug "Android" /workspace/build/android/SmokeTest.apk --verbose'
