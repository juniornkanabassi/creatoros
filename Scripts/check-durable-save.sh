#!/bin/zsh
set -eu
setopt extendedglob
cd "${0:A:h:h}"
# Run after swift build; pass the legacy debug directory or Xcode 27 scratch root.
build_dir=${1:-/private/tmp/creatoros-build/arm64-apple-macosx/debug}
arch=$(uname -m)
legacy_objects=("$build_dir"/TemplateCore.build/*.swift.o(N))
xcode_objects=("$build_dir"/out/Intermediates.noindex/ProjectTemplates.build/Debug/TemplateCore-t.build/Objects-normal/"$arch"/*.o(N))
if (( ${#legacy_objects} && ${#xcode_objects} )); then
    print -u2 "Both legacy and Xcode 27 TemplateCore objects found; use a clean build directory: $build_dir"
    exit 1
fi
if (( ${#legacy_objects} )); then
    if [[ ${build_dir:A:t} != debug || ${build_dir:A:h:t} != ${arch}-apple-macosx ]]; then
        print -u2 "Legacy build directory must be ${arch}-apple-macosx/debug: $build_dir"
        exit 1
    fi
    objects=("${legacy_objects[@]}")
    module_dir="$build_dir/Modules"
    module_file="$module_dir/TemplateCore.swiftmodule"
    framework_dir="$build_dir"
elif (( ${#xcode_objects} )); then
    objects=("${xcode_objects[@]}")
    module_dir="$build_dir/out/Products/Debug"
    module_file="$module_dir/TemplateCore.swiftmodule/${arch}-apple-macos.swiftmodule"
    framework_dir="$module_dir"
else
    print -u2 "No Debug TemplateCore objects for $arch found in legacy or Xcode 27 layout under: $build_dir"
    exit 1
fi
if [[ ! -f "$module_file" ]]; then
    print -u2 "Matching TemplateCore module not found: $module_file"
    exit 1
fi
sources=(Sources/TemplateCore/*.swift(N))
expected_objects=()
for source in "${sources[@]}"; do
    if (( ${#legacy_objects} )); then
        expected_objects+=("$build_dir/TemplateCore.build/${source:t}.o")
    else
        expected_objects+=("${xcode_objects[1]:h}/${source:t:r}.o")
    fi
done
if (( ${#objects} != ${#expected_objects} )); then
    print -u2 "TemplateCore object set does not match Sources/TemplateCore; rebuild first"
    exit 1
fi
for ((i = 1; i <= ${#sources}; i++)); do
    if [[ ! -f ${expected_objects[i]} ]]; then
        print -u2 "Missing TemplateCore object; rebuild first: ${expected_objects[i]}"
        exit 1
    fi
    if [[ ${sources[i]} -nt ${expected_objects[i]} ]]; then
        print -u2 "TemplateCore source is newer than its build output; rebuild first: ${sources[i]}"
        exit 1
    fi
done
objects=("${expected_objects[@]}")
print "TemplateCore objects: ${objects[1]:h}"
print "TemplateCore module: $module_file"
# The app sources import Sparkle (Updates.swift), so the harness links the framework SwiftPM built beside them.
[[ -d "$framework_dir/Sparkle.framework" ]] || { print -u2 "No Sparkle.framework in $framework_dir; rebuild first"; exit 1; }
check_dir=$(mktemp -d /private/tmp/creatoros-durable-check.XXXXXX)
cp Sources/ProjectTemplates/ProjectTemplatesApp.swift "$check_dir/ProjectTemplatesApp.swift"
# Keep all real UI declarations, replacing only the executable entrypoint.
sed -i '' 's/^@main struct ContentTemplateApp/struct ContentTemplateApp/' "$check_dir/ProjectTemplatesApp.swift"
swiftc -parse-as-library -module-name CreatorOSDurableCheck -I "$module_dir" \
    -F "$framework_dir" -framework Sparkle -Xlinker -rpath -Xlinker "$framework_dir" \
    Sources/ProjectTemplates/^ProjectTemplatesApp.swift(.N) \
    "$check_dir/ProjectTemplatesApp.swift" "${CONTENT_TEMPLATE_CHECK_SOURCE:-Scripts/check-durable-save.swift}" \
    "${objects[@]}" -o "$check_dir/check"
"$check_dir/check" --data-directory "$check_dir/Data"
print "Disposable evidence retained: $check_dir"
