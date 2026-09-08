#!/bin/zsh
set -eu
setopt extendedglob
cd "${0:A:h:h}"
# Run after swift build; pass its debug directory when using a custom scratch path.
build_dir=${1:-/private/tmp/creatoros-build/arm64-apple-macosx/debug}
check_dir=$(mktemp -d /private/tmp/creatoros-durable-check.XXXXXX)
cp Sources/ProjectTemplates/ProjectTemplatesApp.swift "$check_dir/ProjectTemplatesApp.swift"
# Keep all real UI declarations, replacing only the executable entrypoint.
sed -i '' 's/^@main struct ContentTemplateApp/struct ContentTemplateApp/' "$check_dir/ProjectTemplatesApp.swift"
swiftc -parse-as-library -module-name CreatorOSDurableCheck -I "$build_dir/Modules" \
    Sources/ProjectTemplates/^ProjectTemplatesApp.swift(.N) \
    "$check_dir/ProjectTemplatesApp.swift" Scripts/check-durable-save.swift \
    "$build_dir"/TemplateCore.build/*.swift.o -o "$check_dir/check"
"$check_dir/check" --data-directory "$check_dir/Data"
print "Disposable evidence retained: $check_dir"
