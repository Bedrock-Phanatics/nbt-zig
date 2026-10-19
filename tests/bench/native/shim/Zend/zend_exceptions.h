#include <stdarg.h>
#include <stdlib.h>

typedef struct zend_class_entry zend_class_entry;

static inline void zend_throw_exception(zend_class_entry *ce, const char *message, long code) { (void)ce; (void)message; (void)code; }
static inline void zend_throw_exception_ex(zend_class_entry *ce, long code, const char *format, ...) { (void)ce; (void)code; (void)format; }
static inline void *erealloc(void *pointer, size_t size) { return realloc(pointer, size); }
