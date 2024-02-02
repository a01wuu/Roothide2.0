#include <stdlib.h>
#include <libjailbreak/util.h>
#include <libjailbreak/trustcache.h>
#include <xpc/xpc.h>
#include <dlfcn.h>

#import <Foundation/Foundation.h>

void abort_with_reason(uint32_t reason_namespace, uint64_t reason_code, const char *reason_string, uint64_t reason_flags);

int jbupdate_basebin(const char *basebinTarPath)
{
	@autoreleasepool {
		int r = 0;
		if (access(basebinTarPath, F_OK) != 0) return 1;

		NSString *prevVersion = [NSString stringWithContentsOfFile:NSJBRootPath(@"/basebin/.version") encoding:NSUTF8StringEncoding error:nil] ?: @"2.0";

		// Extract basebin tar
		NSString *tmpExtractionPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
		r = libarchive_unarchive(basebinTarPath, tmpExtractionPath.fileSystemRepresentation);
		if (r != 0) {
			[[NSFileManager defaultManager] removeItemAtPath:tmpExtractionPath error:nil];
			return 2;
		}
		NSString *tmpBasebinPath = [tmpExtractionPath stringByAppendingPathComponent:@"basebin"];

		// Update basebin trustcache
		NSString *trustcachePath = [tmpBasebinPath stringByAppendingPathComponent:@"basebin.tc"];
		if (![[NSFileManager defaultManager] fileExistsAtPath:trustcachePath]) return 3;
		trustcache_file_v1 *basebinTcFile = NULL;
		if (trustcache_file_build_from_path(trustcachePath.fileSystemRepresentation, &basebinTcFile) != 0) {
			[[NSFileManager defaultManager] removeItemAtPath:tmpExtractionPath error:nil];
			return 4;
		}
		r = trustcache_file_upload_with_uuid(basebinTcFile, BASEBIN_TRUSTCACHE_UUID);
		free(basebinTcFile);
		if (r != 0) {
			[[NSFileManager defaultManager] removeItemAtPath:tmpExtractionPath error:nil];
			return 5;
		}
		else {
			[[NSFileManager defaultManager] removeItemAtPath:trustcachePath error:nil];
		}

		// Replace basebin content
		NSArray *newBasebinContents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:tmpBasebinPath error:nil];
		for (NSString *basebinItem in newBasebinContents) {
			NSString *newBasebinPath = [tmpBasebinPath stringByAppendingPathComponent:basebinItem];
			NSString *oldBasebinPath = [NSJBRootPath(@"basebin") stringByAppendingPathComponent:basebinItem];
			if ([[NSFileManager defaultManager] fileExistsAtPath:oldBasebinPath]) {
				[[NSFileManager defaultManager] removeItemAtPath:oldBasebinPath error:nil];
			}
			[[NSFileManager defaultManager] copyItemAtPath:newBasebinPath toPath:oldBasebinPath error:nil];
		}
		[[NSFileManager defaultManager] removeItemAtPath:tmpExtractionPath error:nil];

		// Update systemhook in fakelib
		[[NSFileManager defaultManager] copyItemAtPath:NSJBRootPath(@"basebin/systemhook.dylib") toPath:NSJBRootPath(@"basebin/.fakelib/systemhook.dylib") error:nil];

		NSString *newVersion = [NSString stringWithContentsOfFile:NSJBRootPath(@"/basebin/.version") encoding:NSUTF8StringEncoding error:nil];
		if (!newVersion) return 6;

		setenv("JBUPDATE_PREV_VERSION", prevVersion.UTF8String, 1);
		setenv("JBUPDATE_NEW_VERSION", newVersion.UTF8String, 1);
		return 0;
	}
}

void jbupdate_update_system_info(void)
{
	@autoreleasepool {
		// Load XPF
		void *xpfHandle = dlopen("@loader_path/libxpf.dylib", RTLD_NOW);
		if (!xpfHandle) {
			char msg[4000];
			snprintf(msg, 4000, "Dopamine: dlopening libxpf failed: (%s), cannot continue.", dlerror());
			abort_with_reason(7, 1, msg, 0);
			return;
		}
		int (*xpf_start_with_kernel_path)(const char *kernelPath) = dlsym(xpfHandle, "xpf_start_with_kernel_path");
		const char *(*xpf_get_error)(void) = dlsym(xpfHandle, "xpf_get_error");
		bool (*xpf_set_is_supported)(const char *name) = dlsym(xpfHandle, "xpf_set_is_supported");
		void (*xpf_stop)(void) = dlsym(xpfHandle, "xpf_stop");
		xpc_object_t (*xpf_construct_offset_dictionary)(const char *sets[]) = dlsym(xpfHandle, "xpf_construct_offset_dictionary");

		// XXX: this is a hack
		const char *kernelPath = JBRootPath("/../../System/Library/Caches/com.apple.kernelcaches/kernelcache");
		xpc_object_t systemInfoXdict = NULL;

		// Rerun patchfinder
		int r = xpf_start_with_kernel_path(kernelPath);
		const char *error = NULL;
		if (r == 0) {
			const char *sets[] = {
				"translation",
				"trustcache",
				"physmap",
				"struct",
				"physrw",
				"perfkrw",
				"badRecovery",
				NULL
			};
			
			if (!xpf_set_is_supported("badRecovery")) {
				sets[(sizeof(sets)/sizeof(sets[0]))-2] = NULL;
			}
			systemInfoXdict = xpf_construct_offset_dictionary(sets);
			if (!systemInfoXdict) {
				error = xpf_get_error();
			}
			xpf_stop();
		}
		else {
			xpf_stop();
			error = xpf_get_error();
		}

		if (error) {
			char msg[4000];
			snprintf(msg, 4000, "Dopamine: Updating system info via XPF failed with error: (%s), cannot continue.", error);
			abort_with_reason(7, 1, msg, 0);
			return;
		}

		dlclose(xpfHandle);

		// Get stuff that won't change from current info
		xpc_dictionary_set_uint64(systemInfoXdict, "kernelConstant.staticBase", kconstant(staticBase));
		xpc_dictionary_set_uint64(systemInfoXdict, "kernelConstant.slide", kconstant(slide));
		xpc_dictionary_set_uint64(systemInfoXdict, "kernelConstant.base", kconstant(base));
		xpc_dictionary_set_uint64(systemInfoXdict, "kernelConstant.virtBase", kconstant(virtBase));
		xpc_dictionary_set_uint64(systemInfoXdict, "kernelConstant.physBase", kconstant(physBase));
		xpc_dictionary_set_uint64(systemInfoXdict, "kernelConstant.physSize", kconstant(physSize));
		xpc_dictionary_set_uint64(systemInfoXdict, "kernelConstant.cpuTTEP", kconstant(cpuTTEP));
		xpc_dictionary_set_bool(systemInfoXdict, "jailbreakInfo.usesPACBypass", jbinfo(usesPACBypass));
		xpc_dictionary_set_string(systemInfoXdict, "jailbreakInfo.rootPath", jbinfo(rootPath));

		// Rebuild gSystemInfo
		jbinfo_initialize_dynamic_offsets(systemInfoXdict);
		jbinfo_initialize_hardcoded_offsets();
	}
}

// Before primitives are retrieved
void jbupdate_finalize_stage1(const char *prevVersion, const char *newVersion)
{
	// Currently unused, reserved for the future
}

// After primitives are retrieved
void jbupdate_finalize_stage2(const char *prevVersion, const char *newVersion)
{
	jbupdate_update_system_info();
}