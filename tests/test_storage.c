#include <colyseus/auth/secure_storage.h>
#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <stdlib.h>

int main() {
    printf("=== Test: Secure Storage ===\n");
    
    /* Test set and get */
    printf("Testing set and get...\n");
    storage_result_t result = secure_storage_set("test_key", "test_value");
    assert(result == STORAGE_OK);
    
    char* value = secure_storage_get("test_key");
    assert(value != NULL);
    assert(strcmp(value, "test_value") == 0);
    free(value);
    printf("PASS: Set and get\n");
    
    /* Test update */
    printf("Testing update...\n");
    result = secure_storage_set("test_key", "updated_value");
    assert(result == STORAGE_OK);
    
    value = secure_storage_get("test_key");
    assert(value != NULL);
    assert(strcmp(value, "updated_value") == 0);
    free(value);
    printf("PASS: Update\n");
    
    /* Test remove */
    printf("Testing remove...\n");
    result = secure_storage_remove("test_key");
    assert(result == STORAGE_OK);
    
    value = secure_storage_get("test_key");
    assert(value == NULL);
    printf("PASS: Remove\n");
    
    /* Test non-existent key */
    printf("Testing non-existent key...\n");
    value = secure_storage_get("non_existent_key");
    assert(value == NULL);
    printf("PASS: Non-existent key\n");
    
    /* Test storage available */
    printf("Testing storage availability...\n");
    int available = secure_storage_available();
    printf("Storage available: %d\n", available);
    
    printf("\nAll storage tests passed!\n");
    return 0;
}
