#ifndef COLYSEUS_SECURE_STORAGE_H
#define COLYSEUS_SECURE_STORAGE_H

#ifdef __cplusplus
extern "C" {
#endif

    /* Storage result codes */
    typedef enum {
        STORAGE_OK = 0,
        STORAGE_ERROR = -1,
        STORAGE_PERMISSION_DENIED = -2,
        STORAGE_NOT_FOUND = -3,
        STORAGE_PLATFORM_UNSUPPORTED = -4
    } storage_result_t;

    /* Set a value in secure storage */
    storage_result_t secure_storage_set(const char* key, const char* value);

    /* Get a value from secure storage (returns NULL if not found, caller must free) */
    char* secure_storage_get(const char* key);

    /* Remove a value from secure storage */
    storage_result_t secure_storage_remove(const char* key);

    /* Check if secure storage is available on this platform */
    int secure_storage_available(void);

#ifdef __cplusplus
}
#endif

#endif /* COLYSEUS_SECURE_STORAGE_H */