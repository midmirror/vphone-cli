/*
 * vphoned_app — IPA application installation support.
 *
 * Handles IPA extraction, optional ldid re-signing, and installation
 * via LSApplicationWorkspace private API. IPA files are extracted to
 * /tmp/<UUID>/ and cleaned up after installation completes.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Extract an IPA file to a temporary directory.
/// Returns the full path to the Payload/*.app bundle on success, or nil on failure.
/// On failure, *outError is set to a dictionary with "msg" describing the error.
NSString *vp_app_extract_ipa(NSString *ipaPath, NSDictionary **outError);

/// Install an extracted .app bundle via LSApplicationWorkspace private API.
/// Returns the installed bundle identifier on success, or nil on failure.
/// On failure, *outError is set with the iOS system error description.
/// On success, also refreshes SpringBoard icon cache.
NSString *vp_app_install(NSString *appPath, NSDictionary **outError);

/// Handle the "app_install" command: extract IPA → install → cleanup.
/// Returns a response dictionary (ok or err) suitable for sending back over the protocol.
NSDictionary *vp_handle_app_install(NSDictionary *msg, id reqId);

/// Clean up a temporary extraction directory and optionally the source IPA file.
void vp_app_cleanup(NSString *extractDir);
void vp_app_cleanup_ipa(NSString *extractDir, NSString *ipaPath);
