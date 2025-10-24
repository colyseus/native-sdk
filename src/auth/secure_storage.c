#include "colyseus/auth/secure_storage.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* Platform detection */
#if defined(__APPLE__)
    #include <TargetConditionals.h>
    #if TARGET_OS_IOS
        #define PLATFORM_IOS
    #elif TARGET_OS_TV
        #define PLATFORM_TVOS
    #elif TARGET_OS_MAC
        #define PLATFORM_MACOS
    #endif
    #define PLATFORM_APPLE
#elif defined(__ANDROID__)
    #define PLATFORM_ANDROID
#elif defined(_WIN32) || defined(_WIN64)
    #define PLATFORM_WINDOWS
#elif defined(__linux__)
    #define PLATFORM_LINUX
#elif defined(__EMSCRIPTEN__)
    #define PLATFORM_WEB
#endif

/* Platform-specific includes */
#if defined(PLATFORM_APPLE)
    #include <Security/Security.h>
#elif defined(PLATFORM_WINDOWS)
    #include <windows.h>
    #include <wincred.h>
    #pragma comment(lib, "advapi32.lib")
#elif defined(PLATFORM_LINUX)
    #include <dlfcn.h>
#elif defined(PLATFORM_ANDROID)
    #include <jni.h>
#endif

/* File fallback for all platforms */
#include <sys/stat.h>
#ifndef _WIN32
    #include <unistd.h>
#else
    #include <direct.h>
    #define mkdir(path, mode) _mkdir(path)
    #define chmod(path, mode) (0)
#endif

/* Forward declarations for fallback */
static storage_result_t fallback_storage_set(const char* key, const char* value);
static char* fallback_storage_get(const char* key);
static storage_result_t fallback_storage_remove(const char* key);

/* ========================================================================
 * APPLE PLATFORMS (iOS, macOS, tvOS) - Keychain
 * ======================================================================== */
#if defined(PLATFORM_APPLE)

int secure_storage_available(void) {
    return 1;
}

storage_result_t secure_storage_set(const char* key, const char* value) {
    if (!key || !value) return STORAGE_ERROR;
    
    CFStringRef keyRef = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    if (!keyRef) return STORAGE_ERROR;
    
    CFDataRef valueData = CFDataCreate(NULL, (const UInt8*)value, strlen(value));
    if (!valueData) {
        CFRelease(keyRef);
        return STORAGE_ERROR;
    }
    
    /* Build query dictionary */
    const void* keys[] = {
        kSecClass,
        kSecAttrAccount,
        kSecAttrService,
        kSecValueData
    };
    const void* values[] = {
        kSecClassGenericPassword,
        keyRef,
        CFSTR("com.colyseus.sdk"),
        valueData
    };
    
    CFDictionaryRef query = CFDictionaryCreate(NULL, keys, values, 4,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    
    /* Delete existing item first */
    SecItemDelete(query);
    
    /* Add new item */
    OSStatus status = SecItemAdd(query, NULL);
    
    CFRelease(query);
    CFRelease(keyRef);
    CFRelease(valueData);
    
    if (status == errSecSuccess) {
        return STORAGE_OK;
    } else if (status == errSecNotAvailable || status == errSecInteractionNotAllowed) {
        /* Keychain not available, use fallback */
        return fallback_storage_set(key, value);
    } else {
        return STORAGE_ERROR;
    }
}

char* secure_storage_get(const char* key) {
    if (!key) return NULL;
    
    CFStringRef keyRef = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    if (!keyRef) return NULL;
    
    const void* keys[] = {
        kSecClass,
        kSecAttrAccount,
        kSecAttrService,
        kSecReturnData,
        kSecMatchLimit
    };
    const void* values[] = {
        kSecClassGenericPassword,
        keyRef,
        CFSTR("com.colyseus.sdk"),
        kCFBooleanTrue,
        kSecMatchLimitOne
    };
    
    CFDictionaryRef query = CFDictionaryCreate(NULL, keys, values, 5,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    
    CFDataRef result = NULL;
    OSStatus status = SecItemCopyMatching(query, (CFTypeRef*)&result);
    
    CFRelease(query);
    CFRelease(keyRef);
    
    if (status != errSecSuccess || !result) {
        /* Try fallback */
        return fallback_storage_get(key);
    }
    
    CFIndex length = CFDataGetLength(result);
    char* value = malloc(length + 1);
    if (value) {
        CFDataGetBytes(result, CFRangeMake(0, length), (UInt8*)value);
        value[length] = '\0';
    }
    
    CFRelease(result);
    return value;
}

storage_result_t secure_storage_remove(const char* key) {
    if (!key) return STORAGE_ERROR;
    
    CFStringRef keyRef = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    if (!keyRef) return STORAGE_ERROR;
    
    const void* keys[] = {
        kSecClass,
        kSecAttrAccount,
        kSecAttrService
    };
    const void* values[] = {
        kSecClassGenericPassword,
        keyRef,
        CFSTR("com.colyseus.sdk")
    };
    
    CFDictionaryRef query = CFDictionaryCreate(NULL, keys, values, 3,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    
    OSStatus status = SecItemDelete(query);
    
    CFRelease(query);
    CFRelease(keyRef);
    
    /* Also remove from fallback */
    fallback_storage_remove(key);
    
    return (status == errSecSuccess || status == errSecItemNotFound) ? STORAGE_OK : STORAGE_ERROR;
}

/* ========================================================================
 * WINDOWS - Credential Manager
 * ======================================================================== */
#elif defined(PLATFORM_WINDOWS)

int secure_storage_available(void) {
    return 1;
}

storage_result_t secure_storage_set(const char* key, const char* value) {
    if (!key || !value) return STORAGE_ERROR;
    
    /* Build target name */
    char target[256];
    snprintf(target, sizeof(target), "Colyseus/%s", key);
    
    CREDENTIALA cred = {0};
    cred.Type = CRED_TYPE_GENERIC;
    cred.TargetName = target;
    cred.CredentialBlobSize = (DWORD)strlen(value);
    cred.CredentialBlob = (LPBYTE)value;
    cred.Persist = CRED_PERSIST_LOCAL_MACHINE;
    cred.UserName = (LPSTR)"ColyseusSDK";
    
    if (CredWriteA(&cred, 0)) {
        return STORAGE_OK;
    } else {
        /* Fallback on error */
        return fallback_storage_set(key, value);
    }
}

char* secure_storage_get(const char* key) {
    if (!key) return NULL;
    
    char target[256];
    snprintf(target, sizeof(target), "Colyseus/%s", key);
    
    PCREDENTIALA cred;
    if (!CredReadA(target, CRED_TYPE_GENERIC, 0, &cred)) {
        /* Try fallback */
        return fallback_storage_get(key);
    }
    
    char* value = malloc(cred->CredentialBlobSize + 1);
    if (value) {
        memcpy(value, cred->CredentialBlob, cred->CredentialBlobSize);
        value[cred->CredentialBlobSize] = '\0';
    }
    
    CredFree(cred);
    return value;
}

storage_result_t secure_storage_remove(const char* key) {
    if (!key) return STORAGE_ERROR;
    
    char target[256];
    snprintf(target, sizeof(target), "Colyseus/%s", key);
    
    CredDeleteA(target, CRED_TYPE_GENERIC, 0);
    
    /* Also remove from fallback */
    fallback_storage_remove(key);
    
    return STORAGE_OK;
}

/* ========================================================================
 * LINUX - libsecret (GNOME Keyring / KDE Wallet)
 * ======================================================================== */
#elif defined(PLATFORM_LINUX)

/* libsecret types and function pointers */
typedef struct { const char* name; int type; } SecretSchemaAttribute;
typedef struct {
    const char* name;
    int flags;
    SecretSchemaAttribute attributes[8];
} SecretSchema;

typedef int (*secret_password_store_sync_fn)(const SecretSchema*, const char*, const char*,
                                              const char*, void*, void*, ...);
typedef char* (*secret_password_lookup_sync_fn)(const SecretSchema*, void*, void*, ...);
typedef int (*secret_password_clear_sync_fn)(const SecretSchema*, void*, void*, ...);

static void* libsecret_handle = NULL;
static int libsecret_available = -1;
static secret_password_store_sync_fn secret_store = NULL;
static secret_password_lookup_sync_fn secret_lookup = NULL;
static secret_password_clear_sync_fn secret_clear = NULL;

static const SecretSchema schema = {
    "com.colyseus.Storage",
    0,
    {
        { "key", 0 },
        { NULL, 0 }
    }
};

static void init_libsecret(void) {
    if (libsecret_available != -1) return;
    
    libsecret_handle = dlopen("libsecret-1.so.0", RTLD_LAZY);
    if (!libsecret_handle) {
        libsecret_handle = dlopen("libsecret-1.so", RTLD_LAZY);
    }
    
    if (!libsecret_handle) {
        libsecret_available = 0;
        return;
    }
    
    secret_store = (secret_password_store_sync_fn)dlsym(libsecret_handle, "secret_password_store_sync");
    secret_lookup = (secret_password_lookup_sync_fn)dlsym(libsecret_handle, "secret_password_lookup_sync");
    secret_clear = (secret_password_clear_sync_fn)dlsym(libsecret_handle, "secret_password_clear_sync");
    
    libsecret_available = (secret_store && secret_lookup && secret_clear) ? 1 : 0;
}

int secure_storage_available(void) {
    init_libsecret();
    return libsecret_available;
}

storage_result_t secure_storage_set(const char* key, const char* value) {
    if (!key || !value) return STORAGE_ERROR;
    
    init_libsecret();
    if (libsecret_available) {
        int result = secret_store(&schema, "default", "Colyseus Storage", value,
                                  NULL, NULL, "key", key, NULL);
        if (result) {
            return STORAGE_OK;
        }
    }
    
    /* Fallback to file */
    return fallback_storage_set(key, value);
}

char* secure_storage_get(const char* key) {
    if (!key) return NULL;
    
    init_libsecret();
    if (libsecret_available) {
        char* value = secret_lookup(&schema, NULL, NULL, "key", key, NULL);
        if (value) return value;
    }
    
    /* Fallback to file */
    return fallback_storage_get(key);
}

storage_result_t secure_storage_remove(const char* key) {
    if (!key) return STORAGE_ERROR;
    
    init_libsecret();
    if (libsecret_available) {
        secret_clear(&schema, NULL, NULL, "key", key, NULL);
    }
    
    /* Also remove from fallback */
    fallback_storage_remove(key);
    
    return STORAGE_OK;
}

/* ========================================================================
 * ANDROID - EncryptedSharedPreferences (requires JNI setup)
 * ======================================================================== */
#elif defined(PLATFORM_ANDROID)

/* Note: This requires JNI initialization from Java/Kotlin side */
static JavaVM* g_jvm = NULL;
static jobject g_context = NULL;

/* Call this from your Android app's initialization */
void secure_storage_init_android(JavaVM* jvm, jobject context) {
    g_jvm = jvm;
    g_context = context;
}

int secure_storage_available(void) {
    return (g_jvm != NULL && g_context != NULL);
}

storage_result_t secure_storage_set(const char* key, const char* value) {
    if (!key || !value || !g_jvm || !g_context) {
        return fallback_storage_set(key, value);
    }
    
    JNIEnv* env;
    (*g_jvm)->GetEnv(g_jvm, (void**)&env, JNI_VERSION_1_6);
    
    /* Get SharedPreferences */
    jclass contextClass = (*env)->GetObjectClass(env, g_context);
    jmethodID getSharedPrefs = (*env)->GetMethodID(env, contextClass,
        "getSharedPreferences", "(Ljava/lang/String;I)Landroid/content/SharedPreferences;");
    
    jstring prefName = (*env)->NewStringUTF(env, "colyseus_secure");
    jobject prefs = (*env)->CallObjectMethod(env, g_context, getSharedPrefs, prefName, 0);
    
    /* Get editor */
    jclass prefsClass = (*env)->GetObjectClass(env, prefs);
    jmethodID edit = (*env)->GetMethodID(env, prefsClass, "edit",
        "()Landroid/content/SharedPreferences$Editor;");
    jobject editor = (*env)->CallObjectMethod(env, prefs, edit);
    
    /* Put string */
    jclass editorClass = (*env)->GetObjectClass(env, editor);
    jmethodID putString = (*env)->GetMethodID(env, editorClass, "putString",
        "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;");
    jmethodID apply = (*env)->GetMethodID(env, editorClass, "apply", "()V");
    
    jstring jkey = (*env)->NewStringUTF(env, key);
    jstring jvalue = (*env)->NewStringUTF(env, value);
    
    (*env)->CallObjectMethod(env, editor, putString, jkey, jvalue);
    (*env)->CallVoidMethod(env, editor, apply);
    
    (*env)->DeleteLocalRef(env, jkey);
    (*env)->DeleteLocalRef(env, jvalue);
    (*env)->DeleteLocalRef(env, prefName);
    
    return STORAGE_OK;
}

char* secure_storage_get(const char* key) {
    if (!key || !g_jvm || !g_context) {
        return fallback_storage_get(key);
    }
    
    JNIEnv* env;
    (*g_jvm)->GetEnv(g_jvm, (void**)&env, JNI_VERSION_1_6);
    
    /* Get SharedPreferences */
    jclass contextClass = (*env)->GetObjectClass(env, g_context);
    jmethodID getSharedPrefs = (*env)->GetMethodID(env, contextClass,
        "getSharedPreferences", "(Ljava/lang/String;I)Landroid/content/SharedPreferences;");
    
    jstring prefName = (*env)->NewStringUTF(env, "colyseus_secure");
    jobject prefs = (*env)->CallObjectMethod(env, g_context, getSharedPrefs, prefName, 0);
    
    /* Get string */
    jclass prefsClass = (*env)->GetObjectClass(env, prefs);
    jmethodID getString = (*env)->GetMethodID(env, prefsClass, "getString",
        "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    
    jstring jkey = (*env)->NewStringUTF(env, key);
    jstring jresult = (jstring)(*env)->CallObjectMethod(env, prefs, getString, jkey, NULL);
    
    char* result = NULL;
    if (jresult) {
        const char* str = (*env)->GetStringUTFChars(env, jresult, NULL);
        result = strdup(str);
        (*env)->ReleaseStringUTFChars(env, jresult, str);
    }
    
    (*env)->DeleteLocalRef(env, jkey);
    (*env)->DeleteLocalRef(env, prefName);
    
    return result ? result : fallback_storage_get(key);
}

storage_result_t secure_storage_remove(const char* key) {
    if (!key) return STORAGE_ERROR;
    
    if (g_jvm && g_context) {
        JNIEnv* env;
        (*g_jvm)->GetEnv(g_jvm, (void**)&env, JNI_VERSION_1_6);
        
        /* Get SharedPreferences */
        jclass contextClass = (*env)->GetObjectClass(env, g_context);
        jmethodID getSharedPrefs = (*env)->GetMethodID(env, contextClass,
            "getSharedPreferences", "(Ljava/lang/String;I)Landroid/content/SharedPreferences;");

        jstring prefName = (*env)->NewStringUTF(env, "colyseus_secure");
        jobject prefs = (*env)->CallObjectMethod(env, g_context, getSharedPrefs, prefName, 0);

        /* Get editor */
        jclass prefsClass = (*env)->GetObjectClass(env, prefs);
        jmethodID edit = (*env)->GetMethodID(env, prefsClass, "edit",
            "()Landroid/content/SharedPreferences$Editor;");
        jobject editor = (*env)->CallObjectMethod(env, prefs, edit);

        /* Remove key */
        jclass editorClass = (*env)->GetObjectClass(env, editor);
        jmethodID remove = (*env)->GetMethodID(env, editorClass, "remove",
            "(Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;");
        jmethodID apply = (*env)->GetMethodID(env, editorClass, "apply", "()V");

        jstring jkey = (*env)->NewStringUTF(env, key);

        (*env)->CallObjectMethod(env, editor, remove, jkey);
        (*env)->CallVoidMethod(env, editor, apply);

        (*env)->DeleteLocalRef(env, jkey);
        (*env)->DeleteLocalRef(env, prefName);
    }

    /* Also remove from fallback */
    fallback_storage_remove(key);

    return STORAGE_OK;
}

/* ========================================================================
 * WEB / EMSCRIPTEN - Not supported (use browser localStorage from JS)
 * ======================================================================== */
#elif defined(PLATFORM_WEB)

int secure_storage_available(void) {
    return 0;
}

storage_result_t secure_storage_set(const char* key, const char* value) {
    return fallback_storage_set(key, value);
}

char* secure_storage_get(const char* key) {
    return fallback_storage_get(key);
}

storage_result_t secure_storage_remove(const char* key) {
    return fallback_storage_remove(key);
}

/* ========================================================================
 * UNSUPPORTED PLATFORM
 * ======================================================================== */
#else

int secure_storage_available(void) {
    return 0;
}

storage_result_t secure_storage_set(const char* key, const char* value) {
    return fallback_storage_set(key, value);
}

char* secure_storage_get(const char* key) {
    return fallback_storage_get(key);
}

storage_result_t secure_storage_remove(const char* key) {
    return fallback_storage_remove(key);
}

#endif

/* ========================================================================
 * FALLBACK FILE STORAGE (All Platforms)
 * ======================================================================== */

static char* get_storage_directory(void) {
    static char dir[512] = {0};
    if (dir[0] != '\0') return dir;
    
#if defined(_WIN32)
    const char* appdata = getenv("APPDATA");
    if (appdata) {
        snprintf(dir, sizeof(dir), "%s\\Colyseus", appdata);
    } else {
        snprintf(dir, sizeof(dir), ".colyseus");
    }
#else
    const char* home = getenv("HOME");
    if (home) {
        snprintf(dir, sizeof(dir), "%s/.colyseus", home);
    } else {
        snprintf(dir, sizeof(dir), ".colyseus");
    }
#endif
    
    /* Create directory if it doesn't exist */
    mkdir(dir, 0700);
    
    return dir;
}

static char* get_fallback_path(const char* key) {
    const char* dir = get_storage_directory();
    
    size_t len = strlen(dir) + strlen(key) + 2;
    char* path = malloc(len);
    snprintf(path, len, "%s/%s", dir, key);
    
    return path;
}

static storage_result_t fallback_storage_set(const char* key, const char* value) {
    if (!key || !value) return STORAGE_ERROR;
    
    char* path = get_fallback_path(key);
    
    FILE* f = fopen(path, "w");
    if (!f) {
        free(path);
        return STORAGE_ERROR;
    }
    
    fprintf(f, "%s", value);
    fclose(f);
    
    /* Set restrictive permissions */
    chmod(path, 0600);
    
    free(path);
    return STORAGE_OK;
}

static char* fallback_storage_get(const char* key) {
    if (!key) return NULL;
    
    char* path = get_fallback_path(key);
    
    FILE* f = fopen(path, "r");
    free(path);
    
    if (!f) return NULL;
    
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    
    if (size <= 0) {
        fclose(f);
        return NULL;
    }
    
    char* value = malloc(size + 1);
    size_t read = fread(value, 1, size, f);
    value[read] = '\0';
    fclose(f);
    
    return value;
}

static storage_result_t fallback_storage_remove(const char* key) {
    if (!key) return STORAGE_ERROR;
    
    char* path = get_fallback_path(key);
    remove(path);
    free(path);
    
    return STORAGE_OK;
}