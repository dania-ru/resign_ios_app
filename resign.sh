#!/bin/bash

usage ()
{
    echo "-i|--input           - input file or folder"
    echo "-c|--certificate     - certificate's name, should be in keychains"
    echo "-m|--mobileprovision - path to mobile provision file"
    echo "-o|--output          - output path. Optional. [input]_RES is default"
    echo "-p|--password        - user password to unlock keychains. Optional"
    echo ""
    echo "There is an option to configure certificate and mobileprovision."
    echo "Create file ~/.resign/[your_name] with these properties."
    echo "Set R_A environment variable to your property file name."
    echo ""
    echo "Example:"
    echo "File path: ~/.resign/my_account"
    echo ""
    echo "File content:"
    echo "certificate=iPhone Developer: Ivan Nabokov (2GHYFZ4MS5)"
    echo "mobileprovision=/Users/name/Library/MobileDevice/Provisioning Profiles/bdhhhhd5-3crr-4dc9-88jj-1d1318f7584d.mobileprovision"
    echo ""
    echo "Set environment: export R_A=my_account"
}

while [ "$1" != "" ]
do
key="$1"

case $key in
-i|--input)
INPUT="$2"
shift # past argument
;;
-c|--certificate)
CERTIFICATE="$2"
shift # past argument
;;
-m|--mobileprovision)
MOBILEPROVISION="$2"
shift # past argument
;;
-o|--output)
OUTPUT="$2"
shift # past argument
;;
-p|--password)
PASSWORD="$2"
shift # past argument
;;
-h|--help)
usage
exit 0
;;
*)
# unknown option
echo "UNKNOWN OPTION"
usage
exit 1
;;
esac
shift # past argument or value
done

# vars
IS_IPA=0

checkrc ()
{
    if [ $? -ne 0 ]
        then
            echo "ERROR!"
            rm -rf "$TEMP_DIR"
            exit 1
    fi
}

check_file_exists ()
{
    if [ ! -e "$1" ]; then
        echo "ERROR: File $1 not exists!"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
}

init_is_ipa ()
{
    if [ ${1: -4} == ".ipa" ]; then
        echo "===== .ipa received as input ===================="
        IS_IPA=1
    fi
}

init_output ()
{
    # default output
    if [[ -z "$OUTPUT" ]];
    then
        OUTPUT=`pwd`
        if [[ "$IS_IPA" -eq "1" ]]
        then
            OUTPUT_FILE_NAME=`basename $INPUT .ipa`
            OUTPUT_FILE_NAME="$OUTPUT_FILE_NAME"_RES.ipa
        else
            OUTPUT_FILE_NAME=`basename $INPUT .app`
            OUTPUT_FILE_NAME="$OUTPUT_FILE_NAME"_RES.app
        fi

        OUTPUT="$OUTPUT/$OUTPUT_FILE_NAME"
        echo "===== output not specified, going to save a result in a default file ${OUTPUT}"
    fi
}

# read property name ($1) from config file
read_prop_from_config_file ()
{
    if [[ -z "$R_A" ]];
    then
        echo "ERROR: parameter $1 is missing and configuration file not specified."
        exit 1
    fi
    
    if [[ -f ~/.resign/"$R_A" ]]
    then
        grep "${1}" ~/.resign/$R_A|cut -d'=' -f2
    else
        echo "ERROR: $1 not received and configuration file ~/.resign/$R_A not found!"
        exit 1
    fi
}

# validate input parameter
check_file_exists $INPUT

# is input .ipa
init_is_ipa $INPUT

if [[ -z "$CERTIFICATE" ]]; then
    CERTIFICATE=`read_prop_from_config_file certificate`
fi

if [[ -z "$MOBILEPROVISION" ]]; then
    MOBILEPROVISION=`read_prop_from_config_file mobileprovision`
fi

# decide where to save re-signed stuff
init_output

echo "================================================="
echo "INPUT                 = ${INPUT}"
echo "OUTPUT                = ${OUTPUT}"
echo "CERTIFICATE           = ${CERTIFICATE}"
echo "MOBILEPROVISION       = ${MOBILEPROVISION}"
echo "================================================="

# working in the temp dir
# creating temp dir
TEMP_DIR=`mktemp -d`
echo "===== temp dir created at $TEMP_DIR"

# unziping and copying bundle to the temp dir
echo "===== unziping =================================="
if [[ "$IS_IPA" -eq "1" ]]
then
    unzip -q "$INPUT" -d "$TEMP_DIR"
    checkrc
    cp -R "$TEMP_DIR"/Payload/* "$TEMP_DIR"
    checkrc
    rm -rf "$TEMP_DIR"/__MACOSX
    rm -rf "$TEMP_DIR"/Payload
else
    # remove trailing slash if exists
    APP_PATH=`echo ${INPUT%/}`
    cp -R "$APP_PATH" "$TEMP_DIR"
    checkrc
fi

APP_NAME=$(ls "$TEMP_DIR" | grep ".app")
APP_PATH="$TEMP_DIR"/"$APP_NAME"

# extracting bundle's exe name
EXEC_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP_PATH"/Info.plist)

echo "================================================="
echo APP_PATH  - "$APP_PATH"
echo EXEC_NAME - "$EXEC_NAME"
echo "================================================="


# remove the old signature
echo "===== deleting old signature ===================="
rm -r "$APP_PATH"/_CodeSignature/

# generate entitilements.plist
echo "===== generating entitilements =================="
security cms -D -i "$MOBILEPROVISION" > "$TEMP_DIR"/ProvisionProfile.plist 2>&1

checkrc
/usr/libexec/PlistBuddy -x -c "Print Entitlements" "$TEMP_DIR"/ProvisionProfile.plist > "$TEMP_DIR"/entitlements.plist 2>&1

KEYCHAIN_ACCESS=$(/usr/libexec/PlistBuddy -c "Print :keychain-access-groups:0" "$TEMP_DIR"/entitlements.plist)
APP_ID=$(/usr/libexec/PlistBuddy -c "Print :application-identifier" "$TEMP_DIR"/entitlements.plist)

KEYCHAIN_ACCESS="${KEYCHAIN_ACCESS%?}""$EXEC_NAME"
/usr/libexec/PlistBuddy -c "Set :keychain-access-groups:0 $KEYCHAIN_ACCESS" "$TEMP_DIR"/entitlements.plist

if [ "${APP_ID: -1}" == "*" ]; then
    APP_ID="${APP_ID%?}""$EXEC_NAME"
    /usr/libexec/PlistBuddy -c "Set :application-identifier $APP_ID" "$TEMP_DIR"/entitlements.plist
fi

# replace the provision
echo "===== coping new mobileprovision ==============="
cp "$MOBILEPROVISION"  "$APP_PATH"/embedded.mobileprovision

checkrc

# unlock keychains
echo "===== resigning ================================="
USER_NAME=`id -un`
KEYCHAIN=/Users/$USER_NAME/Library/Keychains/login.keychain

security -v list-keychains -d system -s $KEYCHAIN
security -v unlock-keychain -p $USER_PASSWORD $KEYCHAIN

XC_EXEC_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP_PATH"/PlugIns/*/Info.plist)
echo "$XC_EXEC_NAME"

# sign with the new certificate
codesign -f -s "$CERTIFICATE" --entitlements "$TEMP_DIR"/entitlements.plist "$APP_PATH"/PlugIns/*/"$XC_EXEC_NAME"
codesign -f -s "$CERTIFICATE" "$APP_PATH"/PlugIns/*/Frameworks/*/Frameworks/*
codesign -f -s "$CERTIFICATE" "$APP_PATH"/PlugIns/*/Frameworks/*
codesign -f -s "$CERTIFICATE" --entitlements "$TEMP_DIR"/entitlements.plist "$APP_PATH"/"$EXEC_NAME"
checkrc
codesign -f -s "$CERTIFICATE" "$APP_PATH"/Frameworks/*
codesign -f -s "$CERTIFICATE" "$APP_PATH"/PlugIns/*
codesign -f -s "$CERTIFICATE" --entitlements "$TEMP_DIR"/entitlements.plist "$APP_PATH"/

# output
echo "===== archiving to ${OUTPUT} ======================"
if [[ "$IS_IPA" -eq "1" ]]
then
    mkdir $TEMP_DIR/Payload
    cp -rf "$APP_PATH" "$TEMP_DIR"/Payload
    cd "$TEMP_DIR"
    zip -qry "$OUTPUT" Payload
    checkrc
else
    cp -rf "$APP_PATH" "$OUTPUT"
    checkrc
fi

# clean temp dir
echo "===== removing temp dir ========================"
rm -rf "$TEMP_DIR"

exit 0
