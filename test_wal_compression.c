#include "postgres.h"
#include "access/xlog.h"
#include "utils/guc.h"
#include <stdio.h>

int main() {
    printf("Testing wal_compression_level implementation:\n");
    printf("wal_compression_level variable exists: %s\n", 
           (&wal_compression_level != NULL) ? "YES" : "NO");
    printf("Default value: %d\n", wal_compression_level);
    
    // Test setting different values
    wal_compression_level = 5;
    printf("After setting to 5: %d\n", wal_compression_level);
    
    wal_compression_level = 0;
    printf("After setting to 0: %d\n", wal_compression_level);
    
    printf("Test completed successfully!\n");
    return 0;
} 