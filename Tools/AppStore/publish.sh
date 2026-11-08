#!/bin/zsh
# Publishes the App Store page from metadata/ and out/ to App Store Connect.
# Without --confirm it only shows what would change.
#
#   publish.sh                      dry run for the version main builds
#   publish.sh --confirm            write text and screenshots
#   publish.sh --version 1.1        target another App Store version
#   publish.sh --skip-screenshots   text only
#   publish.sh --platform MAC_OS    one platform, IOS or MAC_OS
#   publish.sh --check              validate the text offline, nothing else
set -euo pipefail
cd "${0:A:h}"
# Apple can take minutes to process an uploaded screenshot
export ASC_TIMEOUT=${ASC_TIMEOUT:-5m} ASC_UPLOAD_TIMEOUT=${ASC_UPLOAD_TIMEOUT:-20m}

confirm=0 check=0 screenshots=1 version="" platforms=(IOS MAC_OS)
while (( $# )); do
  case $1 in
    --confirm) confirm=1 ;;
    --check) check=1 ;;
    --skip-screenshots) screenshots=0 ;;
    --version) version=$2; shift ;;
    --platform) platforms=($2); shift ;;
    *) print -u2 "Unknown option: $1"; exit 2 ;;
  esac
  shift
done

if [[ -z $version ]]; then
  if (( check )); then
    version=check
  else
    version=$(../../scripts/app_version.sh)
  fi
fi

# asc reads one JSON file per locale; the text files are easier to edit and review
build=../../build/app-store/metadata
rm -rf $build
mkdir -p $build/app-info $build/version/$version
for locale in metadata/*(/:t); do
  app_info=() version_info=()
  for key file in name name subtitle subtitle privacyPolicyUrl privacy_url; do
    [[ -f metadata/$locale/$file.txt ]] && app_info+=(--rawfile $key metadata/$locale/$file.txt)
  done
  for key file in description description keywords keywords supportUrl support_url \
    marketingUrl marketing_url promotionalText promotional_text whatsNew whats_new; do
    [[ -f metadata/$locale/$file.txt ]] && version_info+=(--rawfile $key metadata/$locale/$file.txt)
  done
  jq -n $app_info '$ARGS.named | map_values(sub("\\s+$"; ""))' > $build/app-info/$locale.json
  jq -n $version_info '$ARGS.named | map_values(sub("\\s+$"; ""))' > $build/version/$version/$locale.json
done
asc metadata validate --dir $build --output table
(( check )) && exit 0

pngs=(out/{iphone,ipad,mac}/*.png(N))
if (( screenshots && ! ${#pngs} )); then
  print -u2 "No screenshots in out/, run render.sh first or pass --skip-screenshots."
  exit 1
fi

app=${ASC_APP_ID:-$(asc apps list --bundle-id de.andreas-sk.meh-md --output json | jq -er '.data[0].id')}
if (( confirm )); then
  apply_mode=() upload_mode=(--confirm)
  print "Publishing version $version of app $app"
else
  apply_mode=(--dry-run) upload_mode=(--dry-run)
  print "Dry run for version $version of app $app"
fi
# While a version is live, App Store Connect keeps a second app info for the
# next one, and only that one takes changes. asc refuses to guess between them.
app_info_id=$(asc apps info list --app $app --output json | jq -r '[.data[]
  | select(.attributes.state | IN("READY_FOR_DISTRIBUTION", "REPLACED_WITH_NEW_INFO") | not)]
  | first | .id // empty')
app_info_flag=()
[[ -n $app_info_id ]] && app_info_flag=(--app-info $app_info_id)

failed=()
typeset -A platform_devices=(IOS "iphone ipad" MAC_OS "mac")
typeset -A display_type=(iphone IPHONE_69 ipad IPAD_PRO_3GEN_129 mac DESKTOP)
for platform in $platforms; do
  print "\n== $platform"
  # Apple allows one version in preparation per platform. Reuse it and give it
  # the app's version, so it always matches the build that gets submitted.
  editable=$(asc versions list --app $app --platform $platform --paginate --output json \
    | jq -r '[.data[] | select(.attributes.appStoreState | IN("PREPARE_FOR_SUBMISSION",
        "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"))]
      | first | select(.) | "\(.id) \(.attributes.versionString)"')
  target=$version
  if [[ -z $editable ]]; then
    if (( ! confirm )); then
      print "Would create App Store version $version, can't preview further without it."
      continue
    fi
    asc versions create --app $app --version $version --platform $platform --release-type AFTER_APPROVAL --output table
  elif [[ ${editable#* } != $version ]]; then
    if (( confirm )); then
      asc versions update --version-id ${editable% *} --version $version --output table
    else
      print "Would rename App Store version ${editable#* } to $version."
      target=${editable#* }
    fi
  fi

  # Fields without a file in metadata/ stay as they are in App Store Connect
  [[ $target == $version ]] || cp -R $build/version/$version $build/version/$target
  asc metadata apply --app $app --version $target --platform $platform --dir $build \
    $app_info_flag $apply_mode --output table

  (( screenshots )) || continue
  for locale in metadata/*(/:t); do
    for device in ${=platform_devices[$platform]}; do
      asc screenshots upload --app $app --version $target --platform $platform \
        --locale $locale --path out/$device --device-type ${display_type[$device]} \
        --replace $upload_mode --output table || failed+=("$platform $locale $device")
    done
  done
done

if (( ${#failed} )); then
  print -u2 "\nScreenshots failed for: ${(j:, :)failed}. Run the script again."
  exit 1
fi
