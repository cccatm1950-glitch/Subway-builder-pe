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

cp "$GITHUB_WORKSPACE/export_presets.cfg" "$RUNNER_TEMP/godot-smoke/export_presets.cfg"
sed -i \
  -e 's#export_path="build/android/SubwayBuilderMobileUnofficial-debug.apk"#export_path="/workspace/build/android/SmokeTest.apk"#' \
  -e 's#package/unique_name="com.subwaybuilder.mobileunofficial"#package/unique_name="com.example.godotexportsmoke"#' \
  -e 's#package/name="Subway Builder Mobile Unofficial"#package/name="Godot Export Smoke Test"#' \
  "$RUNNER_TEMP/godot-smoke/export_presets.cfg"

docker run --rm \
  -v "$RUNNER_TEMP/godot-smoke:/smoke" \
  -v "$GITHUB_WORKSPACE/build:/workspace/build" \
  -w /smoke \
  barichello/godot-ci:4.4.1 \
  bash -lc '
    set -e
    SDKMANAGER=/usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager
    yes | "$SDKMANAGER" --sdk_root=/usr/lib/android-sdk --licenses
    "$SDKMANAGER" --sdk_root=/usr/lib/android-sdk \
      "platform-tools" "build-tools;34.0.0" "platforms;android-34" \
      "cmdline-tools;latest" "cmake;3.10.2.4988404" "ndk;23.2.8568313"
    godot --headless --path . --editor --quit
    godot --headless --path . --export-debug "Android" /workspace/build/android/SmokeTest.apk --verbose
  '
